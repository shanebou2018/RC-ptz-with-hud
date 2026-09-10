"""Telemetry-only bridge between the vehicle FPGA and the HUD web page.

Unlike the sibling esp32_bridge.py (main branch), this file has ZERO
control authority -- it only reads binary telemetry frames from the
vehicle FPGA's telemetry_uart_tx.v output over USB-serial and rebroadcasts
them to the HUD's websocket clients as the same JSON shape the browser
already expects. There is no inbound command path: any message a
websocket client sends is ignored (the on-screen controls were removed
from index.html in this fork -- see CLAUDE.md's fork section). All
vehicle control happens over a separate LoRa link between two FPGAs,
entirely outside this process -- the Pi is purely a video + telemetry
viewer here.

Binary frame format (from fpga/vehicle/rtl/telemetry_uart_tx.v, 14 bytes):
    0:     sync byte (0x5A)
    1-2:   heading, degrees*10, big-endian uint16
    3-8:   pan, tilt, focus, zoom, fire, load (0-180 each)
    9:     flags: bit0=motor L dir, bit1=motor R dir
    10:    motor L pwm
    11:    motor R pwm
    12-13: CRC16 (CRC-16/CCITT-FALSE) over bytes 0-11, big-endian

Run against real hardware:
    python vehicle_fpga_bridge.py --port /dev/ttyUSB0 --baud 115200

Run without hardware attached, to develop/test the HUD page:
    python vehicle_fpga_bridge.py --fake
"""

import argparse
import asyncio
import json

import serial_asyncio
import websockets

FRAME_LEN = 14
FRAME_SYNC = 0x5A

clients: set = set()


def crc16_ccitt_false(data: bytes) -> int:
    """Must match fpga/common/rtl/crc16.v's crc16_step() exactly:
    poly 0x1021, init 0xFFFF, no reflection, xorout 0x0000."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def decode_frame(frame: bytes):
    """Returns the telemetry dict for a valid 14-byte frame, or None if
    the sync byte or CRC doesn't check out."""
    if len(frame) != FRAME_LEN or frame[0] != FRAME_SYNC:
        return None
    crc_received = (frame[12] << 8) | frame[13]
    if crc16_ccitt_false(frame[:12]) != crc_received:
        return None
    heading_x10 = (frame[1] << 8) | frame[2]
    pan, tilt, focus, zoom, fire, load = frame[3:9]
    flags = frame[9]
    motor_l_pwm, motor_r_pwm = frame[10], frame[11]
    return {
        "hdg": heading_x10 / 10.0,
        "servo": {"pan": pan, "tilt": tilt, "focus": focus, "zoom": zoom, "fire": fire, "load": load},
        "motor": {
            "l": {"dir": flags & 0x1, "pwm": motor_l_pwm},
            "r": {"dir": (flags >> 1) & 0x1, "pwm": motor_r_pwm},
        },
    }


async def broadcast(message: str) -> None:
    if not clients:
        return
    await asyncio.gather(
        *(client.send(message) for client in clients),
        return_exceptions=True,
    )


class VehicleFpgaProtocol(asyncio.Protocol):
    """Reads the vehicle FPGA's binary telemetry frames off USB-serial,
    resyncing on FRAME_SYNC + CRC, and broadcasts each valid frame as
    JSON to every websocket client."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def data_received(self, data: bytes) -> None:
        self._buffer.extend(data)
        # Scan for a sync byte, then try to consume a full frame from
        # there -- mirrors e220_driver.v's own sync-byte framing approach
        # on the LoRa side (packet_defs.vh's PKT_SYNC), just at the
        # Python/UART layer this time.
        while True:
            sync_idx = self._buffer.find(bytes([FRAME_SYNC]))
            if sync_idx < 0:
                self._buffer.clear()
                return
            if sync_idx > 0:
                del self._buffer[:sync_idx]
            if len(self._buffer) < FRAME_LEN:
                return
            frame = bytes(self._buffer[:FRAME_LEN])
            telemetry = decode_frame(frame)
            if telemetry is not None:
                del self._buffer[:FRAME_LEN]
                asyncio.create_task(broadcast(json.dumps(telemetry)))
            else:
                # False sync match -- drop just the sync byte and rescan,
                # rather than the whole tentative frame, so a real frame
                # starting one byte later isn't skipped over too.
                del self._buffer[:1]


class FakeVehicleFpga:
    """Generates synthetic telemetry in-process, so the HUD page can be
    developed/tested without any FPGA hardware attached -- same spirit as
    esp32_bridge.py's FakeEsp32, but read-only (no command handling,
    since this fork's Pi has no control authority at all)."""

    def __init__(self) -> None:
        self.state = {
            "hdg": 0.0,
            "servo": {"pan": 90, "tilt": 90, "focus": 0, "zoom": 0, "fire": 0, "load": 0},
            "motor": {"l": {"dir": 1, "pwm": 0}, "r": {"dir": 1, "pwm": 0}},
        }

    async def spin_loop(self) -> None:
        while True:
            self.state["hdg"] = (self.state["hdg"] + 2) % 360
            await broadcast(json.dumps(self.state))
            await asyncio.sleep(0.5)


async def ws_handler(websocket) -> None:
    clients.add(websocket)
    try:
        async for _ in websocket:
            pass  # no inbound command path in this fork -- see module docstring
    finally:
        clients.discard(websocket)


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyUSB0", help="vehicle FPGA's USB-serial device")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--ws-host", default="0.0.0.0")
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument(
        "--fake",
        action="store_true",
        help="simulate the vehicle FPGA in-process instead of opening a serial port",
    )
    args = parser.parse_args()

    loop = asyncio.get_running_loop()

    if args.fake:
        fpga = FakeVehicleFpga()
        loop.create_task(fpga.spin_loop())
    else:
        await serial_asyncio.create_serial_connection(
            loop, VehicleFpgaProtocol, args.port, baudrate=args.baud
        )

    async with websockets.serve(ws_handler, args.ws_host, args.ws_port):
        print(f"Vehicle FPGA telemetry bridge listening on ws://{args.ws_host}:{args.ws_port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())

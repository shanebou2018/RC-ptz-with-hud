"""Bidirectional bridge between the ESP32 (motors, 6 servos, compass — see
control/esp32_firmware/) and the HUD web page.

- Lines the ESP32 writes to its USB-serial port are line-delimited JSON
  telemetry, e.g.:
      {"hdg": 123.4, "servo": {"pan":90,"tilt":45,"focus":0,"zoom":0,"fire":0,"load":0},
       "motor": {"l": {"dir":1,"pwm":0}, "r": {"dir":1,"pwm":0}}}
  Each line is broadcast to every connected websocket client as-is.

- Any message a websocket client sends (the HUD page's on-screen controls)
  is treated as a command and written straight through to the ESP32's
  serial port, e.g.:
      {"type": "servo", "name": "pan", "pos": 90}
      {"type": "motor", "side": "l", "dir": 1, "pwm": 180}
  See control/esp32_firmware/esp32_firmware.ino for the exact fields each
  command type expects.

This makes the websocket a single shared channel: browser -> command ->
ESP32, and ESP32 -> telemetry -> browser (fanned out to all clients).

Run against real hardware:
    python esp32_bridge.py --port /dev/ttyUSB0 --baud 115200

Run without hardware attached, to develop/test the HUD page (commands sent
from the page update the simulated state and are reflected back):
    python esp32_bridge.py --fake
"""

import argparse
import asyncio
import json

import serial_asyncio
import websockets

clients: set = set()


async def broadcast(message: str) -> None:
    if not clients:
        return
    await asyncio.gather(
        *(client.send(message) for client in clients),
        return_exceptions=True,
    )


class Esp32BridgeProtocol(asyncio.Protocol):
    """Reads line-delimited JSON telemetry from the ESP32 and forwards
    outgoing command lines to it."""

    transport: asyncio.Transport = None

    def __init__(self) -> None:
        self._buffer = ""

    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self._buffer += data.decode(errors="ignore")
        *lines, self._buffer = self._buffer.split("\n")
        for line in lines:
            line = line.strip()
            if line:
                asyncio.create_task(broadcast(line))

    def send_command(self, line: str) -> None:
        if self.transport is not None:
            self.transport.write((line + "\n").encode())


class FakeEsp32:
    """Stands in for Esp32BridgeProtocol.send_command when running --fake:
    applies commands to an in-memory state and re-broadcasts it as
    telemetry, so the HUD page behaves the same with no hardware attached."""

    def __init__(self) -> None:
        self.state = {
            "hdg": 0.0,
            "servo": {"pan": 90, "tilt": 90, "focus": 0, "zoom": 0, "fire": 0, "load": 0},
            "motor": {"l": {"dir": 1, "pwm": 0}, "r": {"dir": 1, "pwm": 0}},
        }

    def send_command(self, line: str) -> None:
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            return
        if cmd.get("type") == "servo" and cmd.get("name") in self.state["servo"]:
            self.state["servo"][cmd["name"]] = cmd.get("pos", 0)
        elif cmd.get("type") == "motor" and cmd.get("side") in self.state["motor"]:
            self.state["motor"][cmd["side"]] = {"dir": cmd.get("dir", 1), "pwm": cmd.get("pwm", 0)}
        asyncio.create_task(broadcast(json.dumps(self.state)))

    async def spin_loop(self) -> None:
        while True:
            self.state["hdg"] = (self.state["hdg"] + 2) % 360
            await broadcast(json.dumps(self.state))
            await asyncio.sleep(0.5)


async def ws_handler(websocket, esp32) -> None:
    clients.add(websocket)
    try:
        async for message in websocket:
            esp32.send_command(message)
    finally:
        clients.discard(websocket)


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyUSB0", help="ESP32 USB-serial device")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--ws-host", default="0.0.0.0")
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument(
        "--fake",
        action="store_true",
        help="simulate the ESP32 in-process instead of opening a serial port",
    )
    args = parser.parse_args()

    loop = asyncio.get_running_loop()

    if args.fake:
        esp32 = FakeEsp32()
        loop.create_task(esp32.spin_loop())
    else:
        _, esp32 = await serial_asyncio.create_serial_connection(
            loop, Esp32BridgeProtocol, args.port, baudrate=args.baud
        )

    async with websockets.serve(lambda ws: ws_handler(ws, esp32), args.ws_host, args.ws_port):
        print(f"ESP32 bridge listening on ws://{args.ws_host}:{args.ws_port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())

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
      {"type": "ping"}
  See control/esp32_firmware/esp32_firmware.ino for the exact fields each
  command type expects. The HUD page sends a "ping" heartbeat every couple
  hundred ms whenever the socket is open — it keeps the ESP32's deadman
  timeout from tripping even while a motor is deliberately held at a
  non-zero speed and no slider is actively moving.

This makes the websocket a single shared channel: browser -> command ->
ESP32, and ESP32 -> telemetry -> browser (fanned out to all clients). If
the last browser disconnects, both drive motors are stopped immediately
(see stop_motor_lines()) rather than waiting on the ESP32's own timeout.

Run against real hardware:
    python esp32_bridge.py --port /dev/ttyUSB0 --baud 115200

Run without hardware attached, to develop/test the HUD page (commands sent
from the page update the simulated state and are reflected back):
    python esp32_bridge.py --fake
"""

import argparse
import asyncio
import json
import time

import serial_asyncio
import websockets

# =============================================================================
# SAFETY LIMITS — tune these for your hardware. Keep MAX_MOTOR_PWM in sync
# with MAX_MOTOR_PWM in control/esp32_firmware/esp32_firmware.ino and
# web/static/index.html. Only actually enforced here in --fake mode (the
# real ESP32 enforces its own copy independently over serial — that's the
# authoritative one); kept in sync here too so --fake accurately previews
# real safety behavior.
# =============================================================================
MAX_MOTOR_PWM = 200
COMMAND_TIMEOUT_S = 0.5  # matches esp32_firmware.ino's COMMAND_TIMEOUT_MS

clients: set = set()


def stop_motor_lines():
    return [
        json.dumps({"type": "motor", "side": "l", "dir": 1, "pwm": 0}),
        json.dumps({"type": "motor", "side": "r", "dir": 1, "pwm": 0}),
    ]


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
        self.last_command_ts = time.monotonic()

    def send_command(self, line: str) -> None:
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            return
        # Any well-formed command — including a plain {"type":"ping"}
        # heartbeat — counts as proof the link is alive.
        self.last_command_ts = time.monotonic()
        if cmd.get("type") == "servo" and cmd.get("name") in self.state["servo"]:
            self.state["servo"][cmd["name"]] = cmd.get("pos", 0)
        elif cmd.get("type") == "motor" and cmd.get("side") in self.state["motor"]:
            pwm = max(0, min(cmd.get("pwm", 0), MAX_MOTOR_PWM))
            self.state["motor"][cmd["side"]] = {"dir": cmd.get("dir", 1), "pwm": pwm}
        else:
            return  # unrecognized/ping-only line, nothing changed to broadcast
        asyncio.create_task(broadcast(json.dumps(self.state)))

    async def spin_loop(self) -> None:
        while True:
            self.state["hdg"] = (self.state["hdg"] + 2) % 360
            await broadcast(json.dumps(self.state))
            await asyncio.sleep(0.5)

    async def watchdog_loop(self) -> None:
        """Mirrors esp32_firmware.ino's deadman timeout, so --fake behaves
        like real hardware would if the link goes quiet."""
        while True:
            await asyncio.sleep(0.1)
            stale = time.monotonic() - self.last_command_ts > COMMAND_TIMEOUT_S
            still_moving = any(m["pwm"] != 0 for m in self.state["motor"].values())
            if stale and still_moving:
                for side in self.state["motor"]:
                    self.state["motor"][side] = {"dir": 1, "pwm": 0}
                await broadcast(json.dumps(self.state))


async def ws_handler(websocket, esp32) -> None:
    clients.add(websocket)
    try:
        async for message in websocket:
            esp32.send_command(message)
    finally:
        clients.discard(websocket)
        if not clients:
            # Last browser disconnected — stop the drive motors immediately
            # rather than waiting on the ESP32's own deadman timeout.
            for line in stop_motor_lines():
                esp32.send_command(line)


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
        loop.create_task(esp32.watchdog_loop())
    else:
        _, esp32 = await serial_asyncio.create_serial_connection(
            loop, Esp32BridgeProtocol, args.port, baudrate=args.baud
        )

    async with websockets.serve(lambda ws: ws_handler(ws, esp32), args.ws_host, args.ws_port):
        print(f"ESP32 bridge listening on ws://{args.ws_host}:{args.ws_port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())

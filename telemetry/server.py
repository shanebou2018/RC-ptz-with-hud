"""Reads line-delimited JSON telemetry from the STM32H7's UART and fans it
out to any connected websocket clients (the HUD canvas on the web page).

Expected line format (see CLAUDE.md "Open gaps" — not yet finalized with the
STM32 firmware):
    {"servo": <str|num>, "hdg": <deg>, "speed": <m/s>, "lat": <deg>, "lon": <deg>}

Run against real hardware:
    python server.py --port /dev/serial0 --baud 115200

Run without hardware attached, to develop/test the HUD page against
simulated telemetry:
    python server.py --fake
"""

import argparse
import asyncio
import itertools
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


class TelemetryProtocol(asyncio.Protocol):
    def __init__(self) -> None:
        self._buffer = ""

    def data_received(self, data: bytes) -> None:
        self._buffer += data.decode(errors="ignore")
        *lines, self._buffer = self._buffer.split("\n")
        for line in lines:
            line = line.strip()
            if line:
                asyncio.create_task(broadcast(line))


async def ws_handler(websocket) -> None:
    clients.add(websocket)
    try:
        await websocket.wait_closed()
    finally:
        clients.discard(websocket)


async def fake_telemetry_loop() -> None:
    """Simulates a slowly-changing telemetry stream for HUD development
    without the STM32H7 / GPS / compass hardware attached."""
    heading = 0.0
    for step in itertools.count():
        heading = (heading + 3) % 360
        frame = {
            "servo": f"pan={(step % 180) - 90} tilt={((step * 2) % 60) - 30}",
            "hdg": heading,
            "speed": 1.5 + 0.5 * (step % 5),
            "lat": 37.7749 + 0.0001 * (step % 10),
            "lon": -122.4194 - 0.0001 * (step % 10),
        }
        await broadcast(json.dumps(frame))
        await asyncio.sleep(0.5)


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/serial0", help="UART device")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--ws-host", default="0.0.0.0")
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument(
        "--fake",
        action="store_true",
        help="generate simulated telemetry instead of reading the UART",
    )
    args = parser.parse_args()

    loop = asyncio.get_running_loop()

    if args.fake:
        loop.create_task(fake_telemetry_loop())
    else:
        await serial_asyncio.create_serial_connection(
            loop, TelemetryProtocol, args.port, baudrate=args.baud
        )

    async with websockets.serve(ws_handler, args.ws_host, args.ws_port):
        print(f"telemetry websocket listening on ws://{args.ws_host}:{args.ws_port}")
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())

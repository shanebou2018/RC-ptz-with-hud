# RC PTZ with HUD

Raspberry Pi 5 dual-camera pan/tilt/zoom rig: a picture-in-picture (PIP) video
composite, streamed over RTSP, plus a web page showing the same video live
with a HUD overlay (servo/pan-tilt position, compass heading, speed, GPS
lat/long).

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, hardware list, and
open gaps — this README is just the quick-start.

## Status

Early scaffolding. The pieces below have starter code but have **not** been
run against real Pi 5 / camera / STM32 hardware yet.

## Layout

```
pipeline/     GStreamer PiP capture + encode script (pip_stream.sh)
mediamtx/     MediaMTX (RTSP/WebRTC server) config
telemetry/    UART-to-websocket telemetry bridge (Python)
web/          FastAPI app serving the HUD page (canvas overlay + WHEP video)
systemd/      Starter unit files for running everything as services on the Pi
```

## Running on the Pi

1. Install [MediaMTX](https://github.com/bluenviron/mediamtx) and start it
   with the provided config:
   ```
   mediamtx mediamtx/mediamtx.yml
   ```
2. Find your camera IDs and set them in `pipeline/pip_stream.sh` (or via env
   vars), then start the capture pipeline:
   ```
   rpicam-hello --list-cameras   # or libcamera-hello --list-cameras
   MAIN_CAM=<id0> INSET_CAM=<id1> ./pipeline/pip_stream.sh
   ```
   Check the stream with `vlc rtsp://<pi>:8554/robot`.
3. Start the telemetry bridge (against the real STM32H7 UART, once the
   framing in `telemetry/server.py` matches the firmware):
   ```
   cd telemetry && pip install -r requirements.txt
   python server.py --port /dev/serial0 --baud 115200
   ```
4. Start the web app:
   ```
   cd web && pip install -r requirements.txt
   uvicorn app:app --host 0.0.0.0 --port 8000
   ```
   Open `http://<pi>:8000/` in a browser.

`systemd/*.service` has starter units for running all of the above as
services — adjust the paths inside them to match your deploy location before
installing.

## Developing the HUD without hardware

The telemetry bridge can generate simulated data instead of reading a UART,
which is enough to iterate on the HUD page without a Pi, cameras, or the
STM32H7 attached:

```
cd telemetry && python server.py --fake
```

Then open `web/static/index.html` (or run the FastAPI app) — the canvas HUD
will animate against the fake feed. The video panel won't show anything
without MediaMTX + a real camera pipeline running.

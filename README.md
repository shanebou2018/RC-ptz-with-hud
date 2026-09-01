# RC PTZ with HUD

Raspberry Pi 5 pan/tilt/zoom camera rig: video streamed over RTSP (with a
picture-in-picture composite once a second camera is added), plus a web page
showing the same video live with a HUD overlay — compass heading, servo
positions (pan/tilt/focus/zoom/fire/load), drive motor state, and (once GPS
is wired up) speed and lat/long.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, hardware list, serial
protocol, and open gaps — this README is just the quick-start.

## Status

Early scaffolding, working toward a first bench test: one Pi 5, one camera,
one ESP32 (motors + 6 servos + compass), and the HUD web page. The HUD
page's controls and telemetry readout have been verified end-to-end against
a simulated ESP32 (`control/esp32_bridge.py --fake`) — dragging a slider in
the browser round-trips through the bridge and updates the canvas readout.
Nothing involving actual cameras, GStreamer, MediaMTX, or real ESP32
hardware has been run yet.

## Layout

```
pipeline/     GStreamer capture + encode scripts
              - single_cam_stream.sh  (current: one camera, no compositor)
              - pip_stream.sh         (dual-camera PiP, once camera #2 exists)
mediamtx/     MediaMTX (RTSP/WebRTC server) config
control/      Pi <-> ESP32 bridge (serial <-> websocket) + the ESP32 firmware sketch
web/          FastAPI app serving the HUD page (canvas overlay + WHEP video + controls)
systemd/      Starter unit files for running everything as services on the Pi
```

## Running on the Pi

1. Install [MediaMTX](https://github.com/bluenviron/mediamtx) and start it
   with the provided config:
   ```
   mediamtx mediamtx/mediamtx.yml
   ```
2. Find your camera ID and set it in `pipeline/single_cam_stream.sh` (or via
   an env var), then start the capture pipeline:
   ```
   rpicam-hello --list-cameras   # or libcamera-hello --list-cameras
   CAM=<id0> ./pipeline/single_cam_stream.sh
   ```
   Check the stream with `vlc rtsp://<pi>:8554/robot`.
3. Flash `control/esp32_firmware/esp32_firmware.ino` to the ESP32 (Arduino
   IDE or `arduino-cli`; needs the ESP32Servo, ArduinoJson, and Adafruit
   BNO055/Unified Sensor libraries — see the sketch's header comment), then
   start the control bridge against it:
   ```
   cd control && pip install -r requirements.txt
   python esp32_bridge.py --port /dev/ttyUSB0 --baud 115200
   ```
4. Start the web app:
   ```
   cd web && pip install -r requirements.txt
   uvicorn app:app --host 0.0.0.0 --port 8000
   ```
   Open `http://<pi>:8000/` in a browser — video panel, compass dial, servo
   readout, motor bars, and sliders/buttons that actually drive the ESP32.

`systemd/*.service` has starter units for running all of the above as
services — adjust the paths inside them to match your deploy location before
installing.

## Developing the HUD without hardware

`control/esp32_bridge.py --fake` simulates the ESP32 in-process — no camera,
Pi-specific hardware, or ESP32 needed. Commands sent from the HUD page's
sliders/buttons update the simulated state and are reflected straight back:

```
cd control && python esp32_bridge.py --fake
cd ../web && uvicorn app:app --host 0.0.0.0 --port 8000
```

Then open `http://localhost:8000/`. The canvas HUD (compass dial, servo
readout, motor bars) and the on-screen controls both work fully against the
fake bridge. The video panel won't show anything without MediaMTX + a real
camera pipeline running.

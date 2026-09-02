# RC PTZ with HUD

Raspberry Pi 5 pan/tilt/zoom camera rig: video streamed over RTSP (with a
picture-in-picture composite once a second camera is added), plus a web page
showing the same video live with a HUD overlay — compass heading, servo
positions (pan/tilt/focus/zoom/fire/load), drive motor state, and (once GPS
is wired up) speed and lat/long.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, hardware list, serial
protocol, and open gaps — this README is just the quick-start.

## Status

First bench test in progress: one Pi 5, one camera, one ESP32 (motors + 6
servos + compass), and the HUD web page.

**Verified on real Pi 5 hardware — the full single-camera + HUD stack works
end-to-end:** the camera pipeline (`pipeline/single_cam_stream.sh` → MediaMTX,
confirmed live in VLC over RTSP), *and* the actual HUD web page itself —
live video via MediaMTX's WebRTC (WHEP) embed, the compass dial, servo
readout, motor bars, and on-screen controls all working against
`control/esp32_bridge.py --fake` running on the Pi. Along the way we found
GStreamer's `rtspclientsink` isn't available on Debian trixie (it ships in
GStreamer's Rust plugin set, which isn't packaged there), so the pipeline
script uses `rpicam-vid`'s built-in `libav` RTSP push instead — see
`CLAUDE.md` for the full story.

**Not yet touched:** the ESP32 firmware/serial link (still simulated via
`--fake`) and `pip_stream.sh` (dual-camera — still has the same
`rtspclientsink` problem, needs the same rework).

Running all of this requires 4 long-running processes at once (MediaMTX, the
camera pipeline, the ESP32 bridge, the web app). **These now run as systemd
services on the bench-test Pi** — installed, enabled, and confirmed to
survive a full reboot with no manual terminal work. See "Installing as
systemd services" below.

## Layout

```
pipeline/     Capture + encode scripts
              - single_cam_stream.sh  (current: rpicam-vid, one camera, no compositor)
              - pip_stream.sh         (dual-camera GStreamer PiP — needs rework, see CLAUDE.md)
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
2. Find your camera's numeric index and set it in `pipeline/single_cam_stream.sh`
   (or via an env var), then start the capture pipeline:
   ```
   rpicam-hello --list-cameras   # note the index, e.g. "0" in "0 : ov5647 [...]"
   CAM=0 ./pipeline/single_cam_stream.sh
   ```
   Check the stream with `vlc rtsp://<pi>:8554/robot` (expect a few seconds
   of latency in VLC by default — that's normal RTSP/network-caching
   behavior, not a pipeline problem; the HUD page's WebRTC path should be
   lower-latency, though that hasn't been tested yet).
3. Flash `control/esp32_firmware/esp32_firmware.ino` to the ESP32 (Arduino
   IDE or `arduino-cli`; needs the ESP32Servo, ArduinoJson, and Adafruit
   BNO055/Unified Sensor libraries — see the sketch's header comment), then
   set up a venv and start the control bridge against it:
   ```
   cd control
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   .venv/bin/python esp32_bridge.py --port /dev/ttyUSB0 --baud 115200
   ```
   (Use `--fake` instead of `--port .../--baud ...` until the ESP32 is
   actually wired up.)
4. Start the web app, same pattern:
   ```
   cd web
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   .venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
   ```
   Open `http://<pi>:8000/` in a browser — video panel, compass dial, servo
   readout, motor bars, and sliders/buttons that actually drive the ESP32.

Steps 1–4 each need their own terminal/SSH session left running — see the
next section for running them as background services instead.

## Installing as systemd services

Once each piece above works manually, install them so they run in the
background and start automatically on boot — no terminals to babysit:

```
cd ~/RC-ptz-with-hud
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rc-hud-mediamtx rc-hud-pipeline rc-hud-control rc-hud-web
sudo systemctl status rc-hud-mediamtx rc-hud-pipeline rc-hud-control rc-hud-web
```

Each should show `active (running)`. If one doesn't, check its logs with
`sudo journalctl -u <service-name> -n 50`.

The unit files as committed are hardcoded to this bench-test Pi's real setup
(user `admincam`, repo at `/home/admincam/RC-ptz-with-hud`, MediaMTX at
`/home/admincam/mediamtx`) — edit them if you're deploying to a different
machine/user. `rc-hud-control.service` defaults to `--fake`; switch it to
`--port /dev/ttyUSB0 --baud 115200` once the ESP32 is wired up, then
`sudo systemctl daemon-reload && sudo systemctl restart rc-hud-control`.

## Developing the HUD without hardware

`control/esp32_bridge.py --fake` simulates the ESP32 in-process — no camera,
Pi-specific hardware, or ESP32 needed. Commands sent from the HUD page's
sliders/buttons update the simulated state and are reflected straight back:

```
cd control && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python esp32_bridge.py --fake
cd ../web && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

Then open `http://localhost:8000/`. The canvas HUD (compass dial, servo
readout, motor bars) and the on-screen controls both work fully against the
fake bridge. The video panel won't show anything without MediaMTX + a real
camera pipeline running.

# RC PTZ with HUD

Raspberry Pi 5 pan/tilt/zoom camera rig: video streamed over RTSP (with a
picture-in-picture composite once a second camera is added), plus a web page
showing the same video live with a HUD overlay — compass heading, servo
positions (pan/tilt/focus/zoom/fire/load), drive motor state, and (once GPS
is wired up) speed and lat/long.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, hardware list, serial
protocol, and open gaps — this README is just the quick-start.

**This branch (`lora-fpga-control`) is a fork**: vehicle control (motors,
servos, compass) no longer goes through an ESP32/the Pi at all — it's driven
by a vehicle-side FPGA over a dedicated LoRa link from a base-station FPGA,
with the Pi reduced to a view-only video + telemetry display. See
`CLAUDE.md`'s "Fork: LoRa/FPGA vehicle control architecture" section and
`fpga/README.md` before following the ESP32-oriented steps below — the video
pipeline/HUD-page steps (1, 4) still apply unchanged, but step 3 (ESP32) is
replaced by the FPGA build in `fpga/`, which is **simulation-verified only,
zero real hardware tested** as of this writing (see `fpga/README.md`'s LUT
budget finding before assuming it's ready to flash).

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
`rtspclientsink` problem, needs the same rework). On this branch, the ESP32
path is superseded entirely by `fpga/` — see the fork note above and
`fpga/README.md` for that work's own status (RTL simulation-verified, zero
real hardware).

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
control/      vehicle_fpga_bridge.py: telemetry-ONLY bridge from the vehicle
              FPGA to the HUD websocket (this fork's active file). Also still
              contains esp32_bridge.py/esp32_firmware.ino, kept as unused
              reference material -- see CLAUDE.md's fork section.
fpga/         RTL for both Alchitry Cu V2 boards (base station + vehicle) and
              the build/test Makefile -- see fpga/README.md.
web/          FastAPI app serving the HUD page (canvas overlay + WHEP video,
              view-only in this fork -- on-screen/keyboard controls removed)
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
3. **On this branch, there is no ESP32 step.** Vehicle control is a
   base-FPGA ↔ LoRa ↔ vehicle-FPGA link instead — see `fpga/README.md` for
   the build/test flow. As of this writing that RTL is simulation-verified
   only (`cd fpga && make sim`), with no real Alchitry Cu V2 pin data filled
   in yet, so there is nothing to flash for real hardware. Set up a venv and
   run the telemetry bridge against `--fake` in the meantime:
   ```
   cd control
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   .venv/bin/python vehicle_fpga_bridge.py --fake
   ```
   Once the vehicle FPGA is real hardware and wired to the Pi over USB-serial:
   ```
   .venv/bin/python vehicle_fpga_bridge.py --port /dev/ttyUSB0 --baud 115200
   ```
4. Start the web app, same pattern:
   ```
   cd web
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   .venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
   ```
   Open `http://<pi>:8000/` in a browser — video panel, compass dial, servo
   readout, and motor bars. **View-only in this fork**: there are no
   on-screen sliders/buttons or keyboard controls — vehicle control happens
   over the LoRa base station, not this page (see CLAUDE.md's fork section).

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
`--port /dev/ttyUSB0 --baud 115200` once the vehicle FPGA is real hardware
and wired up, then
`sudo systemctl daemon-reload && sudo systemctl restart rc-hud-control`.

## Developing the HUD without hardware

`control/vehicle_fpga_bridge.py --fake` simulates the vehicle FPGA's
telemetry in-process — no camera, Pi-specific hardware, or FPGA needed:

```
cd control && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python vehicle_fpga_bridge.py --fake
cd ../web && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

Then open `http://localhost:8000/`. The canvas HUD (compass dial, servo
readout, motor bars) works fully against the fake bridge — there's no
control path to test in this fork, only telemetry display. The video panel
won't show anything without MediaMTX + a real camera pipeline running.

## Developing/testing the FPGA RTL without hardware

```
cd fpga
make sim            # run all 11 testbenches (iverilog)
make stat-vehicle    # yosys synth + LUT utilization report, no .pcf needed
```

See `fpga/README.md` for the full toolchain writeup, the current 91% LUT
utilization finding, and what's still needed before a real bitstream can be
built and flashed.

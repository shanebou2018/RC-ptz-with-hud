# CLAUDE.md

This file gives Claude Code (and any other AI assistant) the context needed to work on this project. Update it as the project's architecture and conventions solidify — it should stay a living summary, not a one-time snapshot.

## Project

RC-ptz-with-hud: a Raspberry Pi 5 based pan/tilt/zoom (PTZ) camera rig with a live heads-up display (HUD), built for an RC vehicle or similar remote platform.

Status: **early scaffolding, moving toward a first bench test**. Current phase: one Pi 5, one camera, an ESP32 driving motors/servos/compass, and the HUD web page — proving out the pipeline end-to-end before the second camera and the full PIP layout get added. None of it has been run against real hardware yet. Treat everything here as the working plan, and correct it as real hardware testing reveals problems.

## Goal

1. **Camera capture** on a Raspberry Pi 5. End goal is **dual camera** composited as picture-in-picture (PIP) — a main view with a secondary camera inset; **current phase is a single camera** (see "Current test phase" below), with PIP compositing added back once a second camera is on hand.
2. **RTSP stream** of the video, for viewing in standard RTSP clients (VLC, etc.) and for low-latency remote piloting.
3. **Web page** that shows the same video live in a browser, with the HUD overlay described below.
4. **HUD overlay** rendered on top of the video, showing live telemetry:
   - Servo data: pan, tilt, focus, zoom, fire, load
   - Drive motor state: left/right direction + PWM
   - Compass / heading data
   - Speed, GPS latitude and longitude (planned — no GPS hardware chosen yet, see Open gaps)

## Current test phase: single camera + ESP32 bench test

Before building out the second camera and PIP compositing, the goal is to get one full vertical slice working on real hardware: Pi 5 + one camera + RTSP stream + ESP32 over serial + HUD web page with live compass/servo/motor readout and on-screen controls that actually drive the hardware.

- `pipeline/single_cam_stream.sh` — single `libcamerasrc` → encode → `rtspclientsink`, no compositor. Use `pipeline/pip_stream.sh` instead once camera #2 is added.
- `systemd/rc-hud-pipeline.service` currently points at `single_cam_stream.sh` for this reason — switch it back to `pip_stream.sh` when going dual-camera.
- The web HUD (`web/static/index.html`) already includes on-screen sliders/buttons for all 6 servos and both drive motors, wired to the control websocket — so this phase also validates the *control* path (browser → Pi → ESP32), not just telemetry display.

## Key architectural decision: HUD is not burned into the RTSP feed

The HUD is rendered **client-side** on an HTML `<canvas>` layered over the video element on the web page, driven by a live telemetry websocket — it is *not* composited into the video frames. This keeps:

- The RTSP stream clean (for VLC/QGroundControl/any generic RTSP client) with zero HUD-related re-encode cost.
- The HUD independently updatable/restylable without touching the video pipeline.

If HUD-baked-into-video is ever needed (e.g. for DVR recordings), that's an *additional* GStreamer overlay stage layered on later — not part of the initial build.

## Hardware

- **Compute**: Raspberry Pi 5.
- **Cameras**: Raspberry Pi Camera Module 3 (12MP, Sony IMX708, autofocus). End goal is 2x, one per native CSI port (Pi 5 has two — CAM/DISP0 and CAM/DISP1 — no splitter needed); **current bench test uses 1**. Mix of standard + wide FOV, or two standard, depending on what each camera is used for, once the second one is bought. Camera Module 3 ships with a short (~200mm) FPC cable; buy longer (300–500mm) cables separately for chassis routing, and keep spares — these cables are the most fragile part of the build.
  - **Zoom**: digital crop from the sensor by default. There's also a physical `zoom` servo in the motor-control list below (for a lens with a mechanical zoom ring) — the two are independent; which one (or both) actually gets used depends on the camera/lens ultimately mounted.
  - **Low light**: if daytime-only, skip NoIR. If night operation is needed, get the NoIR variant plus an external IR illuminator (no onboard IR LEDs on the module).
- **Motor / servo / telemetry controller**: **ESP32** dev board, connected to the Pi 5 over USB serial (115200 baud). This supersedes the previously-planned STM32H7 for the current prototyping phase — the STM32H7's independent watchdog/dual-bank-flash/brownout guarantees are a real loss for eventual field reliability, but the ESP32 (cheap, Arduino-ecosystem, built-in USB-serial) is faster to bench-test with. Revisit STM32H7 later if the reliability case matters more than iteration speed once the rig is past prototyping. See `control/esp32_firmware/esp32_firmware.ino`.
  - **Drive motors**: 2x Cytron-style 2-pin (DIR + PWM) motor controllers, one per side (left/right).
  - **Servos** (6, hobby PWM, 0–180°): **pan**, **tilt**, **focus**, **zoom**, **fire**, **load**. ("Fire"/"load" are driven as plain servo-position commands like the others; if they turn out to need discrete/latching behavior instead of a 0–180° sweep, that's a firmware change, not a protocol change.)
  - **Compass/IMU**: wired to the ESP32 over I2C (assumed — not yet confirmed with real wiring), folded into the same serial telemetry stream to the Pi. Firmware currently assumes a BNO055 (`Adafruit_BNO055` library) as a placeholder — swap for whatever part is actually used.
- **GPS**: not yet chosen, and not part of the ESP32's job — needs a UART/I2C GPS module (u-blox NEO-6M/M8N are the easy default), wired directly to the Pi 5 or added to the ESP32 later. Speed can come from GPS ground speed and/or motor/wheel telemetry. Until this exists, the HUD shows a static "not wired up yet" placeholder instead of live GPS/speed.

Confirm with the user before changing any of the above, and update this section as parts get locked in.

## Video pipeline constraint: Pi 5 has no hardware H.264 encoder

Broadcom pulled the encode block for Pi 5 (decode-only VPU now) — camera capture + encode is CPU (`x264enc` software encode), and doubles up once PIP compositing brings a second camera into the same pipeline. At 1080p30 this will pin cores. Plan on **720p15–20 per camera**, or MJPEG if dodging encoder cost matters more than bandwidth.

## Architecture

```
Cam0 (CSI) ── libcamera → x264enc (software) → rtspclientsink → MediaMTX ──► WebRTC (WHEP) out ──► browser <video>
                                                                                                          ▲
ESP32 (motors, 6 servos, compass) ──USB serial──► Python bridge ──► websocket ──┴──► canvas HUD + on-screen controls
                                     ◄──────────────────────────────────────────┘         (commands flow back down)
```

(Once camera #2 is added, `Cam0`/`Cam1` feed a GStreamer `compositor` for PIP before `x264enc` — see `pipeline/pip_stream.sh`.)

- **MediaMTX** (formerly rtsp-simple-server) is the RTSP/WebRTC server — a single pre-built binary, config-only, not something we write. Handles both RTSP consumers (`rtsp://<pi>:8554/robot`) and gives a WebRTC (WHEP) endpoint for the web page (`http://<pi>:8889/robot`) for free.
- **GStreamer** does capture (+ PiP compositing, once there are 2 cameras) + encode, and pushes to MediaMTX via `rtspclientsink`. See `pipeline/single_cam_stream.sh` (current) and `pipeline/pip_stream.sh` (dual-camera).
- **Web app** (FastAPI) serves the HUD page: embeds a MediaMTX WHEP video player + a canvas HUD layer (compass dial, servo readout, motor bars) + on-screen servo/motor controls, all driven over one websocket. See `web/`.
- **Control/telemetry bridge**: a Python asyncio service that's the single point of contact with the ESP32 over USB serial — bidirectional: ESP32 → Pi telemetry lines get broadcast to every websocket client, and any command a client sends gets written straight to the ESP32. See `control/esp32_bridge.py`.

PiP toggle (swap which camera is the inset) should be done live via the GStreamer `compositor` pads' `xpos`/`ypos`/`width`/`height`/`zorder` properties (dynamic property push), not by rebuilding the pipeline — relevant once dual-camera is back in play.

## Serial protocol (Pi ↔ ESP32)

Newline-delimited JSON, one object per line, in both directions over the same USB-serial link. Documented in full in `control/esp32_bridge.py`'s module docstring and implemented in `control/esp32_firmware/esp32_firmware.ino`.

**Pi → ESP32 (commands):**
```
{"type": "servo", "name": "pan", "pos": 90}      // name: pan|tilt|focus|zoom|fire|load, pos: 0-180
{"type": "motor", "side": "l", "dir": 1, "pwm": 180}   // side: l|r, dir: 0|1, pwm: 0-255
```

**ESP32 → Pi (telemetry, emitted ~10Hz):**
```
{"hdg": 123.4, "servo": {"pan":90,"tilt":45,"focus":0,"zoom":0,"fire":0,"load":0},
 "motor": {"l": {"dir":1,"pwm":0}, "r": {"dir":1,"pwm":0}}}
```

This is a first draft, not yet validated against real ESP32 firmware behavior on hardware — treat field names/ranges as easy to change once real testing starts.

## Repo layout

- `pipeline/single_cam_stream.sh` — single-camera capture/encode script (current bench-test phase).
- `pipeline/pip_stream.sh` — dual-camera PiP capture/encode script (for once camera #2 is added).
- `mediamtx/mediamtx.yml` — MediaMTX config (RTSP + WebRTC/WHEP, `robot` path).
- `control/esp32_bridge.py` — bidirectional Pi ↔ ESP32 bridge: serial ↔ websocket, plus a `--fake` mode that simulates the ESP32 in-process for HUD development without hardware.
- `control/esp32_firmware/esp32_firmware.ino` — ESP32 sketch: drives the 2 drive motors + 6 servos, reads the compass, speaks the serial protocol above. **Not yet compiled or run on hardware.**
- `web/` — FastAPI app serving the HUD page (`web/static/index.html`): WHEP video embed, canvas HUD (compass dial, servo readout, motor bars), and on-screen servo/motor controls, all over the control websocket.
- `systemd/` — starter unit files for running MediaMTX, the camera pipeline, the ESP32 control bridge, and the web app as services on the Pi.

## Open gaps (confirm before assuming)

- **Pinout in `esp32_firmware.ino`** is a first guess, not a wiring decision — confirm against actual wiring before flashing.
- **Compass part** not chosen; firmware assumes a BNO055 as a placeholder.
- **Serial protocol** above is a first draft, unvalidated against real firmware/hardware behavior.
- GPS module part not chosen; not currently part of the ESP32's responsibilities.
- Outdoor/weatherproofing needs for the camera housings not yet discussed.
- Camera FOV mix (standard+wide vs. two standard) not decided, moot until camera #2 is bought.
- Whether "fire"/"load" should stay plain 0–180° servo commands or need different (discrete/latching) semantics — current implementation treats them the same as any other servo.

## Conventions

- Prefer Python for Pi-side capture/control (best support for `picamera2`/`libcamera` and serial/websocket libraries) and for the web backend (FastAPI).
- Keep the video pipeline and the control/HUD pipeline decoupled — each should be developed and tested independently (e.g. the HUD can be built and iterated against simulated ESP32 telemetry via `control/esp32_bridge.py --fake` before real hardware is wired up).
- This project targets real Pi 5 + camera + ESP32 hardware — most of it cannot be fully verified in a dev-machine-only session. Say so explicitly rather than claiming something works when only the code was written, not run on hardware. (The one exception so far: the HUD page + `--fake` control bridge round-trip *has* been exercised end-to-end — sliders/buttons in the browser correctly reach the bridge and reflect back in the canvas readout — see git history for the screenshots that verified it. What hasn't been touched is anything involving actual cameras, GStreamer, MediaMTX, or the ESP32.)
- As run/build commands solidify, document them here (how to start each service, how to test on a dev machine without a Pi attached, systemd unit install steps, etc.).

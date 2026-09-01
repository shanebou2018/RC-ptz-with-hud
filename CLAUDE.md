# CLAUDE.md

This file gives Claude Code (and any other AI assistant) the context needed to work on this project. Update it as the project's architecture and conventions solidify — it should stay a living summary, not a one-time snapshot.

## Project

RC-ptz-with-hud: a Raspberry Pi 5 based pan/tilt/zoom (PTZ) camera rig with a live heads-up display (HUD), built for an RC vehicle or similar remote platform.

Status: **early scaffolding** — the video pipeline, telemetry service, and web HUD have starter implementations (see Repo layout), but none of it has been run against real hardware yet. Treat everything here as the working plan, and correct it as real hardware testing reveals problems.

## Goal

1. **Dual camera capture** on a Raspberry Pi 5, composited as picture-in-picture (PIP) — a main view with a secondary camera inset.
2. **RTSP stream** of the composited video, for viewing in standard RTSP clients (VLC, etc.) and for low-latency remote piloting.
3. **Web page** that shows the same PIP video live in a browser, with the HUD overlay described below.
4. **HUD overlay** rendered on top of the video, showing live telemetry:
   - Servo data (pan/tilt position, and any other servo channels in use)
   - Compass / heading data
   - Speed
   - GPS latitude and longitude

## Key architectural decision: HUD is not burned into the RTSP feed

The HUD is rendered **client-side** on an HTML `<canvas>` layered over the video element on the web page, driven by a live telemetry websocket — it is *not* composited into the video frames. This keeps:

- The RTSP stream clean (for VLC/QGroundControl/any generic RTSP client) with zero HUD-related re-encode cost.
- The HUD independently updatable/restylable without touching the video pipeline.

If HUD-baked-into-video is ever needed (e.g. for DVR recordings), that's an *additional* GStreamer overlay stage layered on later — not part of the initial build.

## Hardware

- **Compute**: Raspberry Pi 5.
- **Cameras**: 2x Raspberry Pi Camera Module 3 (12MP, Sony IMX708, autofocus), one per native CSI port (Pi 5 has two — CAM/DISP0 and CAM/DISP1 — no splitter needed). Mix of standard + wide FOV, or two standard, depending on what each camera is used for. Camera Module 3 ships with a short (~200mm) FPC cable; buy longer (300–500mm) cables separately for chassis routing, and keep spares — these cables are the most fragile part of the build.
  - **Zoom**: start with digital crop (~2–3x usable from the 12MP sensor) — no architecture change needed. Optical/motorized zoom is a different hardware class (own ISP/encoder, usually USB/IP output that would bypass GStreamer compositing) — only pursue if digital crop proves insufficient.
  - **Low light**: if daytime-only, skip NoIR. If night operation is needed, get the NoIR variant plus an external IR illuminator (no onboard IR LEDs on the module).
- **Servo / telemetry controller**: STM32H7 (Nucleo-H743ZI to start) — chosen for independent hardware watchdog (own RC oscillator, separate clock domain), dual-bank flash (safe firmware updates), brownout detection, and hardware timers that drive PWM independent of CPU load (no jitter from a busy WiFi stack, etc). Reads compass/IMU + GPS and drives the pan/tilt servos, then reports state to the Pi over UART.
- **Compass/IMU**: BNO055 or BNO085, on the STM32H7 (I2C), folded into the same UART telemetry stream to the Pi. (Could instead go directly to the Pi over I2C if that's more convenient physically — not yet decided.)
- **GPS**: not yet chosen — needs a UART/I2C GPS module (u-blox NEO-6M/M8N are the easy default) either on the STM32H7 board feeding the same telemetry line, or wired directly to the Pi 5. Speed can come from GPS ground speed and/or motor/wheel telemetry.
- **Pan/tilt servos**: driven by the STM32H7's hardware PWM timers.

Confirm with the user before changing any of the above, and update this section as parts get locked in.

## Video pipeline constraint: Pi 5 has no hardware H.264 encoder

Broadcom pulled the encode block for Pi 5 (decode-only VPU now) — two camera streams + PiP compositing + encode is all CPU (`x264enc` software encode). At 1080p30 x2 this will pin cores. Plan on **720p15–20 per camera** for the PiP composite, or MJPEG if dodging encoder cost matters more than bandwidth.

## Architecture

```
Cam0 (CSI) ──┐
             ├─ libcamera → GStreamer compositor (PiP) → x264enc (software) → rtspclientsink → MediaMTX
Cam1 (CSI) ──┘                                                                                      │
                                                                                     WebRTC (WHEP) out ──► browser <video>
STM32H7 (servo, compass, GPS) ──UART──► Python serial reader ──► websocket ──► canvas HUD overlay on web page
```

- **MediaMTX** (formerly rtsp-simple-server) is the RTSP/WebRTC server — a single pre-built binary, config-only, not something we write. Handles both RTSP consumers (`rtsp://<pi>:8554/robot`) and gives a WebRTC (WHEP) endpoint for the web page (`http://<pi>:8889/robot`) for free.
- **GStreamer** does capture + PiP compositing + encode, and pushes to MediaMTX via `rtspclientsink`. See `pipeline/pip_stream.sh`.
- **Web app** (FastAPI) serves the HUD page: embeds a MediaMTX WHEP video player + a canvas HUD layer on top, driven by telemetry over a websocket. See `web/`.
- **Telemetry service**: a Python asyncio service reading line-delimited JSON off the STM32H7's UART and fanning it out to connected websocket clients. See `telemetry/`.

PiP toggle (swap which camera is the inset) should be done live via the GStreamer `compositor` pads' `xpos`/`ypos`/`width`/`height`/`zorder` properties (dynamic property push), not by rebuilding the pipeline.

## Repo layout

- `pipeline/pip_stream.sh` — GStreamer launch script: dual `libcamerasrc` → `compositor` (PiP layout) → `x264enc` → `rtspclientsink` into MediaMTX.
- `mediamtx/mediamtx.yml` — MediaMTX config (RTSP + WebRTC/WHEP, `robot` path).
- `telemetry/server.py` — reads UART telemetry from the STM32H7, broadcasts line-delimited JSON over a websocket.
- `web/` — FastAPI app serving the HUD page (`web/static/index.html`): WHEP video embed + canvas HUD driven by the telemetry websocket.
- `systemd/` — starter unit files for running MediaMTX, the GStreamer pipeline, the telemetry service, and the web app as services on the Pi.

## Open gaps (confirm before assuming)

- **UART telemetry framing** between the STM32H7 firmware and the Pi-side parser is not finalized — `telemetry/server.py` currently assumes line-delimited JSON (`{"servo":..,"hdg":..,"speed":..,"lat":..,"lon":..}`) as a placeholder. Nail this down with whoever owns the STM32 firmware before it's load-bearing.
- GPS module part not chosen.
- Compass/IMU placement (on STM32H7 vs. direct to Pi I2C) not decided.
- Outdoor/weatherproofing needs for the camera housings not yet discussed.
- Camera FOV mix (standard+wide vs. two standard) not decided.

## Conventions

- Prefer Python for Pi-side capture/telemetry (best support for `picamera2`/`libcamera` and GPIO/I2C libraries) and for the web backend (FastAPI).
- Keep the video pipeline and the telemetry/HUD pipeline decoupled — each should be developed and tested independently (e.g. the HUD can be built and iterated against fake/simulated telemetry before real sensors are wired up; use a small script that fakes the UART JSON stream over the websocket for this).
- This project targets real Pi 5 + camera + STM32 hardware — most of it cannot be fully verified in a dev-machine-only session. Say so explicitly rather than claiming something works when only the code was written, not run on hardware.
- As run/build commands solidify, document them here (how to start each service, how to test on a dev machine without a Pi attached, systemd unit install steps, etc.).

# CLAUDE.md

This file gives Claude Code (and any other AI assistant) the context needed to work on this project. Update it as the project's architecture and conventions solidify — it should stay a living summary, not a one-time snapshot.

## Project

RC-ptz-with-hud: a Raspberry Pi 5 based pan/tilt/zoom (PTZ) camera rig with a live heads-up display (HUD), built for an RC vehicle or similar remote platform.

Status: **greenfield** — no code has been written yet. This file exists ahead of implementation to record the intended goal and shape so future sessions (and the human) stay aligned as pieces get built.

## Goal

1. **Dual camera capture** on a Raspberry Pi 5, composited as picture-in-picture (PIP) — a main view with a secondary camera inset.
2. **RTSP stream** of the composited video, for viewing in standard RTSP clients (VLC, etc.) and for low-latency remote piloting.
3. **Web page** that shows the same PIP video live in a browser, with the HUD overlay described below.
4. **HUD overlay** rendered on top of the video, showing live telemetry:
   - Servo data (pan/tilt position, and any other servo channels in use)
   - Compass / heading data
   - Speed
   - GPS latitude and longitude

## Target hardware (as currently understood)

- Raspberry Pi 5
- Two CSI (or USB) cameras
- Pan/tilt servos (driven via PWM, e.g. through a PCA9685 or the Pi's own PWM)
- A compass/heading sensor (e.g. magnetometer/IMU, such as an HMC5883L, QMC5883L, or a combined IMU)
- A GPS module (for lat/long and speed) — speed may instead/also be derived from GPS ground speed or wheel/motor telemetry
- Exact part numbers and wiring are not yet finalized; confirm with the user before assuming a specific sensor/board and update this section once hardware is locked in.

## Architecture (proposed, not yet implemented)

This is a starting proposal, not a decision — revisit and correct once real implementation begins:

- **Capture & compositing**: `libcamera`/`rpicam-apps` or GStreamer (`gst-launch`/`gstreamer` Python bindings) to pull both camera feeds and composite a PIP layout.
- **RTSP output**: GStreamer `rtspclientsink`, or a dedicated RTSP server such as `mediamtx` fed by a GStreamer/ffmpeg pipeline.
- **Web page**: a small backend (Python, e.g. FastAPI/Flask) serving the page and a telemetry channel (WebSocket or Server-Sent Events) for live servo/compass/speed/GPS values; video shown via an embedded RTSP-to-web bridge (e.g. WebRTC via mediamtx, or an MJPEG fallback) since browsers can't play RTSP natively.
- **HUD rendering**: overlay drawn client-side on an HTML `<canvas>`/SVG layered over the video element, driven by the live telemetry feed — keeps the HUD independent of the video pipeline and easy to restyle.
- **Telemetry sources**: a small Python service reading the compass/GPS/servo state (from I2C/UART/PWM feedback) and publishing it to the web backend.

None of this is committed yet — treat it as a sensible default to start from and change freely as constraints appear (e.g. if RTSP-to-browser latency is a problem, or if the compositing is better done as two independent streams with CSS-based PIP in the browser instead of a server-side composite).

## Conventions

- No language/framework has been chosen yet beyond the proposal above. Prefer Python for Pi-side capture/telemetry (best support for `picamera2`/`libcamera` and GPIO/I2C libraries) unless a strong reason emerges to do otherwise.
- Keep the video pipeline and the telemetry/HUD pipeline decoupled where practical, so each can be developed and tested independently (e.g. HUD can be built against fake/simulated telemetry before real sensors are wired up).
- As real directories, services, and run/build commands appear, document them here (how to run the capture service, the web server, how to test on a dev machine without a Pi attached, etc.).

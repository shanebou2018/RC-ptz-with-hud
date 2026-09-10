# CLAUDE.md

This file gives Claude Code (and any other AI assistant) the context needed to work on this project. Update it as the project's architecture and conventions solidify — it should stay a living summary, not a one-time snapshot.

## Project

RC-ptz-with-hud: a Raspberry Pi 5 based pan/tilt/zoom (PTZ) camera rig with a live heads-up display (HUD), built for an RC vehicle or similar remote platform.

Status: **early scaffolding, moving toward a first bench test**. Current phase: one Pi 5, one camera, an ESP32 driving motors/servos/compass, and the HUD web page — proving out the pipeline end-to-end before the second camera and the full PIP layout get added. None of it has been run against real hardware yet. Treat everything here as the working plan, and correct it as real hardware testing reveals problems.

**This branch (`lora-fpga-control`) is a fork that replaces the ESP32/USB-serial control architecture described below with a base-station-FPGA ↔ LoRa ↔ vehicle-FPGA link — see "Fork: LoRa/FPGA vehicle control architecture" right after "Goal" for the current, divergent architecture. Everything else in this file (video pipeline, HUD rendering, "Serial protocol (Pi ↔ ESP32)", "Motor safety") describes the sibling main-branch architecture and is kept here as reference/historical context, not as this branch's current design — the fork section below is authoritative for anything it covers.**

## Goal

1. **Camera capture** on a Raspberry Pi 5. End goal is **dual camera** composited as picture-in-picture (PIP) — a main view with a secondary camera inset; **current phase is a single camera** (see "Current test phase" below), with PIP compositing added back once a second camera is on hand.
2. **RTSP stream** of the video, for viewing in standard RTSP clients (VLC, etc.) and for low-latency remote piloting.
3. **Web page** that shows the same video live in a browser, with the HUD overlay described below.
4. **HUD overlay** rendered on top of the video, showing live telemetry:
   - Servo data: pan, tilt, focus, zoom, fire, load
   - Drive motor state: left/right direction + PWM
   - Compass / heading data
   - Speed, GPS latitude and longitude (planned — no GPS hardware chosen yet, see Open gaps)

## Fork: LoRa/FPGA vehicle control architecture

**Status: RTL and Python written, fully verified in simulation (14/14 testbenches pass via `fpga/Makefile`'s `make sim`), zero real hardware verification.** No FPGA, radio module, servo, motor, pot, or button in this architecture has ever been touched. Treat every claim below as "internally consistent in simulation," not "works."

**Why this fork exists**: the main branch's video/control both live on one Pi at WiFi range. This fork keeps video/HUD viewing on the Pi over WiFi exactly as the main branch does, but moves **all vehicle control** onto a dedicated long-range LoRa link between two FPGAs, so driving range isn't limited by WiFi. The Pi becomes purely a video + telemetry viewer with **zero control authority** — it never sends a command anywhere in this architecture.

**Architecture**: an Alchitry Cu V2 (Lattice iCE40 HX, 7680 LUTs) at the base station reads operator input and transmits a command packet over a LoRa radio at a steady rate; a second Alchitry Cu V2 on the vehicle receives it and directly drives the 2 drive motors + 6 servos + reads the compass — fully replacing the ESP32's role, with the Pi/browser completely out of the control loop. The vehicle FPGA also feeds telemetry to the Pi over a **separate, one-way UART** purely for HUD display.

```
Base station:                                    Vehicle:
5 pots ──► mcp3008_adc (SPI) ──┐                  E220 LoRa ──► packet_decoder ──► servo_pwm x4, fire_load_pulse x2──► servo_pwm x2 ──► servos
2 buttons ──────────────────────┤─► operator_input_capture                  └──► deadman_timer ──► motor_pwm x2 ──► drive motors
                                 ──► packet_encoder                    ┌──► spi_compass_driver ──► compass
                                 ──► E220 LoRa ══(air)══════════════════════════════► (same link, RX only by default)
                                                                        telemetry_uart_tx ──► Pi (control/vehicle_fpga_bridge.py) ──► websocket ──► browser canvas HUD (view-only, index.html's control surface was removed)
```

**LoRa hardware pivot (real, mid-session correction, not a hypothetical)**: the original plan called for a bare SX127x-family SPI-breakout LoRa module ("no microcontroller anywhere in the radio path"). The user's actual hardware pick, the **EBYTE E220-900T22D**, turned out to be a different chip family (LLCC68, SX1262-compatible SPI) *and*, more importantly, a "smart" module whose SPI is used internally by its own onboard MCU — the host interface is **UART** (default 9600 8N1), not SPI. This is architecturally the same shape of problem as the T-Higrow module rejected earlier in this session, except meaningfully better: the E220's MCU runs EBYTE's own fixed firmware, not custom bridge code the user would need to write. A from-scratch SX127x SPI driver was written, verified in simulation, and then **deleted** once this was discovered; `fpga/common/rtl/e220_driver.v` (UART-based) replaced it. If you see references to SPI/SX127x anywhere outside this note, they're stale.

**Packet protocol** (`fpga/common/rtl/packet_defs.vh`): fixed 12-byte command packet — sync byte, sequence number, pan/tilt/focus/zoom, a flags byte (fire/load triggers + motor directions), 2 motor PWM bytes, a reserved byte, CRC16. The same packet doubles as the heartbeat (sent at a steady rate — no separate lightweight heartbeat format). Payload bytes are XOR-encrypted with a keystream (`fpga/common/rtl/keystream.v`) keyed by a shared secret (`KEYSTREAM_SEED`, currently a placeholder test value — **do not ship it as a real secret**) mixed with the sequence number. **Security note, stated plainly**: the CRC is NOT keyed — it catches accidental corruption but does not prove the sender knew the secret; a receiver with the wrong key still structurally accepts a packet (right sync, right CRC over whatever bytes arrived, non-duplicate sequence) and just decodes it to garbage-but-plausible-looking values rather than rejecting it outright. This scheme defeats passive sniffing and naive replay-of-a-captured-packet; it does **not** defend against active forgery by an attacker who never knew the key (CRC is public/unkeyed, so anyone can construct a structurally-valid packet). A keyed MAC or real AEAD cipher would be needed for that — noted as an open item, not built.

**LUT budget — a real, measured finding**: `make stat-vehicle` (yosys `synth_ice40` against the iCE40 HX8K target, no place-and-route needed for a LUT count) reports **7273 of 7680 SB_LUT4 cells used — 94.7% utilization**, with zero margin for I/O buffer overhead or PnR routing pressure, let alone future features. Root cause, also measured (not guessed): `servo_pwm.v` (×6 instances) and `motor_pwm.v` (×2) dominate, because each instantiates its own constant-divisor division (`/ 180`, `/ 255`) that yosys's default flow implements as a genuine iterative divider rather than a cheap shift-and-add. **Practical consequence: assume a soft RISC-V core (picorv32/PicoSoC) does NOT fit alongside this design as currently written** — pure hand-written RTL is already at 94.7%, with the compass driver's addition eating into what little margin there was. See `fpga/README.md` for the full writeup and the recommended (not yet implemented) fix: replace the divisions with a multiply-by-reciprocal approximation. `operator_input_capture.v`'s own ADC-to-degrees/PWM scaling was written multiply-then-shift from the start specifically to not repeat this mistake — see its header comment. `top_base.v` (with the full 5-pot ADC + 2-button pipeline, no servo/motor PWM generators) synthesizes to 1135 LUTs (14.8%), comfortable.

**Repo layout for this fork**:
- `fpga/common/rtl/` — shared: `packet_defs.vh`, `crc16.v`, `keystream.v`, `uart_engine.v`, `e220_driver.v`.
- `fpga/vehicle/rtl/` — `top_vehicle.v` + `packet_decoder.v`, `deadman_timer.v`, `servo_pwm.v`, `motor_pwm.v`, `fire_load_pulse.v`, `spi_compass_driver.v`, `telemetry_uart_tx.v`. Compass is **SPI**, not I2C — an earlier `i2c_master.v` was deleted once the user asked to standardize on SPI (matching the base station's ADC) rather than mix bus protocols; SPI is also simpler RTL (no open-drain ACK/NACK protocol) and was noticeably less finicky to get right in this session than the I2C version had been. **`spi_compass_driver.v`'s exact register-read convention (MSB=1 for read, matching the SX127x work) is UNCONFIRMED for the real BNO055 part** — both `bosch-sensortec.com` and the Adafruit-hosted datasheet PDF were blocked by this dev environment's network egress, and no secondary source gave the exact SPI byte framing. Confirm against the real datasheet (section 5.4) before trusting it on hardware.
- `fpga/base/rtl/` — `top_base.v` + `packet_encoder.v` + `operator_input_capture.v` + `button_debounce.v` + `mcp3008_adc.v`. Operator input is **hybrid**: 5 potentiometers (pan, tilt, zoom, throttle, turn) via an MCP3008 SPI ADC for the continuous axes, plus 2 pushbuttons (fire/load, debounced via `button_debounce.v`) for the momentary triggers — a pot doesn't make sense for a one-shot fire command. This replaced an earlier all-button design (12 pushbuttons, increment-while-held pan/tilt/zoom, 4-button on/off tank-steer) after the user asked for pot control on the continuous axes; buttons were kept for fire/load since a momentary trigger doesn't map to a pot. Pan/tilt/zoom are `(raw*180)>>10` (tops out at 179, not 180, due to the shift approximation — inconsequential for a hobby pot). Throttle/turn are centered-at-512 pots with a deadzone (`DEADZONE`, default ±20 raw counts) to prevent motor creep, tank-steer mixed continuously (not on/off) and clamped to `MAX_MOTOR_PWM`. The MCP3008's own 3-byte SPI transaction protocol (unlike the compass) **is** well-documented and confidently implemented, not a placeholder guess. Verified in simulation (`tb_button_debounce`, `tb_mcp3008_adc`, `tb_operator_input_capture`) — never tested against real pots/buttons. Two real bugs were caught and fixed via simulation while building this, not shipped blind: `mcp3008_adc.v`'s internal SPI engine sampled `miso` on a different clock cycle than its own byte-completion check for `SPI_CLK_DIV>1`, silently double-counting the last bit of every received byte; and `operator_input_capture.v`'s pan/tilt/zoom scaling initially let Verilog infer the multiply's width from the 8-bit output register, silently truncating the 10-bit ADC reading to 8 bits *before* the multiply (512 truncates to 0) — both fixed by using explicit wide intermediates, the same pattern the throttle/turn math used correctly from the start.
- `fpga/{common,vehicle,base}/sim/` — 14 testbenches, all passing (`make sim`).
- `fpga/{vehicle,base}/constraints/*.pcf` — **placeholder pin files**, every line commented out; real Alchitry Cu V2 pin data was never looked up/confirmed. `make vehicle.bin`/`make base.bin` (full synth→PnR→bitstream) will not succeed until these are filled in.
- `fpga/Makefile`, `fpga/README.md` — build/test flow and the LUT-budget writeup.
- `control/vehicle_fpga_bridge.py` — replaces `control/esp32_bridge.py` on this branch: **telemetry-only**, no inbound command handling at all (verified live: sending it a command over the websocket is silently ignored, telemetry keeps flowing unaffected). Decodes `telemetry_uart_tx.v`'s 14-byte binary frame (its own CRC16 independently cross-checked against the RTL's, same test vector, same result) and re-serializes to the same JSON shape `index.html` already expects.
- `web/static/index.html` — on-screen servo/motor sliders/buttons and all keyboard control handling (arrows/I/O/F/L/WASD/Escape) were **removed** on this branch (a silently-dead control is worse for operator trust than a visibly-absent one) — replaced with a plain "View-only" notice. The canvas HUD telemetry rendering (heading tape, servo readout, motor bars) is unchanged, now fed by the telemetry-only websocket.
- `systemd/rc-hud-control.service` — repointed at `vehicle_fpga_bridge.py`. Note the base station is a **separate physical box** (base FPGA + operator input device) with no Pi and no systemd involvement at all — a real departure from the main branch's single-Pi-centric setup.
- `control/esp32_bridge.py` / `control/esp32_firmware/esp32_firmware.ino` — kept in the branch, **unused** in this architecture (superseded by the FPGA RTL). Kept as reference since their `startPulse`/`updatePulse`/`applyMotor`/deadman-check logic are exactly what the vehicle FPGA's RTL was translated from — useful for side-by-side comparison, not stale cruft to delete casually.

**Open items, not resolved by the code above**:
- **Operator input device at the base station** — resolved: 5 pots (MCP3008 SPI ADC) for pan/tilt/zoom/throttle/turn + 2 pushbuttons for fire/load (see `fpga/base/rtl/operator_input_capture.v`). Still unresolved: the exact physical pot/button hardware/enclosure, and whether `DEADZONE` (±20 raw counts) feels right once real hardware exists — a tunable constant at the top of the file, not yet bench-tuned.
- **BNO055 SPI protocol** — `spi_compass_driver.v` uses an unconfirmed convention (see the repo-layout entry above). Confirm against the real datasheet before hardware use.
- **Real `KEYSTREAM_SEED`** — `fpga/common/rtl/keystream.v`'s current value is a placeholder test constant, not a real secret. Both boards' bitstreams must be built with the same value for their link to decode each other.
- **LUT budget fix** — the division-to-shift-multiply rewrite described above and in `fpga/README.md`, not yet done.
- **Deadman timeout value** — `deadman_timer.v`'s `TIMEOUT_MS` (2000ms) is a placeholder; needs deriving from the real measured LoRa packet rate at whatever spreading factor/bandwidth gets chosen, once real radios exist.
- **Servo behavior on deadman timeout** — currently mirrors the ESP32 (motors force-stop, servos just hold last position). Worth confirming this is still the right call given LoRa's likely-longer exposure time in a link-loss state vs. USB-serial.
- **Real Alchitry Cu V2 pin assignments** — `.pcf` files are placeholders; nothing has been checked against Alchitry's actual pinout reference.
- **`iceprog` vs `openFPGALoader` for flashing** — unverified, no hardware to test against.
- **Frequency band (868MHz EU / 915MHz US)** — must be chosen to match the deployment region and match between both E220 modules; not fixed in the RTL (E220 ships pre-configured per part number, e.g. E220-900T22D vs. a 868MHz variant).
- **Return/link-quality channel from vehicle back to base** — not built (`top_base.v`'s radio never enables RX). Telemetry reaches the Pi via the separate local UART, not over LoRa, by design; a minimal "link OK" indicator at the base station would need its own RX handling and deliberate TX/RX turnaround timing given LoRa's largely half-duplex nature.

## Current test phase: single camera + ESP32 bench test

Before building out the second camera and PIP compositing, the goal is to get one full vertical slice working on real hardware: Pi 5 + one camera + RTSP stream + ESP32 over serial + HUD web page with live compass/servo/motor readout and on-screen controls that actually drive the hardware.

- `pipeline/single_cam_stream.sh` — `rpicam-vid` (libav backend, forced to software `libx264`) pushing RTSP straight to MediaMTX, no compositor.
- Camera #2 is now physically attached, and `pipeline/pip_stream.sh` is **confirmed working on real hardware** — composited PiP video (camera 0 full-frame, camera 1 as a 480×270 inset) confirmed live in VLC. **Dual-camera is now the default**: `systemd/rc-hud-pipeline.service` runs `pip_stream.sh` (with `MAIN_CAM=0`/`INSET_CAM=1`).
- The web HUD (`web/static/index.html`) already includes on-screen sliders/buttons for all 6 servos and both drive motors, wired to the control websocket — so this phase also validates the *control* path (browser → Pi → ESP32), not just telemetry display.

## Key architectural decision: HUD is not burned into the RTSP feed

The HUD is rendered **client-side** on an HTML `<canvas>` layered over the video element on the web page, driven by a live telemetry websocket — it is *not* composited into the video frames. This keeps:

- The RTSP stream clean (for VLC/QGroundControl/any generic RTSP client) with zero HUD-related re-encode cost.
- The HUD independently updatable/restylable without touching the video pipeline.

If HUD-baked-into-video is ever needed (e.g. for DVR recordings), that's an *additional* GStreamer overlay stage layered on later — not part of the initial build.

## Hardware

- **Compute**: Raspberry Pi 5.
- **Cameras**: Plan was Raspberry Pi Camera Module 3 (12MP, Sony IMX708, autofocus); the camera actually connected for the current bench test is an **`ov5647`**-sensor module instead (5MP, no autofocus — detected via `rpicam-hello --list-cameras` on real hardware) — **confirm with the user whether this is a placeholder or the camera being kept**. End goal is 2x, one per native CSI port (Pi 5 has two — CAM/DISP0 and CAM/DISP1 — no splitter needed); **current bench test uses 1**. Mix of standard + wide FOV, or two standard, depending on what each camera is used for, once the second one is bought. Camera Module 3 ships with a short (~200mm) FPC cable; buy longer (300–500mm) cables separately for chassis routing, and keep spares — these cables are the most fragile part of the build.
  - **Zoom**: digital crop from the sensor by default. There's also a physical `zoom` servo in the motor-control list below (for a lens with a mechanical zoom ring) — the two are independent; which one (or both) actually gets used depends on the camera/lens ultimately mounted.
  - **Low light**: if daytime-only, skip NoIR. If night operation is needed, get the NoIR variant plus an external IR illuminator (no onboard IR LEDs on the module).
- **Motor / servo / telemetry controller**: **ESP32** dev board, connected to the Pi 5 over USB serial (115200 baud). This supersedes the previously-planned STM32H7 for the current prototyping phase — the STM32H7's independent watchdog/dual-bank-flash/brownout guarantees are a real loss for eventual field reliability, but the ESP32 (cheap, Arduino-ecosystem, built-in USB-serial) is faster to bench-test with. Revisit STM32H7 later if the reliability case matters more than iteration speed once the rig is past prototyping. See `control/esp32_firmware/esp32_firmware.ino`.
  - **Drive motors**: 2x Cytron-style 2-pin (DIR + PWM) motor controllers, one per side (left/right).
  - **Servos** (6, hobby PWM, 0–180°): **pan**, **tilt**, **focus**, **zoom**, **fire**, **load**. Pan/tilt/focus/zoom are plain absolute-position servos. Fire/load are not — see "Fire/load pulse behavior" below.
  - **Compass/IMU**: wired to the ESP32 over I2C (assumed — not yet confirmed with real wiring), folded into the same serial telemetry stream to the Pi. Firmware currently assumes a BNO055 (`Adafruit_BNO055` library) as a placeholder — swap for whatever part is actually used.
- **GPS**: not yet chosen, and not part of the ESP32's job — needs a UART/I2C GPS module (u-blox NEO-6M/M8N are the easy default), wired directly to the Pi 5 or added to the ESP32 later. Speed can come from GPS ground speed and/or motor/wheel telemetry. Until this exists, the HUD shows a static "not wired up yet" placeholder instead of live GPS/speed.

Confirm with the user before changing any of the above, and update this section as parts get locked in.

## Video pipeline constraint: Pi 5 has no hardware H.264 encoder

Broadcom pulled the encode block for Pi 5 (decode-only VPU now) — camera capture + encode is CPU (software x264), and doubles up once PIP compositing brings a second camera into the same pipeline. At 1080p30 this will pin cores. Plan on **720p15–20 per camera**, or MJPEG if dodging encoder cost matters more than bandwidth.

**Confirmed on real hardware (Debian trixie / Raspberry Pi OS): GStreamer's `rtspclientsink` is not usable.** It ships in GStreamer's Rust plugin set (`gst-plugins-rs`), which Debian trixie's apt repos don't carry as a built package (only unbuilt Rust source crates). `pipeline/single_cam_stream.sh` was rewritten around this: it uses `rpicam-vid`'s built-in `--codec libav` output mode to push RTSP directly, with `--libav-video-codec` forced to `libx264` (software) since that backend's own default, `h264_v4l2m2m`, assumes a hardware encoder Pi 5 doesn't have.

`pipeline/pip_stream.sh` (dual-camera) has been reworked the same way, but since there's no single-process tool that both captures two cameras *and* composites them, it's built differently: two `rpicam-vid` processes (one per camera, `--codec yuv420` raw output) each write into a named pipe, and a single `ffmpeg` process reads both pipes, composites the inset with its `overlay` filter, encodes with software `libx264`, and pushes RTSP via `ffmpeg`'s own RTSP muxer — the same underlying mechanism `rpicam-vid --codec libav` uses internally, which is already proven working on this hardware. GStreamer is no longer used anywhere in the video path. **Confirmed working on real hardware** — composited PiP video live in VLC.

One real bug hit and fixed along the way: the inset camera was initially captured directly at its small on-screen size (320×180). Since 180 isn't a multiple of 16, `rpicam-vid`'s actual raw output almost certainly had row-stride padding that didn't match what `ffmpeg`'s rawvideo demuxer was told to expect — raw video has no self-syncing frame markers, so the byte-offset mismatch corrupted every frame after the first into unreadable blocks. Fixed by capturing the inset at a real supported sensor mode (640×480) and letting `ffmpeg`'s own `scale` filter do the downscale to the on-screen size (`INSET_WIDTH`/`INSET_HEIGHT`, now 480×270) instead — see `INSET_CAP_WIDTH`/`INSET_CAP_HEIGHT` in the script.

## Architecture

```
Cam0 (main, CSI) ──┐
                    ├─ rpicam-vid x2 (raw yuv420, one per cam) ──► named pipes ──► ffmpeg (overlay composite,
Cam1 (inset, CSI) ──┘                                                              software libx264, RTSP push) ──► MediaMTX ──► WebRTC (WHEP) out ──► browser <video>
                                                                                                                                                          ▲
ESP32 (motors, 6 servos, compass) ──USB serial──► Python bridge ──► websocket ──────────────────────────────────────────────────────────────────────────┴──► canvas HUD + on-screen controls
                                     ◄──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘         (commands flow back down)
```

(Single-camera mode — `pipeline/single_cam_stream.sh` — skips the compositing step: one `rpicam-vid --codec libav` process does capture + encode + RTSP push directly.)

- **MediaMTX** (formerly rtsp-simple-server) is the RTSP/WebRTC server — a single pre-built binary, config-only, not something we write. Handles both RTSP consumers (`rtsp://<pi>:8554/robot`) and gives a WebRTC (WHEP) endpoint for the web page (`http://<pi>:8889/robot`) for free.
- **`rpicam-vid`** does the actual camera capture in both scripts. Single-camera: one process handles capture + encode + RTSP push itself (`--codec libav`). Dual-camera: two processes emit raw frames only, and `ffmpeg` does the compositing + encode + RTSP push. **GStreamer is no longer used anywhere in the video path** — both `rtspclientsink` (single-camera) and the old `compositor` + `rtspclientsink` (dual-camera) hit the same missing-Rust-plugin wall on Debian trixie.
- **Web app** (FastAPI) serves the HUD page: embeds a MediaMTX WHEP video player + a canvas HUD layer (compass dial, servo readout, motor bars) + on-screen servo/motor controls, all driven over one websocket. See `web/`.
- **Control/telemetry bridge**: a Python asyncio service that's the single point of contact with the ESP32 over USB serial — bidirectional: ESP32 → Pi telemetry lines get broadcast to every websocket client, and any command a client sends gets written straight to the ESP32. See `control/esp32_bridge.py`.

**PiP camera roles are fixed, not live-swappable.** A live-swap feature was built and shipped (keeping both `rpicam-vid` processes running for `pip_stream.sh`'s entire lifetime and restarting only `ffmpeg` on a `SIGUSR1` signal, with a **P key** in the HUD page triggering it via `POST /api/pip/swap`) — it worked in scripted stub tests (~4ms ffmpeg-only restart, cameras never touched) and even swapped successfully once on real hardware, but **broke the stream on real hardware on a later attempt**: MediaMTX didn't reliably release the old RTSP publish session before the new `ffmpeg` tried to reconnect, leaving the `robot` path unpublished (browser saw `WHEP error 404`) until the whole `rc-hud-pipeline` service was restarted. Given that failure mode, the live-swap feature was **removed** rather than hardened further for now — `pip_stream.sh` goes back to starting both cameras and `ffmpeg` once, with `MAIN_CAM`/`INSET_CAM` fixed for the service's lifetime. To change which camera is main vs. inset, edit `MAIN_CAM`/`INSET_CAM` (in `systemd/rc-hud-pipeline.service` or the environment) and restart the service — no code-level swap right now. If a live swap is wanted again later, it needs a more robust handoff with MediaMTX (e.g. confirming the old RTSP session is torn down, or exploring GStreamer's live pad-property push instead of restarting the RTSP publisher) before shipping it again.

## Serial protocol (Pi ↔ ESP32)

Newline-delimited JSON, one object per line, in both directions over the same USB-serial link. Documented in full in `control/esp32_bridge.py`'s module docstring and implemented in `control/esp32_firmware/esp32_firmware.ino`.

**Pi → ESP32 (commands):**
```
{"type": "servo", "name": "pan", "pos": 90}      // name: pan|tilt|focus|zoom, pos: 0-180
{"type": "servo", "name": "fire"}                // name: fire|load — pos ignored, triggers a pulse (see below)
{"type": "motor", "side": "l", "dir": 1, "pwm": 180}   // side: l|r, dir: 0|1, pwm: 0-255
```

**ESP32 → Pi (telemetry, emitted ~10Hz):**
```
{"hdg": 123.4, "servo": {"pan":90,"tilt":45,"focus":0,"zoom":0,"fire":0,"load":0},
 "motor": {"l": {"dir":1,"pwm":0}, "r": {"dir":1,"pwm":0}}}
```

This is a first draft, not yet validated against real ESP32 firmware behavior on hardware — treat field names/ranges as easy to change once real testing starts.

The web page also sends a `{"type": "ping"}` heartbeat every 200ms while its control socket is open — see "Motor safety" below for why.

## Fire/load pulse behavior

Fire and load aren't plain position servos — they idle at **0°**, and any command triggers a one-shot, non-blocking swing-out-and-return:

- **Fire**: 0° → **40°**, hold, → back to 0°
- **Load**: 0° → **120°**, hold, → back to 0°
- Hold duration: `PULSE_HOLD_MS` (500ms), tunable at the top of `esp32_firmware.ino`
- A command that arrives while a pulse is already in flight is ignored (button semantics, not a toggle)

This is implemented **on the ESP32 itself** (`startPulse()`/`updatePulse()` in `esp32_firmware.ino`, tracked via `millis()`, no `delay()` calls) rather than as two separately-timed commands sent from the Pi/browser — that way the sequence completes reliably even if the Pi or the browser's websocket connection hiccups mid-pulse. `control/esp32_bridge.py`'s `--fake` mode mirrors the same behavior (`FIRE_PULSE_ANGLE`/`LOAD_PULSE_ANGLE`/`PULSE_HOLD_S`) via an asyncio task, so it previews correctly without hardware. The web page's `triggerPulse()` just sends the single trigger command; the "active" highlight on the on-screen FIRE/LOAD buttons is cosmetic click-feedback only — the canvas HUD's FIRE/LOAD status pills are the real indicator, driven by live telemetry.

Verified against `--fake` with a scripted websocket client: trigger → immediately reads back the pulse angle, a retrigger while mid-pulse is ignored, and it returns to 0 at ~0.5s. Not yet run against a real servo.

## Keyboard controls (web page)

In addition to the on-screen sliders/buttons, `web/static/index.html` binds:

- **Arrow keys** — pan (left/right) / tilt (up/down), continuous while held (`PAN_TILT_STEP_DEG` per `KEY_TICK_MS`, both tunable constants near the top of the script)
- **I / O** — zoom in/out, same continuous-while-held behavior
- **F / L** — fire/load, momentary: one press sends the trigger command (see "Fire/load pulse behavior" above — the ESP32 itself owns the actual swing-and-return timing), ignoring OS key-repeat so holding the key doesn't send it repeatedly. The on-screen FIRE/LOAD buttons use the same `triggerPulse()` function, so mouse and keyboard behave identically.
- **W A S D** — tank-steer drive, mixed each tick from whichever keys are currently held (`left = forward + turn`, `right = forward - turn`, clamped to ±1) and scaled by the new **Speed** slider in the DRIVE panel. Releasing all drive keys sends one final stop command.
- **Escape** — immediate stop, same as the on-screen "All stop" button. Implemented as a `driveLocked` flag rather than just clearing the held-keys set: a still-physically-held drive key keeps firing `keydown` events with `repeat: true` from the OS, and merely deleting it from the held-keys set would just let the very next repeat event silently re-add it and resume driving a moment later. `driveLocked` instead blocks drive output outright until every drive key has produced a real `keyup` (which repeat events don't). Verified with a Playwright test that dispatches synthetic `repeat: true` keydown events to confirm the stop actually holds.

All of this updates the same on-screen sliders it would if you'd dragged them by hand (shared `setServo()`/`setMotor()` helpers), so the UI never gets out of sync with what's actually being sent. Losing window focus (e.g. alt-tab) clears all held keys and the drive lock, so a stuck key can't leave a motor running.

## Planned enhancements (not yet built)

Deliberately deferred until the ESP32 is wired up and testable against real hardware, rather than only `--fake`:

- **Gamepad support** (Web Gamepad API) — WASD is on/off, so drive is always full-speed-or-nothing even with the Speed slider; an analog stick would let throttle/turn be feathered continuously.
- **Auto-reconnect** for the video (WHEP) and control websocket — right now a dropped connection just shows "offline"/"control offline" and sits there; a few seconds of automatic retry would make the HUD meaningfully more trustworthy to actually drive with.
- **Pan/tilt center/trim preset** — a key (e.g. `C`) that snaps pan/tilt back to 90/90 instantly, useful after a bunch of arrow-key nudging.

## Motor safety

Two independent safeguards on the drive motors, each with its own tunable constant kept at the top of its file (and kept in sync across all three, called out in each one's comment):

- **`MAX_MOTOR_PWM`** (`esp32_firmware.ino`, `esp32_bridge.py`, `index.html`; currently `200`/255) — hard ceiling on drive PWM, enforced authoritatively by the firmware regardless of what a command asks for. Start low and raise once direction/wiring are confirmed safe.
- **`COMMAND_TIMEOUT_MS` / `COMMAND_TIMEOUT_S`** (`esp32_firmware.ino`, `esp32_bridge.py`; currently `500ms`) — deadman switch: if no command line (including a heartbeat ping) has arrived in this long, both drive motors are forced to stop. The **ESP32 firmware's own copy is the authoritative one** — it still protects the rig even if the Pi crashes or the USB link dies. `esp32_bridge.py --fake` implements an equivalent watchdog purely so the fake mode previews real behavior; it doesn't apply to the real serial connection since the firmware already handles that independently.
- The web page's `HEARTBEAT_INTERVAL_MS` (currently `200ms`, must stay well under `COMMAND_TIMEOUT_MS`) keeps sending `{"type":"ping"}` as long as the control socket is open, so a motor deliberately held at a non-zero speed doesn't get cut just because no slider is actively moving.
- `esp32_bridge.py` also sends an explicit stop-both-motors command the instant the last websocket client disconnects (`ws_handler`'s `finally` block) — a faster path than waiting on the firmware's own timeout, for the common case of "browser tab closed."

None of this has been exercised against real motors — it's been verified against `--fake` (PWM clamping, deadman timeout, heartbeat keepalive, and disconnect-triggers-stop all checked with a scripted websocket client) and against the real HUD page's sliders in a browser. Confirm it behaves the same once real motors are wired up, and re-check `MAX_MOTOR_PWM` against what your drivetrain can actually handle safely.

## Repo layout

- `pipeline/single_cam_stream.sh` — single-camera capture/encode script (current bench-test phase). **Verified working on real Pi 5 hardware** — camera → MediaMTX → VLC over RTSP confirmed live.
- `pipeline/pip_stream.sh` — dual-camera PiP capture/composite/encode script (2x `rpicam-vid` raw → named pipes → `ffmpeg` scale + overlay + encode + RTSP push). Reworked off GStreamer, per "Video pipeline constraint" above — **confirmed working on real hardware** (PiP video live in VLC, 480×270 inset).
- `mediamtx/mediamtx.yml` — MediaMTX config (RTSP + WebRTC/WHEP, `robot` path).
- `control/esp32_bridge.py` — bidirectional Pi ↔ ESP32 bridge: serial ↔ websocket, plus a `--fake` mode that simulates the ESP32 in-process for HUD development without hardware.
- `control/esp32_firmware/esp32_firmware.ino` — ESP32 sketch: drives the 2 drive motors + 6 servos, reads the compass, speaks the serial protocol above. **Not yet compiled or run on hardware.**
- `web/` — FastAPI app serving the HUD page (`web/static/index.html`): WHEP video embed, canvas HUD (compass dial, servo readout, motor bars), and on-screen servo/motor controls, all over the control websocket. Just serves the static page — no other HTTP endpoints right now.
- `systemd/` — starter unit files for running MediaMTX, the camera pipeline, the ESP32 control bridge, and the web app as services on the Pi.

## Open gaps (confirm before assuming)

- **Pinout in `esp32_firmware.ino`** is a first guess, not a wiring decision — confirm against actual wiring before flashing.
- **Compass part** not chosen; firmware assumes a BNO055 as a placeholder.
- **Serial protocol** above is a first draft, unvalidated against real firmware/hardware behavior.
- GPS module part not chosen; not currently part of the ESP32's responsibilities.
- Outdoor/weatherproofing needs for the camera housings not yet discussed.
- Camera #2 is now physically attached (both are `ov5647`, same sensor — confirm whether that's the final pair or one/both get swapped for something else later, and whether a standard+wide FOV mix is still wanted).
- **`MAX_MOTOR_PWM` (200) and `COMMAND_TIMEOUT_MS` (500ms)** in "Motor safety" above are starting guesses, not validated against a real drivetrain — re-check both once real motors are wired up.
- **Fire/load pulse angles (40°/120°) and hold time (500ms)** in "Fire/load pulse behavior" above are first guesses from the user, not yet checked against the actual mechanism they're driving (a linkage, a trigger, etc.) — confirm once wired up.

## Conventions

- Prefer Python for Pi-side capture/control (best support for `picamera2`/`libcamera` and serial/websocket libraries) and for the web backend (FastAPI).
- Keep the video pipeline and the control/HUD pipeline decoupled — each should be developed and tested independently (e.g. the HUD can be built and iterated against simulated ESP32 telemetry via `control/esp32_bridge.py --fake` before real hardware is wired up).
- This project targets real Pi 5 + camera + ESP32 hardware — most of it cannot be fully verified in a dev-machine-only session. Say so explicitly rather than claiming something works when only the code was written, not run on hardware. Verified so far on real Pi 5 hardware: both the single-camera (`pipeline/single_cam_stream.sh`) and dual-camera PiP (`pipeline/pip_stream.sh`, fixed camera roles) capture/encode/RTSP pipelines, camera(s) → MediaMTX → VLC, confirmed live video; **and the full HUD web page itself** — MediaMTX's WHEP video embed showing live camera video in-browser, plus the control websocket, canvas HUD (compass/servo/motor readout), and on-screen controls all working end-to-end against `control/esp32_bridge.py --fake` running on the Pi. What hasn't been touched yet: the ESP32 firmware/serial link (still simulated via `--fake`).
- Running the full stack takes 4 separate long-running processes at once (MediaMTX, the camera pipeline, the ESP32 bridge, the web app) — each needs its own terminal/session left untouched, since typing a new command into one of these windows kills whatever was running there. This tripped up the first hardware bench test; `systemd/*.service` exists specifically to avoid this manual juggling once things are stable enough to run unattended.
- **The systemd units are installed and confirmed working on the bench-test Pi**: all 4 services (`rc-hud-mediamtx`, `rc-hud-pipeline`, `rc-hud-control`, `rc-hud-web`) enabled and running, and verified to survive a full `sudo reboot` — video + the (still `--fake`) HUD both come up automatically with zero manual terminal work. The unit files in `systemd/` are hardcoded to this specific Pi's real setup (user `admincam`, repo at `/home/admincam/RC-ptz-with-hud`, MediaMTX at `/home/admincam/mediamtx`) rather than generic placeholders, since they're meant to be installed as-is on this rig.
- As run/build commands solidify, document them here (how to start each service, how to test on a dev machine without a Pi attached, systemd unit install steps, etc.).

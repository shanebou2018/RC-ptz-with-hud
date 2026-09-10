# ESP32 + LoRa vehicle control -- demo code

Second attempt at long-range vehicle control on this branch. The first
attempt (`fpga/` -- two Alchitry Cu V2 FPGAs, custom Verilog SX127x/E220
drivers, hand-written packet protocol) hit a real LUT budget wall
(94.7% utilization on the vehicle side) and is **not deleted, but
superseded** -- see `CLAUDE.md`'s fork section for that history. This
directory + its two sibling sketch folders are the new plan: swap the
FPGAs for ESP32s (much more LUT/logic headroom isn't a concern at all,
since it's a general-purpose MCU, not fixed logic fabric), keep the LoRa
link, add a PlayStation 2 controller and an OLED status display at the
base station.

**Status: demo code only.** Written and reasoned through, never compiled
(no Arduino/ESP32 toolchain in the dev sandbox this was written in) or
run against any real hardware -- no ESP32, E220 module, PS2 controller,
OLED, servo, or motor controller in this architecture has been touched.
Every pin assignment, library API call, stick-axis sign, and timing
constant is a first guess. Follow this project's usual convention: don't
trust any of it until it's actually been bench-tested.

## Layout

```
control/lora_esp32_shared/       This folder -- install as an Arduino library
  library.properties
  src/lora_packet.h              Command packet (base->vehicle) + telemetry
                                  frame (vehicle->Pi) formats, shared by both
                                  sketches below. Single source of truth --
                                  same role fpga/common/rtl/packet_defs.vh
                                  played for the FPGA attempt.
control/lora_vehicle_esp32/
  lora_vehicle_esp32.ino         Drives 6 servos + 2 drive motors. Receives
                                  commands over E220 LoRa. Sends telemetry to
                                  the Pi over USB serial.
control/lora_base_esp32/
  lora_base_esp32.ino            Reads a PS2 controller, shows status on an
                                  OLED, sends commands over E220 LoRa. A
                                  separate physical box -- no Pi involved.
```

## Install

1. Copy (or symlink) `control/lora_esp32_shared/` into your Arduino
   `libraries/` directory (e.g. `~/Arduino/libraries/lora_packet`) so both
   sketches can `#include <lora_packet.h>`.
2. Install these libraries via the Arduino Library Manager:
   - `ESP32Servo` (vehicle sketch)
   - `PS2X_lib` -- search "PS2X" (base sketch)
   - `Adafruit SSD1306` + `Adafruit GFX Library` (base sketch; pulls in
     `Adafruit BusIO` as a dependency)
3. Open `control/lora_vehicle_esp32/lora_vehicle_esp32.ino` and
   `control/lora_base_esp32/lora_base_esp32.ino` directly in the Arduino
   IDE (each is its own sketch) and flash each to its own ESP32.

## What's real vs. assumed here

**Reused from already-more-vetted code, not reinvented:**
- The vehicle sketch's servo/motor/fire-load-pulse/deadman logic is a
  direct port of `control/esp32_firmware/esp32_firmware.ino` (main
  branch) -- same constants, same non-blocking pulse state machine.
- The vehicle->Pi telemetry frame is byte-identical to
  `fpga/vehicle/rtl/telemetry_uart_tx.v`'s format, which
  `control/vehicle_fpga_bridge.py` already decodes -- **that script keeps
  working unchanged** against this new firmware; only its `--port` needs
  to point at the vehicle ESP32's USB-serial device.
- The CRC16/CCITT-FALSE implementation matches
  `control/vehicle_fpga_bridge.py`'s `crc16_ccitt_false()` and the FPGA
  fork's `fpga/common/rtl/crc16.v` exactly (same algorithm, third
  independent implementation).

**New/first-guess in this pass, not yet validated:**
- The base<->vehicle command packet is plaintext (no XOR keystream, unlike
  the FPGA fork's `packet_defs.vh`) -- deliberate, to keep the first link
  bring-up easy to sniff/debug. Add encryption back as a fast-follow once
  the plaintext link is proven on real hardware, not before.
- Every pin assignment (see each `.ino`'s header comment).
- `PS2X_lib`'s exact method signatures (`config_gamepad`,
  `read_gamepad`, `Analog`, `Button`, `ButtonPressed`) -- written from
  general knowledge of that library, not checked against an installed
  copy.
- Stick-axis sign conventions (which way is "forward", which way pans
  right) -- flagged inline in `lora_base_esp32.ino`, expect to flip some
  signs once you can actually watch it move.
- `LORA_CMD_SEND_INTERVAL_MS` (100ms/10Hz) and the vehicle's
  `COMMAND_TIMEOUT_MS` (1000ms) -- bench-test starting points for
  short-range/high-air-rate bring-up. Real long-range LoRa settings (high
  spreading factor) will need both slowed down together -- same
  unresolved bench-tuning question the FPGA fork's plan left open.
- No compass/IMU in this pass -- it wasn't in the hardware list this was
  built from. The telemetry frame's heading field is a static 0
  placeholder; wire one up (I2C or SPI, matching the pattern
  `esp32_firmware.ino`/`fpga/vehicle/rtl/spi_compass_driver.v` used) if
  live heading on the HUD is wanted.
- No return/link-quality channel from vehicle to base (same open item the
  FPGA fork never resolved) -- the base station's OLED "TX: sending"
  line means "we attempted a send recently," not "the vehicle received
  it."

## E220-900T22D one-time setup (not done by either sketch)

Both E220 modules must already be configured with matching channel,
address, and air data rate -- via EBYTE's `RF_Setting` config tool or AT
commands sent while the module is in config mode (`M0=1`, `M1=1`) --
before either sketch's normal-mode (`M0=0`, `M1=0`) transparent
transmission will talk to anything. Neither `.ino` does this
configuration itself; it's a one-time step you do before flashing.

# fpga/ -- LoRa/FPGA vehicle control fork

RTL for the base-station and vehicle-side Alchitry Cu V2 boards. See the
`## Fork: LoRa/FPGA vehicle control architecture` section of the repo's
top-level `CLAUDE.md` for the full picture (why this exists, what it
replaces, open questions). This file is the toolchain/build/test
reference.

## Toolchain

Confirmed installable and working in this project's dev environment
(Ubuntu, `apt-get install`):
- `iverilog` (Icarus Verilog) -- simulation
- `yosys` -- synthesis
- `nextpnr-ice40` + `fpga-icestorm` (`icepack`, etc.) -- place & route, bitstream packing

**Not verified**: `iceprog`/`openFPGALoader` (flashing) -- no real
Alchitry Cu V2 hardware was available in this dev environment. Try
`openFPGALoader` first when real hardware is on hand; it has broader
support for non-reference boards than raw `iceprog` and is more likely to
"just work" against the Cu V2's onboard USB-serial/FTDI interface, but
this is a guess, not a confirmed fact.

## Running the tests

```
make sim
```

Runs all 14 testbenches under `common/sim/`, `vehicle/sim/`, `base/sim/`.
As of this writing, all 14 pass:

- `tb_crc16` -- CRC-16/CCITT-FALSE against the standard test vector, plus a corruption-detection check
- `tb_keystream` -- determinism, seed/seq sensitivity, XOR round-trip, wrong-seed-fails-to-recover
- `tb_packet_roundtrip` -- full encode/decode round trip: servo/motor fields, fire trigger, duplicate-packet rejection, corrupted-packet rejection, and the documented wrong-key behavior (structurally accepted, garbage payload -- see `packet_defs.vh`'s security note)
- `tb_servo_pwm`, `tb_motor_pwm` -- pulse width / duty cycle timing, clamping, `safe_stop` gating
- `tb_fire_load_pulse` -- trigger timing, retrigger-while-active ignored
- `tb_deadman_timer` -- timeout assertion/clearing
- `tb_uart_engine`, `tb_e220_driver` -- UART loopback, and a full driver+driver (via two bench "radio" models) round trip in both directions
- `tb_spi_compass_driver` -- full 3-byte read transaction against a bench SPI compass model
- `tb_telemetry_uart_tx` -- frame layout, field values, CRC, against a plain UART receiver
- `tb_button_debounce` -- bounce rejection, sustained-press registration, release
- `tb_mcp3008_adc` -- full round-trip against a bench MCP3008 model across all 5 channels, continuous polling
- `tb_operator_input_capture` -- pan/tilt/zoom ADC-to-degrees scaling, throttle/turn deadzone + tank-steer mixing (forward, reverse, pivot-turn), fire/load one-packet-per-press timing (including that a second `send_pulse` without a new press doesn't re-fire)

None of this is hardware verification -- it proves the RTL's logic is
internally consistent, not that it works against a real SX-family radio,
real servos, or a real Pi. Treat every module as unverified against real
hardware until it's actually bench-tested, per this project's usual
convention.

## LUT budget -- a real finding, not a guess

The plan called for an actual post-synthesis check rather than an
a-priori estimate of whether this fits the Alchitry Cu V2's iCE40 HX 7680
logic cells. That check has now been run:

```
make stat-vehicle
```

**Result: 7273 SB_LUT4 cells out of 7680 available -- 94.7% LUT
utilization** (only 407 LUTs of headroom left), with no place-and-route
margin, I/O buffer overhead, or future-feature headroom accounted for
yet. This got *tighter*, not looser, once the compass moved from I2C to
SPI: the SPI driver's own bit-bang engine (261 cells in isolation) is
larger than the I2C driver it replaced was (171 cells), and the switch
cost more than that difference alone once resynthesized as part of the
whole design (6993 -> 7273, a net +280 cells) -- global synthesis
optimization doesn't sum module costs linearly. This is far tighter than
comfortable, and getting tighter with each addition.

**Root cause, also measured, not guessed**: `servo_pwm.v` (1921 cells
per instance x6 instances) and `motor_pwm.v` (1562 cells per instance x2
instances) dominate the total. Both compute their PWM duty cycle with a
runtime division by a constant (`/ 180` in `servo_pwm.v`, `/ 255` in
`motor_pwm.v`) -- `yosys`'s default synthesis flow appears to implement
this as a genuine iterative divider (each instance shows ~700+ `SB_CARRY`
cells, consistent with a ripple-carry restoring divider) rather than the
much cheaper shift-and-add constant-multiply-by-reciprocal a hand-tuned
implementation would use. `spi_compass_driver.v`, `packet_decoder.v`,
`e220_driver.v`, `telemetry_uart_tx.v`, `deadman_timer.v`, and
`fire_load_pulse.v` are all individually small (122-712 cells each) --
they are not the problem. `operator_input_capture.v`'s own ADC-to-degrees/
PWM scaling was deliberately written multiply-then-shift from the start
(see its header comment) specifically to not add to this problem.

`top_base.v` (no servo/motor PWM instances at all -- with the full
5-pot-ADC + 2-button `operator_input_capture.v`/`mcp3008_adc.v`/
`button_debounce.v` pipeline wired in) synthesizes to 1135 LUTs -- 14.8%
utilization, still comfortable.

**Recommended next step, not yet done**: replace the `/ 180` and `/ 255`
divisions in `servo_pwm.v`/`motor_pwm.v` with a multiply-by-reciprocal
approximation (e.g. `(x * 364) >> 16` approximates `x / 180`), which
should synthesize as a small shift-add network instead of a full divider
and free most of that budget. This needs care to avoid rounding errors
breaking the exact pulse-width values the existing testbenches check for
(a naive version was prototyped by hand during this session and did
shift results off by 1 tick at some inputs) -- worth doing properly with
its own verification pass, not as a rushed find-and-replace. Until that's
done, **do not assume a soft RISC-V core (open question 1 in the plan)
fits alongside this design** -- at 94.7% utilization with pure hand-written
RTL, there is essentially no room left for a picorv32 core and its
supporting RAM/peripherals. This makes the soft-core-vs-pure-RTL open
question largely moot until the division cost is addressed: pure RTL is
barely fitting as-is (and margin has been shrinking with each real
addition, not growing), so a soft core is very unlikely to fit at all
without the same optimization first.

## Building a real bitstream (not yet possible end-to-end)

```
make vehicle.bin    # or: make base.bin
```

This runs the full `yosys` -> `nextpnr-ice40` -> `icepack` flow, but
`vehicle/constraints/alchitry_cu_v2_vehicle.pcf` and
`base/constraints/alchitry_cu_v2_base.pcf` are **placeholders** -- every
pin assignment in them is commented out pending real pin data from
Alchitry's own Cu V2 pinout reference. Fill those in before expecting
`nextpnr-ice40` to succeed.

## Payload encryption key

`common/rtl/keystream.v`'s `KEYSTREAM_SEED` is a placeholder test value
(`32'hC0FFEE42`) baked into the shared header -- **do not ship this as a
real secret**. Both `base/rtl/top_base.v` and `vehicle/rtl/top_vehicle.v`
reference the same `` `KEYSTREAM_SEED `` macro, so it only needs changing
in one place (`common/rtl/keystream.v`) before building real bitstreams
for a given vehicle/base pair -- but that means the two boards' bitstreams
must be built from matching source (or the macro overridden identically)
for their LoRa link to decode each other's packets. See `packet_defs.vh`
for what this scheme does and doesn't protect against.

## Sequencing (from the plan -- where things actually stand)

0. Toolchain bring-up (LED blink through the full flow) -- **not done**, no hardware.
1. SPI/UART bring-up to the radio module -- **not done**, no hardware. (Note: the plan originally called this "SPI bring-up" against an SX127x part; the LoRa module changed to the E220-900T22D over UART mid-implementation -- see CLAUDE.md's fork section.)
2. LoRa loopback between two boards -- **not done**, no hardware.
3. Packet protocol -- **done in simulation** (`tb_packet_roundtrip`), not on real radios.
4. Vehicle-side actuation bench test -- **done in simulation** (`tb_servo_pwm`, `tb_motor_pwm`, `tb_fire_load_pulse`), not against real servos/motors.
5. Deadman timer integration -- **done in simulation** (`tb_deadman_timer`), not against a real link.
6. Telemetry link to the Pi -- RTL + `control/vehicle_fpga_bridge.py` both written and independently tested (`tb_telemetry_uart_tx`, and the Python side has its own CRC/framing logic mirroring the RTL); the two have never talked to each other over a real UART.
7. Base station operator input -- **done in simulation** (`tb_button_debounce`, `tb_mcp3008_adc`, `tb_operator_input_capture`): 5 pots (MCP3008 SPI ADC) for pan/tilt/zoom/throttle/turn, continuously scaled; 2 debounced pushbuttons for fire/load (momentary). Real hardware (actual pots/buttons, actual `DEADZONE` feel) not tested.
8. HUD control-surface cleanup -- done (see CLAUDE.md's fork section and `web/static/index.html`).
9. Full integration bench test -- **not done**, no hardware.
10. Optional return channel -- **not built**, per the plan's open question 5 (no RX path on the base station's radio in the current design).

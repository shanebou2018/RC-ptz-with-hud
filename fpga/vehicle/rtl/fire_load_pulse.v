// Direct RTL port of esp32_firmware.ino's startPulse()/updatePulse():
// idle at position 0; a trigger pulse swings the servo to ANGLE, holds
// for PULSE_HOLD_MS, then returns to 0. A trigger arriving while already
// active is ignored (button semantics, not a toggle/retrigger) -- this is
// the cleanest 1:1 port of any module in the vehicle FPGA design.
// Instantiated x2 in top_vehicle.v: one with ANGLE=40 (fire), one with
// ANGLE=120 (load), matching esp32_firmware.ino's FIRE_PULSE_ANGLE/
// LOAD_PULSE_ANGLE. Output feeds directly into a servo_pwm instance's
// `pos` input.
module fire_load_pulse #(
  parameter CLK_FREQ_HZ   = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter PULSE_HOLD_MS = 500,
  parameter ANGLE         = 40
)(
  input  wire       clk,
  input  wire       rst,
  input  wire       trigger,   // one-cycle pulse (from packet_decoder.v's fire_pulse/load_pulse)
  output reg  [7:0] servo_pos, // 0 when idle, ANGLE while a pulse is in flight
  output reg         active
);
  localparam integer HOLD_TICKS = (CLK_FREQ_HZ / 1000) * PULSE_HOLD_MS;
  localparam CNT_WIDTH = $clog2(HOLD_TICKS + 1);

  reg [CNT_WIDTH-1:0] counter;

  always @(posedge clk) begin
    if (rst) begin
      active    <= 1'b0;
      servo_pos <= 8'd0;
      counter   <= 0;
    end else if (trigger && !active) begin
      active    <= 1'b1;
      servo_pos <= ANGLE[7:0];
      counter   <= 0;
    end else if (active) begin
      if (counter >= HOLD_TICKS - 1) begin
        active    <= 1'b0;
        servo_pos <= 8'd0;
      end else begin
        counter <= counter + 1'b1;
      end
    end
  end
endmodule

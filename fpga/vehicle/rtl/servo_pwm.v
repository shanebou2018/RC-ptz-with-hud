// 50Hz hobby-servo PWM generator: position 0-180 -> a 1ms-2ms pulse width
// (standard hobby servo convention), instantiated x6 in top_vehicle.v for
// pan/tilt/focus/zoom/fire/load.
//
// CLK_FREQ_HZ defaults to the Alchitry Cu V2's stated onboard 100MHz
// oscillator -- UNVERIFIED as the actual clock this logic runs at (the
// oscillator commonly feeds a PLL that generates the fabric clock, which
// may differ); confirm on real hardware (open question 6 in the fork's
// CLAUDE.md section) before trusting the exact pulse timing, and override
// the parameter here if the real fabric clock differs.
module servo_pwm #(
  parameter CLK_FREQ_HZ   = 100_000_000,
  parameter PERIOD_US     = 20_000,  // 50Hz
  parameter PULSE_MIN_US  = 1_000,   // pulse width at position 0
  parameter PULSE_MAX_US  = 2_000    // pulse width at position 180
)(
  input  wire       clk,
  input  wire       rst,
  input  wire [7:0] pos,      // 0-180; values above 180 are clamped (mirrors esp32_firmware.ino's constrain())
  output reg         pwm_out
);
  localparam integer TICKS_PER_US      = CLK_FREQ_HZ / 1_000_000;
  localparam integer PERIOD_TICKS      = PERIOD_US * TICKS_PER_US;
  localparam integer PULSE_MIN_TICKS   = PULSE_MIN_US * TICKS_PER_US;
  localparam integer PULSE_RANGE_TICKS = (PULSE_MAX_US - PULSE_MIN_US) * TICKS_PER_US;
  localparam CNT_WIDTH = $clog2(PERIOD_TICKS);

  reg [CNT_WIDTH-1:0] counter;
  wire [7:0]  pos_clamped = (pos > 8'd180) ? 8'd180 : pos;
  wire [31:0] pulse_ticks = PULSE_MIN_TICKS + (pos_clamped * PULSE_RANGE_TICKS) / 180;

  always @(posedge clk) begin
    if (rst) begin
      counter <= 0;
      pwm_out <= 1'b0;
    end else begin
      if (counter >= PERIOD_TICKS - 1)
        counter <= 0;
      else
        counter <= counter + 1'b1;
      pwm_out <= (counter < pulse_ticks);
    end
  end
endmodule

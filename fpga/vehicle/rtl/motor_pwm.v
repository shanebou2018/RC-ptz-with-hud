// Drive-motor DIR + PWM duty-cycle output for a Cytron-style 2-pin motor
// controller, instantiated x2 in top_vehicle.v (left/right). Duty cycle
// is a plain fraction-of-period PWM (unlike servo_pwm.v's fixed 1-2ms
// pulse convention) -- PWM_FREQ_HZ's default (20kHz) is a common choice
// to stay above the audible range, but hasn't been checked against the
// actual Cytron driver model's datasheet max input PWM frequency; treat
// as unverified until confirmed.
//
// MAX_MOTOR_PWM is hard-clamped here in RTL (same ceiling value/spirit as
// esp32_firmware.ino's applyMotor()) as a second line of defense --
// packet_decoder.v already clamps it once on receipt, this clamps again
// at the point of actual output generation. safe_stop (driven by
// deadman_timer.v) forces pwm_out low regardless of pwm_level -- this is
// the module that actually executes the deadman stop, independent of
// whatever command_registers currently holds.
`include "packet_defs.vh"

module motor_pwm #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter PWM_FREQ_HZ = 20_000
)(
  input  wire       clk,
  input  wire       rst,
  input  wire       dir_in,
  input  wire [7:0] pwm_level,  // 0-255 requested duty; clamped to MAX_MOTOR_PWM below
  input  wire       safe_stop,  // deadman_timer.v's SAFE_STOP
  output reg         dir_out,
  output reg         pwm_out
);
  localparam integer PERIOD_TICKS = CLK_FREQ_HZ / PWM_FREQ_HZ;
  localparam CNT_WIDTH = $clog2(PERIOD_TICKS);

  reg [CNT_WIDTH-1:0] counter;
  wire [7:0]  level_clamped = (pwm_level > `MAX_MOTOR_PWM) ? `MAX_MOTOR_PWM : pwm_level;
  wire [15:0] duty_ticks    = (level_clamped * PERIOD_TICKS) / 8'd255;

  always @(posedge clk) begin
    if (rst) begin
      counter <= 0;
      pwm_out <= 1'b0;
      dir_out <= 1'b0;
    end else begin
      dir_out <= dir_in;
      if (counter >= PERIOD_TICKS - 1)
        counter <= 0;
      else
        counter <= counter + 1'b1;
      pwm_out <= safe_stop ? 1'b0 : (counter < duty_ticks);
    end
  end
endmodule

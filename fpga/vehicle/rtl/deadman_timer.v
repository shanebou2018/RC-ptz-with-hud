// Counts elapsed time since the last VALID packet (packet_decoder.v's
// cmd_valid pulse -- deliberately tied to a passing sync/CRC/freshness
// check, not merely "anything received", so RF noise or a corrupted
// packet doesn't reset the clock). On timeout, asserts safe_stop, which
// motor_pwm.v uses to force both drive motors to 0 regardless of
// command_registers -- this module is the vehicle FPGA's authoritative
// safety owner, the direct equivalent of esp32_firmware.ino's
// COMMAND_TIMEOUT_MS check in loop().
//
// TIMEOUT_MS's default (2000ms) is a PLACEHOLDER, not a bench-validated
// value -- unlike the USB-serial link's COMMAND_TIMEOUT_MS=500 (fast,
// reliable link), LoRa's packet rate/latency depends heavily on the
// chosen spreading factor/bandwidth, so this needs to be derived from
// the actual measured packet interval once real hardware exists (see the
// fork's CLAUDE.md section and the plan's open question 8) -- a good
// starting rule of thumb is 5-10x the real packet interval, not a fixed
// number chosen up front.
module deadman_timer #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter TIMEOUT_MS  = 2_000
)(
  input  wire clk,
  input  wire rst,
  input  wire cmd_valid, // pulse from packet_decoder.v on each ACCEPTED packet
  output reg   safe_stop
);
  localparam integer TIMEOUT_TICKS = (CLK_FREQ_HZ / 1000) * TIMEOUT_MS;
  localparam CNT_WIDTH = $clog2(TIMEOUT_TICKS + 1);

  reg [CNT_WIDTH-1:0] counter;

  always @(posedge clk) begin
    if (rst) begin
      counter   <= 0;
      safe_stop <= 1'b0;
    end else if (cmd_valid) begin
      counter   <= 0;
      safe_stop <= 1'b0;
    end else if (counter >= TIMEOUT_TICKS - 1) begin
      safe_stop <= 1'b1; // saturates here -- re-asserted every cycle while the link stays quiet
    end else begin
      counter <= counter + 1'b1;
    end
  end
endmodule

// Simple counter-based debouncer: a raw button input is accepted as the
// new stable value only after it's held steady for DEBOUNCE_MS, so
// mechanical switch bounce on the Br breakout's button inputs doesn't
// register as multiple presses. `pressed` is always ACTIVE-HIGH
// ("logically pressed"), regardless of how the button is physically
// wired -- set ACTIVE_LOW=1 (the default, matching a button wired to
// pull a normally-high, internally-pulled-up input to ground) or
// ACTIVE_LOW=0 if wired the other way.
module button_debounce #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note (fpga/vehicle/rtl) on this being unverified
  parameter DEBOUNCE_MS = 10,
  parameter ACTIVE_LOW  = 1
)(
  input  wire clk,
  input  wire rst,
  input  wire raw,
  output reg   pressed
);
  localparam integer DEBOUNCE_TICKS = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
  localparam CNT_WIDTH = $clog2(DEBOUNCE_TICKS + 1);

  reg sync1, sync2; // 2-FF synchronizer for the async button input
  always @(posedge clk) begin
    sync1 <= raw;
    sync2 <= sync1;
  end
  wire raw_level = ACTIVE_LOW ? ~sync2 : sync2;

  reg [CNT_WIDTH-1:0] cnt;
  reg candidate;

  always @(posedge clk) begin
    if (rst) begin
      cnt       <= 0;
      candidate <= 1'b0;
      pressed   <= 1'b0;
    end else if (raw_level != candidate) begin
      candidate <= raw_level;
      cnt       <= 0;
    end else if (cnt < DEBOUNCE_TICKS) begin
      cnt <= cnt + 1'b1;
    end else begin
      pressed <= candidate;
    end
  end
endmodule

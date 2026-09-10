`timescale 1ns/1ps
`include "fire_load_pulse.v"

// Scaled-down: CLK_FREQ_HZ=100_000, PULSE_HOLD_MS=5 -> HOLD_TICKS =
// (100_000/1000)*5 = 500 ticks, fast to simulate exactly.
module tb_fire_load_pulse;
  localparam CLK_FREQ_HZ = 100_000;
  localparam PULSE_HOLD_MS = 5;
  localparam HOLD_TICKS = (CLK_FREQ_HZ / 1000) * PULSE_HOLD_MS; // 500

  reg clk = 0;
  reg rst = 1;
  reg trigger = 0;
  wire [7:0] servo_pos;
  wire active;

  fire_load_pulse #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .PULSE_HOLD_MS(PULSE_HOLD_MS), .ANGLE(40)
  ) dut (
    .clk(clk), .rst(rst), .trigger(trigger), .servo_pos(servo_pos), .active(active)
  );

  always #5 clk = ~clk;

  integer errors = 0;

  initial begin
    @(negedge clk); rst = 0;

    // idle state
    #1;
    if (servo_pos !== 8'd0 || active !== 1'b0) begin
      $display("FAIL: not idle at reset (servo_pos=%0d active=%b)", servo_pos, active);
      errors = errors + 1;
    end else $display("PASS: idle at reset (servo_pos=0, active=0)");

    // trigger -> immediately swings to ANGLE
    @(negedge clk); trigger = 1;
    @(posedge clk);
    @(negedge clk); trigger = 0;
    #1;
    if (servo_pos !== 8'd40 || active !== 1'b1) begin
      $display("FAIL: trigger did not swing to ANGLE=40 (servo_pos=%0d active=%b)", servo_pos, active);
      errors = errors + 1;
    end else $display("PASS: trigger swings servo_pos to ANGLE=40, active=1");

    // retrigger while active is ignored: fire another trigger pulse partway
    // through the hold and confirm it doesn't reset the counter (i.e. the
    // pulse still ends at the ORIGINAL hold duration, not extended)
    begin : retrigger_check
      integer i;
      for (i = 0; i < HOLD_TICKS/2; i = i + 1) @(posedge clk);
      @(negedge clk); trigger = 1; // retrigger mid-pulse
      @(posedge clk);
      @(negedge clk); trigger = 0;
      #1;
      if (servo_pos !== 8'd40 || active !== 1'b1) begin
        $display("FAIL: unexpected state right after a mid-pulse retrigger");
        errors = errors + 1;
      end else $display("PASS: mid-pulse retrigger did not disrupt the in-flight pulse");
    end

    // wait out the REMAINDER of the original hold duration (not a full
    // new HOLD_TICKS -- proves the retrigger above did not restart the
    // counter) and confirm it returns to idle on schedule
    begin : timeout_check
      integer i;
      for (i = 0; i < (HOLD_TICKS/2) + 2; i = i + 1) @(posedge clk);
      #1;
      if (servo_pos !== 8'd0 || active !== 1'b0) begin
        $display("FAIL: pulse did not return to idle on the original schedule (servo_pos=%0d active=%b) -- retrigger may have wrongly extended it",
                  servo_pos, active);
        errors = errors + 1;
      end else $display("PASS: pulse returns to idle on the original schedule (retrigger did not extend it)");
    end

    // a fresh trigger after returning to idle starts a brand new pulse
    @(negedge clk); trigger = 1;
    @(posedge clk);
    @(negedge clk); trigger = 0;
    #1;
    if (servo_pos !== 8'd40 || active !== 1'b1) begin
      $display("FAIL: a new trigger after idle did not start a fresh pulse");
      errors = errors + 1;
    end else $display("PASS: a new trigger after returning to idle starts a fresh pulse");

    if (errors == 0) $display("ALL FIRE_LOAD_PULSE TESTS PASSED");
    else $display("%0d FIRE_LOAD_PULSE TEST(S) FAILED", errors);
    $finish;
  end
endmodule

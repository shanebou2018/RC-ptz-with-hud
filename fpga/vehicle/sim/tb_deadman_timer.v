`timescale 1ns/1ps
`include "deadman_timer.v"

// Scaled-down: CLK_FREQ_HZ=100_000, TIMEOUT_MS=5 -> TIMEOUT_TICKS=500.
module tb_deadman_timer;
  localparam CLK_FREQ_HZ = 100_000;
  localparam TIMEOUT_MS = 5;
  localparam TIMEOUT_TICKS = (CLK_FREQ_HZ / 1000) * TIMEOUT_MS; // 500

  reg clk = 0;
  reg rst = 1;
  reg cmd_valid = 0;
  wire safe_stop;

  deadman_timer #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .TIMEOUT_MS(TIMEOUT_MS)) dut (
    .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .safe_stop(safe_stop)
  );

  always #5 clk = ~clk;

  integer errors = 0;
  integer i;

  initial begin
    @(negedge clk); rst = 0;

    #1;
    if (safe_stop !== 1'b0) begin
      $display("FAIL: safe_stop asserted immediately after reset");
      errors = errors + 1;
    end else $display("PASS: safe_stop stays low right after reset");

    // Heartbeat keeps it alive: pulse cmd_valid well within the timeout,
    // repeatedly, for longer than TIMEOUT_TICKS total elapsed time, and
    // confirm safe_stop never trips.
    for (i = 0; i < 5; i = i + 1) begin
      @(negedge clk); cmd_valid = 1;
      @(posedge clk);
      @(negedge clk); cmd_valid = 0;
      repeat (TIMEOUT_TICKS/3) @(posedge clk); // well under the timeout between pulses
    end
    #1;
    if (safe_stop !== 1'b0) begin
      $display("FAIL: safe_stop tripped despite a steady heartbeat");
      errors = errors + 1;
    end else $display("PASS: steady heartbeat keeps safe_stop low");

    // Now go quiet and confirm it trips at (approximately) the timeout.
    for (i = 0; i < TIMEOUT_TICKS + 2; i = i + 1) begin
      @(posedge clk);
      if (safe_stop === 1'b1) begin
        $display("safe_stop asserted after %0d idle ticks (timeout=%0d)", i + 1, TIMEOUT_TICKS);
        i = TIMEOUT_TICKS + 2; // break
      end
    end
    #1;
    if (safe_stop !== 1'b1) begin
      $display("FAIL: safe_stop never asserted after the link went quiet past the timeout");
      errors = errors + 1;
    end else $display("PASS: safe_stop asserts after the link goes quiet past the timeout");

    // A fresh valid packet clears it.
    @(negedge clk); cmd_valid = 1;
    @(posedge clk);
    @(negedge clk); cmd_valid = 0;
    #1;
    if (safe_stop !== 1'b0) begin
      $display("FAIL: a fresh valid packet did not clear safe_stop");
      errors = errors + 1;
    end else $display("PASS: a fresh valid packet clears safe_stop");

    if (errors == 0) $display("ALL DEADMAN_TIMER TESTS PASSED");
    else $display("%0d DEADMAN_TIMER TEST(S) FAILED", errors);
    $finish;
  end
endmodule

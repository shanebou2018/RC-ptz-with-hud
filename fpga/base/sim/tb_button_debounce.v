`timescale 1ns/1ps
`include "button_debounce.v"

// Scaled-down: CLK_FREQ_HZ=100_000, DEBOUNCE_MS=1 -> DEBOUNCE_TICKS=100.
module tb_button_debounce;
  localparam CLK_FREQ_HZ = 100_000;
  localparam DEBOUNCE_MS = 1;
  localparam DEBOUNCE_TICKS = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS; // 100

  reg clk = 0;
  reg rst = 1;
  reg raw = 1'b1; // idle-high, active-low wiring (default ACTIVE_LOW=1)
  wire pressed;

  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) dut (
    .clk(clk), .rst(rst), .raw(raw), .pressed(pressed)
  );

  always #5 clk = ~clk;

  integer errors = 0;
  integer i;

  initial begin
    @(negedge clk); rst = 0;

    #1;
    if (pressed !== 1'b0) begin
      $display("FAIL: pressed asserted at reset with raw idle-high");
      errors = errors + 1;
    end else $display("PASS: not pressed at reset");

    // Bouncy press: raw toggles rapidly around the "pressed" (low) level
    // for less than the debounce window -- must NOT register as pressed.
    for (i = 0; i < 10; i = i + 1) begin
      raw = (i % 2 == 0) ? 1'b0 : 1'b1;
      repeat (5) @(posedge clk); // each wiggle much shorter than DEBOUNCE_TICKS
    end
    raw = 1'b1; // settle back to idle
    repeat (DEBOUNCE_TICKS + 5) @(posedge clk);
    #1;
    if (pressed !== 1'b0) begin
      $display("FAIL: bounce-then-release was registered as a press");
      errors = errors + 1;
    end else $display("PASS: bounce shorter than the debounce window is rejected");

    // A real press: raw held low continuously for longer than the debounce window
    raw = 1'b0;
    repeat (DEBOUNCE_TICKS + 5) @(posedge clk);
    #1;
    if (pressed !== 1'b1) begin
      $display("FAIL: a real sustained press was not registered");
      errors = errors + 1;
    end else $display("PASS: a real sustained press is registered as pressed=1");

    // Release
    raw = 1'b1;
    repeat (DEBOUNCE_TICKS + 5) @(posedge clk);
    #1;
    if (pressed !== 1'b0) begin
      $display("FAIL: release was not registered");
      errors = errors + 1;
    end else $display("PASS: release is registered as pressed=0");

    if (errors == 0) $display("ALL BUTTON_DEBOUNCE TESTS PASSED");
    else $display("%0d BUTTON_DEBOUNCE TEST(S) FAILED", errors);
    $finish;
  end
endmodule

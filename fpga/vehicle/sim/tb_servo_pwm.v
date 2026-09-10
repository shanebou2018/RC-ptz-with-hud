`timescale 1ns/1ps
`include "servo_pwm.v"

// Runs at a scaled-down 1MHz clock (TICKS_PER_US=1) so 1 tick == 1us
// exactly, making pulse-width assertions read directly in microseconds
// without waiting out a real 100MHz/50Hz period in simulation.
module tb_servo_pwm;
  localparam CLK_FREQ_HZ = 1_000_000;
  reg clk = 0;
  reg rst = 1;
  reg [7:0] pos = 8'd90;
  wire pwm_out;

  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) dut (
    .clk(clk), .rst(rst), .pos(pos), .pwm_out(pwm_out)
  );

  always #500 clk = ~clk; // 1MHz -> 1us period

  integer errors = 0;

  task measure_pulse_us(output integer high_ticks, output integer period_ticks);
    integer t;
    begin
      // wait for the start of a period (a low->high transition after
      // being low for a while) so timing starts cleanly
      @(posedge clk); while (pwm_out !== 1'b1) @(posedge clk);
      while (pwm_out === 1'b1) @(posedge clk);
      // now at the falling edge boundary; wait for the NEXT rising edge
      // to start a clean measurement window
      while (pwm_out !== 1'b1) @(posedge clk);
      high_ticks = 0;
      while (pwm_out === 1'b1) begin
        high_ticks = high_ticks + 1;
        @(posedge clk);
      end
      period_ticks = high_ticks;
      while (pwm_out !== 1'b1) begin
        period_ticks = period_ticks + 1;
        @(posedge clk);
      end
    end
  endtask

  initial begin
    @(negedge clk); rst = 0;

    begin : mid_check
      integer high_us, period_us;
      pos = 8'd90;
      measure_pulse_us(high_us, period_us);
      if (high_us != 1500) begin
        $display("FAIL: pos=90 pulse width = %0dus, expected 1500us", high_us);
        errors = errors + 1;
      end else $display("PASS: pos=90 -> 1500us pulse (midpoint)");
      if (period_us != 20000) begin
        $display("FAIL: period = %0dus, expected 20000us (50Hz)", period_us);
        errors = errors + 1;
      end else $display("PASS: period = 20000us (50Hz)");
    end

    begin : min_check
      integer high_us, period_us;
      pos = 8'd0;
      measure_pulse_us(high_us, period_us);
      if (high_us != 1000) begin
        $display("FAIL: pos=0 pulse width = %0dus, expected 1000us", high_us);
        errors = errors + 1;
      end else $display("PASS: pos=0 -> 1000us pulse (min)");
    end

    begin : max_check
      integer high_us, period_us;
      pos = 8'd180;
      measure_pulse_us(high_us, period_us);
      if (high_us != 2000) begin
        $display("FAIL: pos=180 pulse width = %0dus, expected 2000us", high_us);
        errors = errors + 1;
      end else $display("PASS: pos=180 -> 2000us pulse (max)");
    end

    begin : clamp_check
      integer high_us, period_us;
      pos = 8'd250; // out-of-range, should clamp to 180's behavior
      measure_pulse_us(high_us, period_us);
      if (high_us != 2000) begin
        $display("FAIL: pos=250 (out of range) pulse width = %0dus, expected clamped to 2000us", high_us);
        errors = errors + 1;
      end else $display("PASS: pos=250 clamps to the same pulse width as pos=180");
    end

    if (errors == 0) $display("ALL SERVO_PWM TESTS PASSED");
    else $display("%0d SERVO_PWM TEST(S) FAILED", errors);
    $finish;
  end
endmodule

`timescale 1ns/1ps
`include "motor_pwm.v"

// Scaled-down clock (100kHz, PWM_FREQ_HZ=1000 -> 100 ticks/period) so
// duty-cycle measurement is exact and fast in simulation.
module tb_motor_pwm;
  localparam CLK_FREQ_HZ = 100_000;
  localparam PWM_FREQ_HZ = 1_000; // -> PERIOD_TICKS = 100

  reg clk = 0;
  reg rst = 1;
  reg dir_in = 1;
  reg [7:0] pwm_level = 8'd0;
  reg safe_stop = 0;
  wire dir_out, pwm_out;

  motor_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .PWM_FREQ_HZ(PWM_FREQ_HZ)) dut (
    .clk(clk), .rst(rst), .dir_in(dir_in), .pwm_level(pwm_level),
    .safe_stop(safe_stop), .dir_out(dir_out), .pwm_out(pwm_out)
  );

  always #5 clk = ~clk; // 100kHz -> 10us period per tick

  integer errors = 0;

  task measure_duty(output integer high_ticks, output integer period_ticks);
    begin
      @(posedge clk); while (pwm_out !== 1'b1 && high_ticks < 200) @(posedge clk);
      // align to a period boundary: wait for a falling edge, then the next rising edge
      while (pwm_out === 1'b1) @(posedge clk);
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

    begin : half_duty
      integer high_ticks, period_ticks;
      pwm_level = 8'd128; // ~50% of 255 -> ~50 ticks of 100
      measure_duty(high_ticks, period_ticks);
      if (period_ticks != 100) begin
        $display("FAIL: period = %0d ticks, expected 100", period_ticks);
        errors = errors + 1;
      end else $display("PASS: period = 100 ticks (1kHz @ 100kHz clk)");
      // (128*100)/255 = 50 (integer division)
      if (high_ticks != 50) begin
        $display("FAIL: pwm_level=128 duty = %0d/100 ticks, expected 50", high_ticks);
        errors = errors + 1;
      end else $display("PASS: pwm_level=128 -> 50/100 duty ticks");
    end

    begin : clamp_check
      integer high_ticks, period_ticks;
      pwm_level = 8'd255; // above MAX_MOTOR_PWM(200) -> should clamp to 200
      measure_duty(high_ticks, period_ticks);
      // (200*100)/255 = 78 (integer division)
      if (high_ticks != 78) begin
        $display("FAIL: pwm_level=255 (should clamp to MAX_MOTOR_PWM=200) duty = %0d/100, expected 78", high_ticks);
        errors = errors + 1;
      end else $display("PASS: pwm_level=255 clamps to MAX_MOTOR_PWM=200 (duty=78/100)");
    end

    begin : safe_stop_check
      integer i;
      pwm_level = 8'd200;
      safe_stop = 1;
      for (i = 0; i < 150; i = i + 1) @(posedge clk);
      if (pwm_out !== 1'b0) begin
        $display("FAIL: pwm_out was high while safe_stop was asserted");
        errors = errors + 1;
      end else $display("PASS: safe_stop forces pwm_out low regardless of pwm_level");
      safe_stop = 0;
    end

    begin : dir_check
      dir_in = 0;
      @(posedge clk); @(posedge clk);
      if (dir_out !== 1'b0) begin
        $display("FAIL: dir_out did not follow dir_in=0");
        errors = errors + 1;
      end else $display("PASS: dir_out follows dir_in");
    end

    if (errors == 0) $display("ALL MOTOR_PWM TESTS PASSED");
    else $display("%0d MOTOR_PWM TEST(S) FAILED", errors);
    $finish;
  end
endmodule

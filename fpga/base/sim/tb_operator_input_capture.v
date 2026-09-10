`timescale 1ns/1ps
`include "operator_input_capture.v"

// Drives adc_channel_values/adc_new_data directly (bypassing mcp3008_adc.v
// -- that's covered by its own testbench) to isolate operator_input_capture's
// own scaling/mixing/fire-load logic.
module tb_operator_input_capture;
  localparam CLK_FREQ_HZ = 100_000;
  localparam DEBOUNCE_MS = 1;
  localparam DEBOUNCE_TICKS = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS; // 100

  reg clk = 0;
  reg rst = 1;
  reg send_pulse = 0;
  reg [49:0] adc_channel_values = 0;
  reg adc_new_data = 0;
  reg btn_fire = 1, btn_load = 1; // active-low, idle high

  wire [7:0] op_pan, op_tilt, op_focus, op_zoom;
  wire op_fire, op_load, op_motor_l_dir, op_motor_r_dir;
  wire [7:0] op_motor_l_pwm, op_motor_r_pwm;

  operator_input_capture #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) dut (
    .clk(clk), .rst(rst), .send_pulse(send_pulse),
    .adc_channel_values(adc_channel_values), .adc_new_data(adc_new_data),
    .btn_fire(btn_fire), .btn_load(btn_load),
    .op_pan(op_pan), .op_tilt(op_tilt), .op_focus(op_focus), .op_zoom(op_zoom),
    .op_fire(op_fire), .op_load(op_load),
    .op_motor_l_dir(op_motor_l_dir), .op_motor_r_dir(op_motor_r_dir),
    .op_motor_l_pwm(op_motor_l_pwm), .op_motor_r_pwm(op_motor_r_pwm)
  );

  always #5 clk = ~clk;
  integer errors = 0;

  task settle_debounce; begin repeat (DEBOUNCE_TICKS + 10) @(posedge clk); end endtask

  task set_adc(input [9:0] pan, input [9:0] tilt, input [9:0] zoom, input [9:0] throttle, input [9:0] turn);
    begin
      adc_channel_values = {turn, throttle, zoom, tilt, pan};
      @(negedge clk); adc_new_data = 1;
      @(posedge clk);
      @(negedge clk); adc_new_data = 0;
      #1;
    end
  endtask

  initial begin
    @(negedge clk); rst = 0;
    settle_debounce();

    if (op_pan !== 8'd90 || op_tilt !== 8'd90 || op_zoom !== 8'd0) begin
      $display("FAIL: defaults wrong at reset (pan=%0d tilt=%0d zoom=%0d)", op_pan, op_tilt, op_zoom);
      errors = errors + 1;
    end else $display("PASS: pan=90 tilt=90 zoom=0 at reset");

    // --- pan/tilt/zoom: min, mid, max ADC values ---
    set_adc(10'd0, 10'd512, 10'd1023, 10'd512, 10'd512);
    if (op_pan !== 8'd0) begin
      $display("FAIL: pan at ADC=0 -> %0d, expected 0", op_pan);
      errors = errors + 1;
    end else $display("PASS: pan at ADC=0 -> 0");

    if (op_tilt < 8'd88 || op_tilt > 8'd92) begin // (512*180)>>10 = 90
      $display("FAIL: tilt at ADC=512 -> %0d, expected ~90", op_tilt);
      errors = errors + 1;
    end else $display("PASS: tilt at ADC=512 -> ~90 (%0d)", op_tilt);

    if (op_zoom !== 8'd179) begin // (1023*180)>>10 = 179 (shift approximation, documented)
      $display("FAIL: zoom at ADC=1023 -> %0d, expected 179", op_zoom);
      errors = errors + 1;
    end else $display("PASS: zoom at ADC=1023 -> 179 (shift-approximation max, as documented)");

    // --- throttle/turn: centered (512) -> both motors stopped ---
    if (op_motor_l_pwm !== 8'd0 || op_motor_r_pwm !== 8'd0) begin
      $display("FAIL: centered throttle/turn did not stop both motors (L=%0d R=%0d)", op_motor_l_pwm, op_motor_r_pwm);
      errors = errors + 1;
    end else $display("PASS: centered throttle/turn -> both motors stopped");

    // --- full-forward throttle, centered turn -> both motors forward at ~MAX_MOTOR_PWM ---
    set_adc(10'd0, 10'd512, 10'd1023, 10'd1023, 10'd512);
    if (op_motor_l_dir !== 1'b1 || op_motor_r_dir !== 1'b1) begin
      $display("FAIL: full-forward throttle did not drive both motors forward (Ldir=%b Rdir=%b)", op_motor_l_dir, op_motor_r_dir);
      errors = errors + 1;
    end else if (op_motor_l_pwm < 8'd190 || op_motor_r_pwm < 8'd190) begin
      $display("FAIL: full-forward throttle pwm too low (L=%0d R=%0d, expected near MAX_MOTOR_PWM=200)", op_motor_l_pwm, op_motor_r_pwm);
      errors = errors + 1;
    end else $display("PASS: full-forward throttle -> both motors forward near max (L=%0d R=%0d)", op_motor_l_pwm, op_motor_r_pwm);

    // --- full-reverse throttle -> both motors reverse ---
    set_adc(10'd0, 10'd512, 10'd1023, 10'd0, 10'd512);
    if (op_motor_l_dir !== 1'b0 || op_motor_r_dir !== 1'b0) begin
      $display("FAIL: full-reverse throttle did not drive both motors in reverse (Ldir=%b Rdir=%b)", op_motor_l_dir, op_motor_r_dir);
      errors = errors + 1;
    end else $display("PASS: full-reverse throttle -> both motors reverse");

    // --- centered throttle, full-right turn -> left motor forward, right motor reverse (pivot turn) ---
    set_adc(10'd0, 10'd512, 10'd1023, 10'd512, 10'd1023);
    if (op_motor_l_dir !== 1'b1 || op_motor_r_dir !== 1'b0) begin
      $display("FAIL: full-right turn (centered throttle) mix wrong (Ldir=%b Rdir=%b, expected L=1 R=0)", op_motor_l_dir, op_motor_r_dir);
      errors = errors + 1;
    end else $display("PASS: centered throttle + full-right turn -> pivot (L forward, R reverse)");

    // --- deadzone: throttle just off-center should still read as stopped ---
    set_adc(10'd0, 10'd512, 10'd1023, 10'd515, 10'd512); // +3 from center, within default DEADZONE=20
    if (op_motor_l_pwm !== 8'd0 || op_motor_r_pwm !== 8'd0) begin
      $display("FAIL: small off-center throttle (within deadzone) produced nonzero pwm (L=%0d R=%0d)", op_motor_l_pwm, op_motor_r_pwm);
      errors = errors + 1;
    end else $display("PASS: throttle within the deadzone reads as stopped");

    // --- fire: momentary, one-packet pulse (same behavior as the button-only design) ---
    btn_fire = 0;
    settle_debounce();
    #1;
    if (op_fire !== 1'b1) begin
      $display("FAIL: op_fire not set after a fire press");
      errors = errors + 1;
    end else $display("PASS: op_fire set after a fire press");

    @(negedge clk); send_pulse = 1;
    @(posedge clk); #1;
    if (op_fire !== 1'b1) begin
      $display("FAIL: op_fire not still high on the send_pulse edge itself");
      errors = errors + 1;
    end else $display("PASS: op_fire is high on the send_pulse edge");
    @(negedge clk); send_pulse = 0;
    @(posedge clk); #1;
    if (op_fire !== 1'b0) begin
      $display("FAIL: op_fire did not clear after being consumed by send_pulse");
      errors = errors + 1;
    end else $display("PASS: op_fire clears after one send_pulse");

    if (errors == 0) $display("ALL OPERATOR_INPUT_CAPTURE TESTS PASSED");
    else $display("%0d OPERATOR_INPUT_CAPTURE TEST(S) FAILED", errors);
    $finish;
  end
endmodule

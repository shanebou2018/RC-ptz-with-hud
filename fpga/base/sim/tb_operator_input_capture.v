`timescale 1ns/1ps
`include "operator_input_capture.v"

// Scaled-down: CLK_FREQ_HZ=100_000, DEBOUNCE_MS=1 (100 ticks),
// STEP_TICK_MS=2 (200 ticks) -- distinct enough to tell debounce settling
// apart from a step tick in the trace, still fast to simulate.
module tb_operator_input_capture;
  localparam CLK_FREQ_HZ = 100_000;
  localparam DEBOUNCE_MS = 1;
  localparam STEP_TICK_MS = 2;
  localparam DEBOUNCE_TICKS = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;   // 100
  localparam STEP_TICKS     = (CLK_FREQ_HZ / 1000) * STEP_TICK_MS;  // 200

  reg clk = 0;
  reg rst = 1;
  reg send_pulse = 0;

  // Active-low buttons (default ACTIVE_LOW=1): idle high, pressed = 0.
  reg btn_pan_left=1, btn_pan_right=1, btn_tilt_up=1, btn_tilt_down=1;
  reg btn_zoom_in=1, btn_zoom_out=1, btn_fire=1, btn_load=1;
  reg btn_drive_fwd=1, btn_drive_rev=1, btn_drive_left=1, btn_drive_right=1;

  wire [7:0] op_pan, op_tilt, op_focus, op_zoom;
  wire op_fire, op_load, op_motor_l_dir, op_motor_r_dir;
  wire [7:0] op_motor_l_pwm, op_motor_r_pwm;

  operator_input_capture #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .STEP_TICK_MS(STEP_TICK_MS),
    .STEP_DEG(2), .DRIVE_PWM(8'd150)
  ) dut (
    .clk(clk), .rst(rst), .send_pulse(send_pulse),
    .btn_pan_left(btn_pan_left), .btn_pan_right(btn_pan_right),
    .btn_tilt_up(btn_tilt_up), .btn_tilt_down(btn_tilt_down),
    .btn_zoom_in(btn_zoom_in), .btn_zoom_out(btn_zoom_out),
    .btn_fire(btn_fire), .btn_load(btn_load),
    .btn_drive_fwd(btn_drive_fwd), .btn_drive_rev(btn_drive_rev),
    .btn_drive_left(btn_drive_left), .btn_drive_right(btn_drive_right),
    .op_pan(op_pan), .op_tilt(op_tilt), .op_focus(op_focus), .op_zoom(op_zoom),
    .op_fire(op_fire), .op_load(op_load),
    .op_motor_l_dir(op_motor_l_dir), .op_motor_r_dir(op_motor_r_dir),
    .op_motor_l_pwm(op_motor_l_pwm), .op_motor_r_pwm(op_motor_r_pwm)
  );

  always #5 clk = ~clk;
  integer errors = 0;

  task settle_debounce; begin repeat (DEBOUNCE_TICKS + 10) @(posedge clk); end endtask
  task wait_step_tick;  begin repeat (STEP_TICKS + 10) @(posedge clk); end endtask

  initial begin
    @(negedge clk); rst = 0;
    settle_debounce();

    if (op_pan !== 8'd90 || op_tilt !== 8'd90 || op_zoom !== 8'd0) begin
      $display("FAIL: defaults wrong at reset (pan=%0d tilt=%0d zoom=%0d)", op_pan, op_tilt, op_zoom);
      errors = errors + 1;
    end else $display("PASS: pan=90 tilt=90 zoom=0 at reset");

    // --- pan right increments, clamped at 180 ---
    btn_pan_right = 0; // pressed
    settle_debounce();
    wait_step_tick();
    if (op_pan !== 8'd92) begin
      $display("FAIL: pan after one step-tick held right = %0d, expected 92", op_pan);
      errors = errors + 1;
    end else $display("PASS: pan increments by STEP_DEG=2 while held right");

    begin : clamp_check
      integer i;
      for (i = 0; i < 60; i = i + 1) wait_step_tick(); // far more than enough to hit 180
      if (op_pan !== 8'd180) begin
        $display("FAIL: pan did not clamp at 180 (got %0d)", op_pan);
        errors = errors + 1;
      end else $display("PASS: pan clamps at 180");
    end
    btn_pan_right = 1; // release
    settle_debounce();

    // --- tilt down decrements ---
    btn_tilt_down = 0;
    settle_debounce();
    wait_step_tick();
    if (op_tilt !== 8'd88) begin
      $display("FAIL: tilt after one step-tick held down = %0d, expected 88", op_tilt);
      errors = errors + 1;
    end else $display("PASS: tilt decrements by STEP_DEG=2 while held down");
    btn_tilt_down = 1;
    settle_debounce();

    // --- zoom in increments from 0 ---
    btn_zoom_in = 0;
    settle_debounce();
    wait_step_tick();
    if (op_zoom !== 8'd2) begin
      $display("FAIL: zoom after one step-tick held in = %0d, expected 2", op_zoom);
      errors = errors + 1;
    end else $display("PASS: zoom increments by STEP_DEG=2 while held in");
    btn_zoom_in = 1;
    settle_debounce();

    // --- fire: momentary, one-packet pulse ---
    btn_fire = 0;
    settle_debounce();
    #1;
    if (op_fire !== 1'b1) begin
      $display("FAIL: op_fire not set after a fire press");
      errors = errors + 1;
    end else $display("PASS: op_fire set after a fire press (pending until next send)");

    @(negedge clk); send_pulse = 1;
    @(posedge clk); #1;
    // op_fire should still read 1 on the same edge send_pulse fires (packet_encoder samples it here)
    if (op_fire !== 1'b1) begin
      $display("FAIL: op_fire not still high on the send_pulse edge itself");
      errors = errors + 1;
    end else $display("PASS: op_fire is high on the send_pulse edge (gets included in that packet)");
    @(negedge clk); send_pulse = 0;
    @(posedge clk); #1;
    if (op_fire !== 1'b0) begin
      $display("FAIL: op_fire did not clear after being consumed by send_pulse");
      errors = errors + 1;
    end else $display("PASS: op_fire clears after one send_pulse (won't repeat on the next packet)");

    btn_fire = 1; // release, still held debounce state doesn't matter now
    settle_debounce();

    // holding the button through a SECOND send_pulse must NOT re-fire
    // (edge-triggered pending, not level-triggered)
    @(negedge clk); send_pulse = 1;
    @(posedge clk); #1;
    if (op_fire !== 1'b0) begin
      $display("FAIL: op_fire re-armed on a second send_pulse without a new press");
      errors = errors + 1;
    end else $display("PASS: op_fire stays low on a later send_pulse with no new press");
    @(negedge clk); send_pulse = 0;
    @(posedge clk);

    // --- drive: forward only ---
    btn_drive_fwd = 0;
    settle_debounce();
    #1;
    if (op_motor_l_dir !== 1'b1 || op_motor_r_dir !== 1'b1 ||
        op_motor_l_pwm !== 8'd150 || op_motor_r_pwm !== 8'd150) begin
      $display("FAIL: forward-only drive mix wrong (L dir=%b pwm=%0d, R dir=%b pwm=%0d)",
                op_motor_l_dir, op_motor_l_pwm, op_motor_r_dir, op_motor_r_pwm);
      errors = errors + 1;
    end else $display("PASS: forward-only drives both motors forward at DRIVE_PWM=150");

    // --- drive: forward + right turn (tank steer: right motor stops) ---
    btn_drive_right = 0;
    settle_debounce();
    #1;
    if (op_motor_l_pwm !== 8'd150 || op_motor_l_dir !== 1'b1 || op_motor_r_pwm !== 8'd0) begin
      $display("FAIL: forward+right mix wrong (L dir=%b pwm=%0d, R pwm=%0d)",
                op_motor_l_dir, op_motor_l_pwm, op_motor_r_pwm);
      errors = errors + 1;
    end else $display("PASS: forward+right turn -> left motor drives, right motor stops");

    btn_drive_fwd = 1; btn_drive_right = 1;
    settle_debounce();

    // --- drive: all released -> both motors stop ---
    #1;
    if (op_motor_l_pwm !== 8'd0 || op_motor_r_pwm !== 8'd0) begin
      $display("FAIL: motors did not stop with no drive buttons held");
      errors = errors + 1;
    end else $display("PASS: no drive buttons held -> both motors stopped");

    if (errors == 0) $display("ALL OPERATOR_INPUT_CAPTURE TESTS PASSED");
    else $display("%0d OPERATOR_INPUT_CAPTURE TEST(S) FAILED", errors);
    $finish;
  end
endmodule

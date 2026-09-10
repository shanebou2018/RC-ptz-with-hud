// Reads 12 physical pushbuttons (via the Br breakout board) and turns
// them into the same command fields packet_encoder.v expects -- this
// replaces top_base.v's earlier fixed-value stub, resolving the fork's
// open question on what operator input device to use.
//
// Mapping mirrors the original (now-removed) browser HUD's keyboard
// scheme 1:1, just on physical buttons instead of a keyboard:
//   pan left/right, tilt up/down, zoom in/out  -- increment while held
//     (STEP_DEG per STEP_TICK_MS, matching the old PAN_TILT_STEP_DEG/
//     ZOOM_STEP_DEG/KEY_TICK_MS constants), clamped 0-180
//   fire, load                                  -- momentary, edge-triggered
//   drive fwd/rev/left/right                     -- 4-button tank-steer
//     mix at a single fixed DRIVE_PWM speed (no analog throttle since
//     these are on/off buttons, not a stick)
`include "button_debounce.v"
//
// Fire/load semantics: packet_decoder.v's header comment documents the
// assumption that the base station only ever sets the fire/load flag bit
// for the ONE packet meant to trigger a pulse, not held across multiple
// packets. This module honors that: a button press latches a "pending"
// flag, which is presented on op_fire/op_load and cleared the moment
// it's included in a transmitted packet (the `send_pulse` input, wired
// to top_base.v's own send timer) -- so a single press produces fire=1
// on exactly one outgoing packet, however long the button stays held.
module operator_input_capture #(
  parameter CLK_FREQ_HZ  = 100_000_000, // see servo_pwm.v's header note (fpga/vehicle/rtl) on this being unverified
  parameter DEBOUNCE_MS  = 10,
  parameter STEP_TICK_MS = 50,  // matches the old browser HUD's KEY_TICK_MS
  parameter STEP_DEG     = 2,   // matches PAN_TILT_STEP_DEG/ZOOM_STEP_DEG
  parameter [7:0] DRIVE_PWM = 8'd150, // fixed drive speed while a direction button is held; tune against MAX_MOTOR_PWM (packet_defs.vh)
  parameter ACTIVE_LOW   = 1
)(
  input  wire clk,
  input  wire rst,
  input  wire send_pulse, // from top_base.v's send timer -- consumes one pending fire/load trigger

  input  wire btn_pan_left,   input wire btn_pan_right,
  input  wire btn_tilt_up,    input wire btn_tilt_down,
  input  wire btn_zoom_in,    input wire btn_zoom_out,
  input  wire btn_fire,       input wire btn_load,
  input  wire btn_drive_fwd,  input wire btn_drive_rev,
  input  wire btn_drive_left, input wire btn_drive_right,

  output reg [7:0] op_pan,
  output reg [7:0] op_tilt,
  output reg [7:0] op_focus,  // no focus buttons (the old browser HUD had none either) -- stays fixed
  output reg [7:0] op_zoom,
  output reg        op_fire,
  output reg        op_load,
  output reg        op_motor_l_dir,
  output reg        op_motor_r_dir,
  output reg [7:0]  op_motor_l_pwm,
  output reg [7:0]  op_motor_r_pwm
);
  wire db_pan_left, db_pan_right, db_tilt_up, db_tilt_down, db_zoom_in, db_zoom_out;
  wire db_fire, db_load, db_fwd, db_rev, db_left, db_right;

  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d0 (.clk(clk), .rst(rst), .raw(btn_pan_left),    .pressed(db_pan_left));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d1 (.clk(clk), .rst(rst), .raw(btn_pan_right),   .pressed(db_pan_right));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d2 (.clk(clk), .rst(rst), .raw(btn_tilt_up),     .pressed(db_tilt_up));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d3 (.clk(clk), .rst(rst), .raw(btn_tilt_down),   .pressed(db_tilt_down));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d4 (.clk(clk), .rst(rst), .raw(btn_zoom_in),     .pressed(db_zoom_in));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d5 (.clk(clk), .rst(rst), .raw(btn_zoom_out),    .pressed(db_zoom_out));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d6 (.clk(clk), .rst(rst), .raw(btn_fire),        .pressed(db_fire));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d7 (.clk(clk), .rst(rst), .raw(btn_load),        .pressed(db_load));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d8 (.clk(clk), .rst(rst), .raw(btn_drive_fwd),   .pressed(db_fwd));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d9 (.clk(clk), .rst(rst), .raw(btn_drive_rev),   .pressed(db_rev));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d10(.clk(clk), .rst(rst), .raw(btn_drive_left),  .pressed(db_left));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d11(.clk(clk), .rst(rst), .raw(btn_drive_right), .pressed(db_right));

  // ---- pan/tilt/zoom: increment while held, ticked periodically ----
  localparam integer STEP_TICKS = (CLK_FREQ_HZ / 1000) * STEP_TICK_MS;
  reg [$clog2(STEP_TICKS + 1)-1:0] step_cnt;
  reg step_tick;

  always @(posedge clk) begin
    step_tick <= 1'b0;
    if (rst) begin
      step_cnt <= 0;
    end else if (step_cnt >= STEP_TICKS - 1) begin
      step_cnt  <= 0;
      step_tick <= 1'b1;
    end else begin
      step_cnt <= step_cnt + 1'b1;
    end
  end

  function [7:0] clamp180(input signed [9:0] v);
    begin
      if (v < 0) clamp180 = 8'd0;
      else if (v > 180) clamp180 = 8'd180;
      else clamp180 = v[7:0];
    end
  endfunction

  always @(posedge clk) begin
    if (rst) begin
      op_pan   <= 8'd90;
      op_tilt  <= 8'd90;
      op_focus <= 8'd0;
      op_zoom  <= 8'd0;
    end else if (step_tick) begin
      if (db_pan_left ^ db_pan_right)
        op_pan <= clamp180($signed({2'b0, op_pan}) + (db_pan_right ? STEP_DEG : -STEP_DEG));
      if (db_tilt_up ^ db_tilt_down)
        op_tilt <= clamp180($signed({2'b0, op_tilt}) + (db_tilt_up ? STEP_DEG : -STEP_DEG));
      if (db_zoom_in ^ db_zoom_out)
        op_zoom <= clamp180($signed({2'b0, op_zoom}) + (db_zoom_in ? STEP_DEG : -STEP_DEG));
    end
  end

  // ---- fire/load: momentary, latched-until-next-transmitted-packet ----
  reg db_fire_prev, db_load_prev;
  reg fire_pending, load_pending;

  always @(posedge clk) begin
    if (rst) begin
      db_fire_prev <= 1'b0;
      db_load_prev <= 1'b0;
      fire_pending <= 1'b0;
      load_pending <= 1'b0;
    end else begin
      db_fire_prev <= db_fire;
      db_load_prev <= db_load;

      if (db_fire && !db_fire_prev) fire_pending <= 1'b1;
      else if (send_pulse) fire_pending <= 1'b0;

      if (db_load && !db_load_prev) load_pending <= 1'b1;
      else if (send_pulse) load_pending <= 1'b0;
    end
    op_fire <= fire_pending;
    op_load <= load_pending;
  end

  // ---- drive: 4-button tank-steer mix at a fixed speed ----
  reg signed [2:0] forward, turn, left, right;
  always @(posedge clk) begin
    if (rst) begin
      op_motor_l_dir <= 1'b1;
      op_motor_r_dir <= 1'b1;
      op_motor_l_pwm <= 8'd0;
      op_motor_r_pwm <= 8'd0;
    end else begin
      forward = (db_fwd && !db_rev) ? 3'sd1 : (db_rev && !db_fwd) ? -3'sd1 : 3'sd0;
      turn    = (db_right && !db_left) ? 3'sd1 : (db_left && !db_right) ? -3'sd1 : 3'sd0;

      left  = forward + turn;
      if (left > 3'sd1) left = 3'sd1;
      if (left < -3'sd1) left = -3'sd1;

      right = forward - turn;
      if (right > 3'sd1) right = 3'sd1;
      if (right < -3'sd1) right = -3'sd1;

      op_motor_l_dir <= (left >= 0);
      op_motor_l_pwm <= (left == 0) ? 8'd0 : DRIVE_PWM;
      op_motor_r_dir <= (right >= 0);
      op_motor_r_pwm <= (right == 0) ? 8'd0 : DRIVE_PWM;
    end
  end
endmodule

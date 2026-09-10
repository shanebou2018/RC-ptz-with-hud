// Reads the base station's operator input and turns it into the command
// fields packet_encoder.v expects. Hybrid input, per user direction:
// - pan, tilt, zoom, throttle, turn: 5 potentiometers via mcp3008_adc.v
//   (SPI ADC) -- continuous, not increment-while-held like the original
//   button-only design this replaced.
// - fire, load: 2 physical pushbuttons (a pot doesn't make sense for a
//   momentary trigger), debounced via button_debounce.v.
//
// Fire/load semantics unchanged from the button-only design: a press
// latches a "pending" flag, presented on op_fire/op_load and cleared the
// moment it's included in a transmitted packet (`send_pulse`, from
// top_base.v's send timer) -- packet_decoder.v assumes the base station
// only ever sets the fire/load flag bit for the ONE packet meant to
// trigger a pulse, not held across multiple packets.
//
// ADC channel mapping (fixed, matches mcp3008_adc.v's NUM_CHANNELS=5):
//   0=pan, 1=tilt, 2=zoom (absolute position pots, 0-180 range)
//   3=throttle, 4=turn (centered pots, tank-steer mixed like the old
//     4-button drive scheme, but now continuous instead of on/off)
//
// All ADC-to-degrees/PWM scaling uses multiply-then-shift, never a real
// divide -- see fpga/README.md's LUT-budget finding on why that matters
// (division-heavy servo_pwm.v/motor_pwm.v ate 91% of the vehicle FPGA's
// LUTs; this module was written to not repeat that mistake).
`include "button_debounce.v"
`include "packet_defs.vh"

module operator_input_capture #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note (fpga/vehicle/rtl) on this being unverified
  parameter DEBOUNCE_MS = 10,
  parameter ACTIVE_LOW  = 1,
  parameter DEADZONE    = 11'd20 // +/- raw ADC counts around center (512) treated as zero throttle/turn
)(
  input  wire clk,
  input  wire rst,
  input  wire send_pulse, // from top_base.v's send timer -- consumes one pending fire/load trigger

  // from mcp3008_adc.v: channel i at bits [10*i +: 10]
  input  wire [49:0] adc_channel_values,
  input  wire         adc_new_data, // pulse: adc_channel_values just refreshed -- this module updates on this pulse

  input  wire btn_fire,
  input  wire btn_load,

  output reg [7:0] op_pan,
  output reg [7:0] op_tilt,
  output reg [7:0] op_focus,  // no focus pot (the old browser HUD had no focus control either) -- stays fixed
  output reg [7:0] op_zoom,
  output reg        op_fire,
  output reg        op_load,
  output reg        op_motor_l_dir,
  output reg        op_motor_r_dir,
  output reg [7:0]  op_motor_l_pwm,
  output reg [7:0]  op_motor_r_pwm
);
  wire [9:0] adc_pan      = adc_channel_values[10*0 +: 10];
  wire [9:0] adc_tilt     = adc_channel_values[10*1 +: 10];
  wire [9:0] adc_zoom     = adc_channel_values[10*2 +: 10];
  wire [9:0] adc_throttle = adc_channel_values[10*3 +: 10];
  wire [9:0] adc_turn     = adc_channel_values[10*4 +: 10];

  // ---- pan/tilt/zoom: absolute position, (raw*180)>>10 -- tops out at
  // 179 rather than a full 180 due to the shift approximation (1023*180
  // = 184140, >>10 = 179), an inconsequential rounding cost for a hobby
  // pot's usable range, traded for avoiding a real division. Computed
  // into explicit 18-bit intermediates (18 bits comfortably holds
  // 1023*180=184140) BEFORE truncating to the 8-bit outputs -- letting
  // Verilog infer the multiply's width from the 8-bit op_pan/op_tilt/
  // op_zoom assignment targets would silently truncate adc_pan/adc_tilt/
  // adc_zoom to 8 bits before the multiply even happens (512 truncates
  // to 0 in 8 bits), corrupting the result. Found via simulation, not
  // guessed -- see the equivalent, correctly-explicit-width pattern
  // already used below for throttle/turn. ----
  reg [17:0] pan_scaled, tilt_scaled, zoom_scaled;
  always @(posedge clk) begin
    if (rst) begin
      op_pan   <= 8'd90;
      op_tilt  <= 8'd90;
      op_focus <= 8'd0;
      op_zoom  <= 8'd0;
    end else if (adc_new_data) begin
      pan_scaled  = adc_pan  * 18'd180;
      tilt_scaled = adc_tilt * 18'd180;
      zoom_scaled = adc_zoom * 18'd180;
      op_pan  <= pan_scaled[17:10];
      op_tilt <= tilt_scaled[17:10];
      op_zoom <= zoom_scaled[17:10];
    end
  end

  // ---- fire/load: momentary, latched-until-next-transmitted-packet ----
  wire db_fire, db_load;
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d0 (.clk(clk), .rst(rst), .raw(btn_fire), .pressed(db_fire));
  button_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .ACTIVE_LOW(ACTIVE_LOW)) d1 (.clk(clk), .rst(rst), .raw(btn_load), .pressed(db_load));

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

  // ---- drive: throttle/turn pots, tank-steer mixed, continuous ----
  // Centered at raw=512 (a standard analog joystick's spring-centered
  // rest position); DEADZONE suppresses drift/noise near center so the
  // vehicle doesn't creep with the stick released. Scaled to
  // +/-MAX_MOTOR_PWM via multiply+shift (centered range is +/-512 = 2^9).
  reg signed [10:0] throttle_c, turn_c;
  reg signed [19:0] fwd_scaled, turn_scaled;
  reg signed [10:0] fwd_pwm, turn_pwm;
  reg signed [10:0] left_raw, right_raw;
  reg signed [10:0] left_abs, right_abs;

  always @(posedge clk) begin
    if (rst) begin
      op_motor_l_dir <= 1'b1;
      op_motor_r_dir <= 1'b1;
      op_motor_l_pwm <= 8'd0;
      op_motor_r_pwm <= 8'd0;
    end else if (adc_new_data) begin
      throttle_c = $signed({1'b0, adc_throttle}) - 11'sd512;
      turn_c     = $signed({1'b0, adc_turn})     - 11'sd512;

      if (throttle_c > -$signed(DEADZONE) && throttle_c < $signed(DEADZONE)) throttle_c = 11'sd0;
      if (turn_c     > -$signed(DEADZONE) && turn_c     < $signed(DEADZONE)) turn_c     = 11'sd0;

      fwd_scaled  = throttle_c * $signed({3'b0, `MAX_MOTOR_PWM});
      turn_scaled = turn_c     * $signed({3'b0, `MAX_MOTOR_PWM});
      fwd_pwm     = fwd_scaled  >>> 9;
      turn_pwm    = turn_scaled >>> 9;

      left_raw  = fwd_pwm + turn_pwm;
      right_raw = fwd_pwm - turn_pwm;

      if (left_raw > $signed({3'b0, `MAX_MOTOR_PWM})) left_raw = $signed({3'b0, `MAX_MOTOR_PWM});
      if (left_raw < -$signed({3'b0, `MAX_MOTOR_PWM})) left_raw = -$signed({3'b0, `MAX_MOTOR_PWM});
      if (right_raw > $signed({3'b0, `MAX_MOTOR_PWM})) right_raw = $signed({3'b0, `MAX_MOTOR_PWM});
      if (right_raw < -$signed({3'b0, `MAX_MOTOR_PWM})) right_raw = -$signed({3'b0, `MAX_MOTOR_PWM});

      // Negate (as a signed value) before truncating to 8 bits, not
      // after -- truncating a negative signed value's low bits first
      // gives its two's-complement bit pattern, not its magnitude.
      // Safe to truncate post-negation since magnitude is already
      // clamped to <= MAX_MOTOR_PWM (200), which fits in 8 bits.
      left_abs  = left_raw  < 0 ? -left_raw  : left_raw;
      right_abs = right_raw < 0 ? -right_raw : right_raw;

      op_motor_l_dir <= (left_raw >= 0);
      op_motor_l_pwm <= left_abs[7:0];
      op_motor_r_dir <= (right_raw >= 0);
      op_motor_r_pwm <= right_abs[7:0];
    end
  end
endmodule

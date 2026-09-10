// Top-level for the vehicle-side Alchitry Cu V2: receives commands over
// the E220 LoRa link, drives 6 servos + 2 drive motors, polls a compass
// over SPI, and feeds telemetry back to the Pi over a separate UART.
// This is the vehicle FPGA's full authority -- it never receives control
// input from the Pi (see CLAUDE.md's fork section).
//
// PIN NAMES BELOW ARE PLACEHOLDERS, NOT A WIRING DECISION -- this file
// compiles and synthesizes (see fpga/README.md's LUT-utilization check),
// but fpga/vehicle/constraints/alchitry_cu_v2_vehicle.pcf still needs
// real pin locations from Alchitry's own Cu V2 pinout reference before
// this can be placed-and-routed for real hardware, exactly like
// esp32_firmware.ino's pinout being "a first guess, not a wiring
// decision" in the main branch.
`include "packet_defs.vh"
`include "e220_driver.v"
`include "packet_decoder.v"
`include "deadman_timer.v"
`include "servo_pwm.v"
`include "motor_pwm.v"
`include "fire_load_pulse.v"
`include "spi_compass_driver.v"
`include "telemetry_uart_tx.v"

module top_vehicle #(
  parameter CLK_FREQ_HZ = 100_000_000 // see servo_pwm.v's header note on this being unverified
)(
  input  wire clk100mhz,
  input  wire rst_n,          // active-low reset (placeholder -- e.g. a pushbutton)

  // E220-900T22D (via the Br breakout board)
  input  wire lora_aux,
  output wire lora_m0,
  output wire lora_m1,
  output wire lora_uart_tx,   // to the module's RXD
  input  wire lora_uart_rx,   // from the module's TXD

  // 6 hobby servos
  output wire servo_pan,
  output wire servo_tilt,
  output wire servo_focus,
  output wire servo_zoom,
  output wire servo_fire,
  output wire servo_load,

  // 2 Cytron-style drive motor controllers
  output wire motor_l_dir_pin,
  output wire motor_l_pwm_pin,
  output wire motor_r_dir_pin,
  output wire motor_r_pwm_pin,

  // compass/IMU (BNO055 placeholder, per CLAUDE.md), SPI
  output wire compass_sclk,
  output wire compass_mosi,
  input  wire compass_miso,
  output wire compass_cs,

  // telemetry-only link to the Pi
  output wire pi_uart_tx
);
  wire clk = clk100mhz;
  wire rst = ~rst_n;

  // ---- LoRa command link (RX only -- no return channel by default, per
  // the fork's open question on a base<-vehicle link quality indicator) ----
  wire [8*`PKT_LEN-1:0] rx_pkt_data;
  wire rx_pkt_valid;

  e220_driver #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) lora (
    .clk(clk), .rst(rst),
    .aux(lora_aux), .m0(lora_m0), .m1(lora_m1),
    .uart_tx(lora_uart_tx), .uart_rx(lora_uart_rx),
    .tx_start(1'b0), .tx_data({8*`PKT_LEN{1'b0}}), .tx_done(),
    .rx_data(rx_pkt_data), .rx_valid(rx_pkt_valid)
  );

  // ---- packet decode ----
  wire [7:0] cmd_pan, cmd_tilt, cmd_focus, cmd_zoom;
  wire cmd_fire_pulse, cmd_load_pulse;
  wire cmd_motor_l_dir, cmd_motor_r_dir;
  wire [7:0] cmd_motor_l_pwm, cmd_motor_r_pwm;
  wire cmd_valid;
  wire [7:0] last_seq;

  packet_decoder decoder (
    .clk(clk), .rst(rst), .seed(`KEYSTREAM_SEED),
    .rx_valid(rx_pkt_valid), .pkt_data_in(rx_pkt_data),
    .pan(cmd_pan), .tilt(cmd_tilt), .focus(cmd_focus), .zoom(cmd_zoom),
    .fire_pulse(cmd_fire_pulse), .load_pulse(cmd_load_pulse),
    .motor_l_dir(cmd_motor_l_dir), .motor_r_dir(cmd_motor_r_dir),
    .motor_l_pwm(cmd_motor_l_pwm), .motor_r_pwm(cmd_motor_r_pwm),
    .cmd_valid(cmd_valid), .last_seq(last_seq)
  );

  // ---- deadman: the vehicle FPGA's authoritative safety owner ----
  wire safe_stop;
  deadman_timer #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) dm (
    .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .safe_stop(safe_stop)
  );

  // ---- 4 absolute-position servos ----
  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) pan_pwm  (.clk(clk), .rst(rst), .pos(cmd_pan),   .pwm_out(servo_pan));
  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) tilt_pwm (.clk(clk), .rst(rst), .pos(cmd_tilt),  .pwm_out(servo_tilt));
  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) focus_pwm(.clk(clk), .rst(rst), .pos(cmd_focus), .pwm_out(servo_focus));
  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) zoom_pwm (.clk(clk), .rst(rst), .pos(cmd_zoom),  .pwm_out(servo_zoom));

  // ---- fire/load: pulse servos, not absolute-position ----
  wire [7:0] fire_pos, load_pos;
  wire fire_active, load_active;
  fire_load_pulse #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .ANGLE(40))  fire_fsm (.clk(clk), .rst(rst), .trigger(cmd_fire_pulse), .servo_pos(fire_pos), .active(fire_active));
  fire_load_pulse #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .ANGLE(120)) load_fsm (.clk(clk), .rst(rst), .trigger(cmd_load_pulse), .servo_pos(load_pos), .active(load_active));
  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) fire_pwm (.clk(clk), .rst(rst), .pos(fire_pos), .pwm_out(servo_fire));
  servo_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) load_pwm (.clk(clk), .rst(rst), .pos(load_pos), .pwm_out(servo_load));

  // ---- 2 drive motors, gated by the deadman timer ----
  motor_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) motor_l (
    .clk(clk), .rst(rst), .dir_in(cmd_motor_l_dir), .pwm_level(cmd_motor_l_pwm),
    .safe_stop(safe_stop), .dir_out(motor_l_dir_pin), .pwm_out(motor_l_pwm_pin)
  );
  motor_pwm #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) motor_r (
    .clk(clk), .rst(rst), .dir_in(cmd_motor_r_dir), .pwm_level(cmd_motor_r_pwm),
    .safe_stop(safe_stop), .dir_out(motor_r_dir_pin), .pwm_out(motor_r_pwm_pin)
  );
  // What telemetry reports as the "actual" motor state -- mirrors
  // esp32_firmware.ino's applyMotor() semantics, where the deadman check
  // forces motorL/motorR's own state (not just the pin) to 0, so
  // telemetry reflects reality even if a stale command is still latched
  // in command_registers.
  wire [7:0] motor_l_pwm_actual = safe_stop ? 8'd0 : cmd_motor_l_pwm;
  wire [7:0] motor_r_pwm_actual = safe_stop ? 8'd0 : cmd_motor_r_pwm;

  // ---- compass poll: periodic fixed transaction (see spi_compass_driver.v) ----
  // Poll period intentionally well longer than one SPI transaction takes
  // (3 bytes, microseconds) so a new poll never starts while the
  // previous one is still in flight -- no explicit busy interlock needed
  // at these defaults, but this assumption would need revisiting if
  // HEADING_POLL_MS were ever made much smaller.
  localparam HEADING_POLL_MS = 100;
  localparam integer HEADING_POLL_TICKS = (CLK_FREQ_HZ / 1000) * HEADING_POLL_MS;
  reg [$clog2(HEADING_POLL_TICKS + 1)-1:0] poll_cnt;
  reg compass_start;
  reg [15:0] heading_x10_reg;
  wire compass_done;
  wire [15:0] compass_read_data;

  always @(posedge clk) begin
    compass_start <= 1'b0;
    if (rst) begin
      poll_cnt        <= 0;
      heading_x10_reg <= 16'd0;
    end else begin
      if (poll_cnt >= HEADING_POLL_TICKS - 1) begin
        poll_cnt      <= 0;
        compass_start <= 1'b1;
      end else poll_cnt <= poll_cnt + 1'b1;

      if (compass_done)
        // BNO055 Euler heading register: 1 degree = 16 LSB (datasheet) ->
        // degrees*10 = raw*10/16 -- already a multiply+shift, not a real
        // divide (see fpga/README.md's LUT-budget finding on why that
        // matters). Swap this conversion for whatever the real chosen
        // compass part's register format turns out to be.
        heading_x10_reg <= (compass_read_data * 10) >> 4;
    end
  end

  spi_compass_driver #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) compass (
    .clk(clk), .rst(rst),
    .sclk(compass_sclk), .mosi(compass_mosi), .miso(compass_miso), .cs(compass_cs),
    .start(compass_start), .read_data(compass_read_data), .done(compass_done)
  );

  // ---- telemetry to the Pi ----
  telemetry_uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) telem (
    .clk(clk), .rst(rst),
    .heading_x10(heading_x10_reg),
    .pan(cmd_pan), .tilt(cmd_tilt), .focus(cmd_focus), .zoom(cmd_zoom),
    .fire_pos(fire_pos), .load_pos(load_pos),
    .motor_l_dir(cmd_motor_l_dir), .motor_r_dir(cmd_motor_r_dir),
    .motor_l_pwm(motor_l_pwm_actual), .motor_r_pwm(motor_r_pwm_actual),
    .uart_tx(pi_uart_tx)
  );
endmodule

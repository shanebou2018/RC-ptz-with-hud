// Top-level for the base-station Alchitry Cu V2: reads operator input
// (5 potentiometers via an MCP3008 SPI ADC for pan/tilt/zoom/throttle/
// turn, plus 2 pushbuttons for fire/load -- see operator_input_capture.v)
// and transmits commands over the E220 LoRa link, at a steady rate (the
// same packet doubles as the heartbeat -- see packet_encoder.v).
`include "packet_defs.vh"
`include "e220_driver.v"
`include "packet_encoder.v"
`include "operator_input_capture.v"
`include "mcp3008_adc.v"

module top_base #(
  parameter CLK_FREQ_HZ = 100_000_000 // see servo_pwm.v's header note (in fpga/vehicle/rtl) on this being unverified
)(
  input  wire clk100mhz,
  input  wire rst_n,

  input  wire lora_aux,
  output wire lora_m0,
  output wire lora_m1,
  output wire lora_uart_tx,
  input  wire lora_uart_rx,

  // MCP3008 ADC (via the Br breakout board) -- 5 pots: pan, tilt, zoom,
  // throttle, turn (channels 0-4, see operator_input_capture.v)
  output wire adc_sclk,
  output wire adc_mosi,
  input  wire adc_miso,
  output wire adc_cs,

  // fire/load pushbuttons
  input  wire btn_fire,
  input  wire btn_load
);
  wire clk = clk100mhz;
  wire rst = ~rst_n;

  // ---- ADC: continuously polls all 5 channels ----
  wire [49:0] adc_channel_values;
  wire adc_new_data;

  mcp3008_adc #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) adc (
    .clk(clk), .rst(rst),
    .sclk(adc_sclk), .mosi(adc_mosi), .miso(adc_miso), .cs(adc_cs),
    .channel_values(adc_channel_values), .new_data(adc_new_data)
  );

  // ---- operator input: ADC pots + 2 buttons -> command fields ----
  wire [7:0] op_pan, op_tilt, op_focus, op_zoom;
  wire op_fire, op_load, op_motor_l_dir, op_motor_r_dir;
  wire [7:0] op_motor_l_pwm, op_motor_r_pwm;

  operator_input_capture #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) opin (
    .clk(clk), .rst(rst), .send_pulse(send_pulse),
    .adc_channel_values(adc_channel_values), .adc_new_data(adc_new_data),
    .btn_fire(btn_fire), .btn_load(btn_load),
    .op_pan(op_pan), .op_tilt(op_tilt), .op_focus(op_focus), .op_zoom(op_zoom),
    .op_fire(op_fire), .op_load(op_load),
    .op_motor_l_dir(op_motor_l_dir), .op_motor_r_dir(op_motor_r_dir),
    .op_motor_l_pwm(op_motor_l_pwm), .op_motor_r_pwm(op_motor_r_pwm)
  );

  // ---- transmit a fresh packet at a steady rate (this IS the
  // heartbeat -- see packet_encoder.v's header comment on why there's no
  // separate lightweight heartbeat packet type) ----
  localparam SEND_INTERVAL_MS = 50; // placeholder -- bench-tune against real LoRa SF/BW (see CLAUDE.md's fork section)
  localparam integer SEND_INTERVAL_TICKS = (CLK_FREQ_HZ / 1000) * SEND_INTERVAL_MS;
  reg [$clog2(SEND_INTERVAL_TICKS + 1)-1:0] send_cnt;
  reg send_pulse;

  always @(posedge clk) begin
    send_pulse <= 1'b0;
    if (rst) begin
      send_cnt <= 0;
    end else if (send_cnt >= SEND_INTERVAL_TICKS - 1) begin
      send_cnt   <= 0;
      send_pulse <= 1'b1;
    end else begin
      send_cnt <= send_cnt + 1'b1;
    end
  end

  wire [8*`PKT_LEN-1:0] pkt_data;
  wire pkt_valid;
  wire [7:0] seq_out;

  packet_encoder encoder (
    .clk(clk), .rst(rst), .seed(`KEYSTREAM_SEED), .send(send_pulse),
    .pan(op_pan), .tilt(op_tilt), .focus(op_focus), .zoom(op_zoom),
    .fire(op_fire), .load(op_load),
    .motor_l_dir(op_motor_l_dir), .motor_r_dir(op_motor_r_dir),
    .motor_l_pwm(op_motor_l_pwm), .motor_r_pwm(op_motor_r_pwm),
    .pkt_data(pkt_data), .pkt_valid(pkt_valid), .seq_out(seq_out)
  );

  e220_driver #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) lora (
    .clk(clk), .rst(rst),
    .aux(lora_aux), .m0(lora_m0), .m1(lora_m1),
    .uart_tx(lora_uart_tx), .uart_rx(lora_uart_rx),
    .tx_start(pkt_valid), .tx_data(pkt_data), .tx_done(),
    .rx_data(), .rx_valid()   // no return channel by default -- see fork's open question 5
  );
endmodule

// Top-level for the base-station Alchitry Cu V2: reads operator input
// and transmits commands over the E220 LoRa link, at a steady rate (the
// same packet doubles as the heartbeat -- see packet_encoder.v).
//
// OPERATOR INPUT IS A STUB. The fork's plan left the operator input
// device as an open question (RC-style digital TX/RX pair vs. an analog
// joystick needing an ADC vs. a USB gamepad needing a front-end MCU) --
// this file wires fixed neutral/idle values (pan/tilt centered, zero
// throttle, no fire/load) instead of any real switches or potentiometers,
// so the design compiles and synthesizes for a LUT-utilization check
// (fpga/README.md) without blocking on that hardware decision. Replace
// operator_input_capture's body once the input device is chosen.
`include "packet_defs.vh"
`include "e220_driver.v"
`include "packet_encoder.v"

module top_base #(
  parameter CLK_FREQ_HZ = 100_000_000 // see servo_pwm.v's header note (in fpga/vehicle/rtl) on this being unverified
)(
  input  wire clk100mhz,
  input  wire rst_n,

  input  wire lora_aux,
  output wire lora_m0,
  output wire lora_m1,
  output wire lora_uart_tx,
  input  wire lora_uart_rx
);
  wire clk = clk100mhz;
  wire rst = ~rst_n;

  // ---- operator input (STUB -- see header comment) ----
  wire [7:0] op_pan   = 8'd90;
  wire [7:0] op_tilt  = 8'd90;
  wire [7:0] op_focus = 8'd0;
  wire [7:0] op_zoom  = 8'd0;
  wire op_fire = 1'b0;
  wire op_load = 1'b0;
  wire op_motor_l_dir = 1'b1;
  wire op_motor_r_dir = 1'b1;
  wire [7:0] op_motor_l_pwm = 8'd0;
  wire [7:0] op_motor_r_pwm = 8'd0;

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

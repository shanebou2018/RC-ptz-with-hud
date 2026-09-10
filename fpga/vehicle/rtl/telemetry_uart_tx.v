// Periodically frames the vehicle FPGA's current state (heading, 6 servo
// positions, 2 motor dir+pwm) into a small binary packet and sends it to
// the Pi over UART -- the vehicle-side half of the telemetry-only link
// described in CLAUDE.md's fork section (the Pi has zero control
// authority in this fork; this is a one-way vehicle-FPGA -> Pi feed).
// control/vehicle_fpga_bridge.py decodes this binary frame and
// re-serializes it to the same JSON shape the HUD's websocket already
// expects -- deliberately binary here rather than generating JSON/ASCII
// text in hand-written Verilog, which would be needless complexity for
// no benefit (the Pi has a full Python environment to do that
// formatting).
//
// Frame layout (12 bytes + 2 CRC bytes = 14 bytes total), sent once
// every TELEMETRY_INTERVAL_MS:
//   0:    sync byte (TELEM_SYNC)
//   1-2:  heading, degrees x10 as a fixed-point uint16 (e.g. 1234 = 123.4 deg), MSB first
//   3-8:  pan, tilt, focus, zoom, fire, load (0-180 each, one byte each)
//   9:    flags: bit0=motor L dir, bit1=motor R dir
//   10:   motor L pwm (0-MAX_MOTOR_PWM)
//   11:   motor R pwm (0-MAX_MOTOR_PWM)
//   12-13: CRC16 (crc16.v) over bytes 0-11
`include "packet_defs.vh"
`include "crc16.v"
`include "uart_engine.v"

module telemetry_uart_tx #(
  parameter CLK_FREQ_HZ           = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter UART_BAUD             = 115_200,      // matches today's ESP32<->Pi link speed
  parameter TELEMETRY_INTERVAL_MS = 100            // matches esp32_firmware.ino's TELEMETRY_INTERVAL_MS
)(
  input  wire       clk,
  input  wire       rst,

  input  wire [15:0] heading_x10,   // degrees * 10
  input  wire [7:0]  pan, tilt, focus, zoom, fire_pos, load_pos,
  input  wire        motor_l_dir,
  input  wire        motor_r_dir,
  input  wire [7:0]  motor_l_pwm,
  input  wire [7:0]  motor_r_pwm,

  output wire uart_tx
);
  localparam [7:0] TELEM_SYNC = 8'h5A;
  localparam FRAME_LEN = 14;

  localparam integer INTERVAL_TICKS = (CLK_FREQ_HZ / 1000) * TELEMETRY_INTERVAL_MS;
  localparam CNT_WIDTH = $clog2(INTERVAL_TICKS + 1);
  reg [CNT_WIDTH-1:0] interval_cnt;
  reg send_frame;

  always @(posedge clk) begin
    send_frame <= 1'b0;
    if (rst) begin
      interval_cnt <= 0;
    end else if (interval_cnt >= INTERVAL_TICKS - 1) begin
      interval_cnt <= 0;
      send_frame   <= 1'b1;
    end else begin
      interval_cnt <= interval_cnt + 1'b1;
    end
  end

  reg [7:0] frame [0:FRAME_LEN-1];
  integer i;
  reg [15:0] crc;

  reg uart_tx_start;
  reg [7:0] uart_tx_byte;
  wire uart_tx_busy;
  reg [3:0] byte_idx;

  localparam S_IDLE=0, S_BUILD=1, S_ISSUE=2, S_ISSUE_WAIT=3, S_WAIT_BYTE=4;
  reg [2:0] state;

  uart_engine #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(UART_BAUD)) uart (
    .clk(clk), .rst(rst),
    .tx_start(uart_tx_start), .tx_byte(uart_tx_byte), .tx_busy(uart_tx_busy), .tx(uart_tx),
    .rx(1'b1), .rx_byte(), .rx_valid()  // this link is TX-only (telemetry to the Pi)
  );

  always @(posedge clk) begin
    uart_tx_start <= 1'b0;
    if (rst) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: begin
          if (send_frame) state <= S_BUILD;
        end
        S_BUILD: begin
          frame[0]  = TELEM_SYNC;
          frame[1]  = heading_x10[15:8];
          frame[2]  = heading_x10[7:0];
          frame[3]  = pan;
          frame[4]  = tilt;
          frame[5]  = focus;
          frame[6]  = zoom;
          frame[7]  = fire_pos;
          frame[8]  = load_pos;
          frame[9]  = {6'b0, motor_r_dir, motor_l_dir};
          frame[10] = motor_l_pwm;
          frame[11] = motor_r_pwm;
          crc = 16'hFFFF;
          for (i = 0; i <= 11; i = i + 1)
            crc = crc16_step(crc, frame[i]);
          frame[12] = crc[15:8];
          frame[13] = crc[7:0];
          byte_idx  <= 4'd0;
          state     <= S_ISSUE;
        end
        S_ISSUE: begin
          uart_tx_byte  <= frame[byte_idx];
          uart_tx_start <= 1'b1;
          state         <= S_ISSUE_WAIT;
        end
        // same one-cycle handshake guard as e220_driver.v's TX path --
        // uart_tx_busy takes one cycle to rise after uart_tx_start pulses.
        S_ISSUE_WAIT: state <= S_WAIT_BYTE;
        S_WAIT_BYTE: begin
          if (!uart_tx_busy) begin
            if (byte_idx == FRAME_LEN - 1) begin
              state <= S_IDLE;
            end else begin
              byte_idx <= byte_idx + 4'd1;
              state    <= S_ISSUE;
            end
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule

// Generic 8N1 UART transmitter + receiver, used by e220_driver.v to talk
// to the E220-900T22D's UART interface (default 9600 baud) and by
// telemetry_uart_tx.v for the vehicle-FPGA-to-Pi link. One bit sampled
// per bit period (no oversampling/majority-vote) -- adequate given the
// huge ratio between the fabric clock and any UART baud rate in this
// design; not meant for baud rates anywhere near the fabric clock.
`ifndef UART_ENGINE_V
`define UART_ENGINE_V

module uart_engine #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter BAUD        = 9_600
)(
  input  wire       clk,
  input  wire       rst,

  input  wire       tx_start,
  input  wire [7:0] tx_byte,
  output reg          tx_busy,
  output reg          tx,        // idle high

  input  wire       rx,          // idle high
  output reg  [7:0] rx_byte,
  output reg          rx_valid    // one-cycle pulse
);
  localparam integer BAUD_DIV = CLK_FREQ_HZ / BAUD;
  localparam CNT_WIDTH = $clog2(BAUD_DIV + 1);

  // ---- TX ----
  localparam TX_IDLE=0, TX_START=1, TX_DATA=2, TX_STOP=3;
  reg [1:0] tx_state;
  reg [CNT_WIDTH-1:0] tx_div_cnt;
  reg [2:0] tx_bit_idx;
  reg [7:0] tx_shift;

  always @(posedge clk) begin
    if (rst) begin
      tx_state <= TX_IDLE;
      tx       <= 1'b1;
      tx_busy  <= 1'b0;
    end else begin
      case (tx_state)
        TX_IDLE: begin
          tx <= 1'b1;
          if (tx_start) begin
            tx_shift   <= tx_byte;
            tx_busy    <= 1'b1;
            tx_div_cnt <= 0;
            tx_state   <= TX_START;
          end else begin
            tx_busy <= 1'b0;
          end
        end
        TX_START: begin
          tx <= 1'b0;
          if (tx_div_cnt >= BAUD_DIV - 1) begin
            tx_div_cnt <= 0;
            tx_bit_idx <= 3'd0;
            tx_state   <= TX_DATA;
          end else tx_div_cnt <= tx_div_cnt + 1'b1;
        end
        TX_DATA: begin
          tx <= tx_shift[0];
          if (tx_div_cnt >= BAUD_DIV - 1) begin
            tx_div_cnt <= 0;
            if (tx_bit_idx == 3'd7) begin
              tx_state <= TX_STOP;
            end else begin
              tx_bit_idx <= tx_bit_idx + 1'b1;
              tx_shift   <= tx_shift >> 1;
            end
          end else tx_div_cnt <= tx_div_cnt + 1'b1;
        end
        TX_STOP: begin
          tx <= 1'b1;
          if (tx_div_cnt >= BAUD_DIV - 1) begin
            tx_div_cnt <= 0;
            tx_busy    <= 1'b0;
            tx_state   <= TX_IDLE;
          end else tx_div_cnt <= tx_div_cnt + 1'b1;
        end
        default: tx_state <= TX_IDLE;
      endcase
    end
  end

  // ---- RX ----
  localparam RX_IDLE=0, RX_START=1, RX_DATA=2, RX_STOP=3;
  reg [1:0] rx_state;
  reg [CNT_WIDTH-1:0] rx_div_cnt;
  reg [2:0] rx_bit_idx;
  reg [7:0] rx_shift;
  reg rx_sync1, rx_sync2; // 2-FF synchronizer for the async serial input

  always @(posedge clk) begin
    rx_sync1 <= rx;
    rx_sync2 <= rx_sync1;
  end

  always @(posedge clk) begin
    rx_valid <= 1'b0;
    if (rst) begin
      rx_state <= RX_IDLE;
    end else begin
      case (rx_state)
        RX_IDLE: begin
          if (rx_sync2 == 1'b0) begin // falling edge (start bit) detected
            rx_div_cnt <= BAUD_DIV / 2; // sample future bits mid-period
            rx_state   <= RX_START;
          end
        end
        RX_START: begin
          if (rx_div_cnt >= BAUD_DIV - 1) begin
            rx_div_cnt <= 0;
            rx_bit_idx <= 3'd0;
            rx_state   <= RX_DATA;
          end else rx_div_cnt <= rx_div_cnt + 1'b1;
        end
        RX_DATA: begin
          if (rx_div_cnt >= BAUD_DIV - 1) begin
            rx_div_cnt <= 0;
            rx_shift   <= {rx_sync2, rx_shift[7:1]}; // shift in LSB-first
            if (rx_bit_idx == 3'd7) begin
              rx_state <= RX_STOP;
            end else begin
              rx_bit_idx <= rx_bit_idx + 1'b1;
            end
          end else rx_div_cnt <= rx_div_cnt + 1'b1;
        end
        RX_STOP: begin
          if (rx_div_cnt >= BAUD_DIV - 1) begin
            rx_div_cnt <= 0;
            if (rx_sync2 == 1'b1) begin // valid stop bit
              rx_byte  <= rx_shift;
              rx_valid <= 1'b1;
            end
            rx_state <= RX_IDLE;
          end else rx_div_cnt <= rx_div_cnt + 1'b1;
        end
        default: rx_state <= RX_IDLE;
      endcase
    end
  end
endmodule

`endif

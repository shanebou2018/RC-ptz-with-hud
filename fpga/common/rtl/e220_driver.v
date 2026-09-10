// Driver for the EBYTE E220-900T22D LoRa module (LLCC68-based, UART host
// interface -- NOT SPI; see CLAUDE.md's fork section for why this
// replaced an earlier SX127x-SPI design). Held permanently in Mode 0
// (M0=0, M1=0 -- "Normal": UART <-> LoRa air interface open, transparent
// pass-through) -- this driver never enters the module's configuration
// mode, so it runs entirely on the module's factory-default settings
// (9600 baud 8N1, default address/channel, default air data rate). See
// fpga/README.md for what that means and what configuring a private
// channel/address would need.
//
// TX: waits for AUX high (module idle/ready -- low during its own
// power-up self-check or while still flushing a previous transmission)
// before streaming the 12-byte packet out over UART, back-to-back. In
// transparent mode the module transmits over the air whatever bytes it
// receives on UART, to every other module sharing its (default)
// address/channel -- there is no separate "send" command.
//
// RX: transparent mode delivers received-over-the-air bytes straight out
// the module's UART with no framing of its own, so this driver frames
// packets itself by scanning the incoming byte stream for PKT_SYNC
// (packet_defs.vh) and collecting the following PKT_LEN-1 bytes. This
// can misframe if a payload byte happens to equal PKT_SYNC mid-stream --
// packet_decoder.v's CRC check downstream simply rejects the resulting
// garbage packet (wastes one packet, not a persistent desync; framing
// re-syncs on the very next real sync byte). A documented limitation of
// a framing-less transparent-serial radio, not a bug.
`include "packet_defs.vh"
`include "uart_engine.v"

module e220_driver #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter BAUD        = 9_600         // E220 factory default
)(
  input  wire clk,
  input  wire rst,

  input  wire aux,        // from module: high=idle/ready, low=busy/self-check
  output wire m0,          // tie to module's M0 -- held low (Mode 0 = Normal/transparent)
  output wire m1,          // tie to module's M1 -- held low
  output wire uart_tx,     // to module's RXD
  input  wire uart_rx,     // from module's TXD

  input  wire tx_start,
  input  wire [8*`PKT_LEN-1:0] tx_data,
  output reg   tx_done,     // one-cycle pulse once all 12 bytes are handed to the module over UART (not a guarantee of over-the-air completion -- there's no ack in transparent mode)

  output reg  [8*`PKT_LEN-1:0] rx_data,
  output reg   rx_valid      // one-cycle pulse: rx_data holds a freshly framed 12-byte packet
);
  assign m0 = 1'b0;
  assign m1 = 1'b0;

  reg uart_tx_start;
  reg [7:0] uart_tx_byte;
  wire uart_tx_busy;
  wire [7:0] uart_rx_byte;
  wire uart_rx_valid;

  uart_engine #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) uart (
    .clk(clk), .rst(rst),
    .tx_start(uart_tx_start), .tx_byte(uart_tx_byte), .tx_busy(uart_tx_busy), .tx(uart_tx),
    .rx(uart_rx), .rx_byte(uart_rx_byte), .rx_valid(uart_rx_valid)
  );

  // ---- TX: wait for AUX idle, then stream PKT_LEN bytes ----
  reg [8*`PKT_LEN-1:0] tx_data_latched;
  reg [3:0] tx_byte_idx;
  localparam TX_IDLE=0, TX_WAIT_AUX=1, TX_ISSUE=2, TX_ISSUE_WAIT=3, TX_WAIT_BYTE=4;
  reg [2:0] tx_state;

  always @(posedge clk) begin
    uart_tx_start <= 1'b0;
    tx_done       <= 1'b0;
    if (rst) begin
      tx_state <= TX_IDLE;
    end else begin
      case (tx_state)
        TX_IDLE: begin
          if (tx_start) begin
            tx_data_latched <= tx_data;
            tx_byte_idx     <= 4'd0;
            tx_state        <= TX_WAIT_AUX;
          end
        end
        TX_WAIT_AUX: begin
          if (aux) tx_state <= TX_ISSUE;
        end
        TX_ISSUE: begin
          uart_tx_byte  <= tx_data_latched[8*tx_byte_idx +: 8];
          uart_tx_start <= 1'b1;
          tx_state      <= TX_ISSUE_WAIT;
        end
        // uart_tx_start was just pulsed this cycle -- the inner
        // uart_engine hasn't had a chance to raise uart_tx_busy yet
        // (that takes one more clock edge to take effect), so checking
        // "!uart_tx_busy" immediately here would falsely read as "already
        // done" before the byte even started transmitting. Wait exactly
        // one cycle so TX_WAIT_BYTE's busy check only ever sees busy
        // genuinely rise-then-fall, not a stale pre-start value.
        TX_ISSUE_WAIT: begin
          tx_state <= TX_WAIT_BYTE;
        end
        TX_WAIT_BYTE: begin
          if (!uart_tx_busy) begin
            if (tx_byte_idx == `PKT_LEN - 1) begin
              tx_done  <= 1'b1;
              tx_state <= TX_IDLE;
            end else begin
              tx_byte_idx <= tx_byte_idx + 4'd1;
              tx_state    <= TX_ISSUE;
            end
          end
        end
        default: tx_state <= TX_IDLE;
      endcase
    end
  end

  // ---- RX: scan for PKT_SYNC, then collect PKT_LEN bytes ----
  reg framing;
  reg [3:0] rx_byte_idx;

  always @(posedge clk) begin
    rx_valid <= 1'b0;
    if (rst) begin
      framing <= 1'b0;
    end else if (uart_rx_valid) begin
      if (!framing) begin
        if (uart_rx_byte == `PKT_SYNC) begin
          rx_data[8*0 +: 8] <= uart_rx_byte;
          rx_byte_idx        <= 4'd1;
          framing             <= 1'b1;
        end
      end else begin
        rx_data[8*rx_byte_idx +: 8] <= uart_rx_byte;
        if (rx_byte_idx == `PKT_LEN - 1) begin
          rx_valid <= 1'b1;
          framing  <= 1'b0;
        end else begin
          rx_byte_idx <= rx_byte_idx + 4'd1;
        end
      end
    end
  end
endmodule

`include "uart_engine.v"

// Bare-bones behavioral stand-in for an E220-900T22D module, for
// simulating e220_driver.v without real hardware. Understands nothing
// about LoRa RF -- just: bytes arriving on its host-facing UART (rxd) get
// forwarded out its "air" port (as if transmitted over the air), and
// bytes arriving on its "air" port (as if received over the air) get
// sent out its host-facing UART (txd). AUX goes low for BUSY_CYCLES after
// each byte from the host, to exercise the real driver's AUX-wait gating
// in simulation rather than trivially always reporting idle.
//
// Two instances, cross-wired air_byte/air_byte_valid <-> air_in_byte/
// air_in_valid in the testbench, simulate a base<->vehicle LoRa pair.
module e220_model #(
  parameter CLK_FREQ_HZ = 100_000_000,
  parameter BAUD        = 9_600,
  parameter BUSY_CYCLES = 50
)(
  input  wire clk,
  input  wire rst,
  input  wire rxd,
  output wire txd,
  output reg   aux,

  output reg          air_byte_valid,
  output reg  [7:0]   air_byte,
  input  wire         air_in_valid,
  input  wire [7:0]   air_in_byte
);
  wire [7:0] host_rx_byte;
  wire host_rx_valid;
  reg host_tx_start;
  reg [7:0] host_tx_byte;
  wire host_tx_busy;

  uart_engine #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) host_uart (
    .clk(clk), .rst(rst),
    .tx_start(host_tx_start), .tx_byte(host_tx_byte), .tx_busy(host_tx_busy), .tx(txd),
    .rx(rxd), .rx_byte(host_rx_byte), .rx_valid(host_rx_valid)
  );

  reg [31:0] busy_cnt;
  always @(posedge clk) begin
    air_byte_valid <= 1'b0;
    if (rst) begin
      aux      <= 1'b1;
      busy_cnt <= 0;
    end else if (host_rx_valid) begin
      air_byte       <= host_rx_byte;
      air_byte_valid <= 1'b1;
      aux            <= 1'b0;
      busy_cnt       <= BUSY_CYCLES;
    end else if (busy_cnt != 0) begin
      busy_cnt <= busy_cnt - 1;
      if (busy_cnt == 1) aux <= 1'b1;
    end
  end

  always @(posedge clk) begin
    host_tx_start <= 1'b0;
    if (!rst && air_in_valid && !host_tx_busy) begin
      host_tx_byte  <= air_in_byte;
      host_tx_start <= 1'b1;
    end
  end
endmodule

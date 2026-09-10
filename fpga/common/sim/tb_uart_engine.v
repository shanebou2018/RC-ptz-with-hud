`timescale 1ns/1ps
`include "uart_engine.v"

// Loopback test: tx pin wired directly to rx pin. Scaled-down clock/baud
// (1MHz/100kbaud -> BAUD_DIV=10) for a fast but still multi-cycle-per-bit
// simulation.
module tb_uart_engine;
  localparam CLK_FREQ_HZ = 1_000_000;
  localparam BAUD = 100_000;

  reg clk = 0;
  reg rst = 1;
  reg tx_start = 0;
  reg [7:0] tx_byte = 8'h00;
  wire tx_busy, tx_line;
  wire [7:0] rx_byte;
  wire rx_valid;

  uart_engine #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) dut (
    .clk(clk), .rst(rst),
    .tx_start(tx_start), .tx_byte(tx_byte), .tx_busy(tx_busy), .tx(tx_line),
    .rx(tx_line), // loopback
    .rx_byte(rx_byte), .rx_valid(rx_valid)
  );

  always #500 clk = ~clk; // 1MHz

  integer errors = 0;

  task send_and_check(input [7:0] b);
    integer waited;
    begin
      @(negedge clk); tx_start = 1; tx_byte = b;
      @(posedge clk);
      @(negedge clk); tx_start = 0;
      waited = 0;
      while (rx_valid !== 1'b1 && waited < 2000) begin
        @(posedge clk);
        #1; // let this edge's nonblocking updates settle before re-checking rx_valid
        waited = waited + 1;
      end
      if (rx_valid !== 1'b1) begin
        $display("FAIL: byte %h never arrived (rx_valid timeout)", b);
        errors = errors + 1;
      end else if (rx_byte !== b) begin
        $display("FAIL: sent %h, received %h", b, rx_byte);
        errors = errors + 1;
      end else begin
        $display("PASS: byte %h round-tripped correctly", b);
      end
      // wait for tx_busy to clear before sending the next byte
      waited = 0;
      while (tx_busy === 1'b1 && waited < 2000) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
      end
    end
  endtask

  initial begin
    @(negedge clk); rst = 0;
    @(negedge clk);

    send_and_check(8'hA5);
    send_and_check(8'h00);
    send_and_check(8'hFF);
    send_and_check(8'h3C);

    if (errors == 0) $display("ALL UART_ENGINE TESTS PASSED");
    else $display("%0d UART_ENGINE TEST(S) FAILED", errors);
    $finish;
  end
endmodule

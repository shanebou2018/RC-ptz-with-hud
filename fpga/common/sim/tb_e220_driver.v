`timescale 1ns/1ps
`include "packet_defs.vh"
`include "e220_driver.v"
`include "e220_model.v"

// Full loop: driver A -> model A -> ("air") -> model B -> driver B, and
// the reverse, simulating a base<->vehicle E220 pair. Scaled-down
// clock/baud for a fast but still bit-accurate simulation.
module tb_e220_driver;
  localparam CLK_FREQ_HZ = 1_000_000;
  localparam BAUD = 100_000;

  reg clk = 0;
  reg rst = 1;
  always #500 clk = ~clk;

  // ---- driver A (acts as "base") ----
  reg tx_start_a = 0;
  reg [8*`PKT_LEN-1:0] tx_data_a = 0;
  wire tx_done_a;
  wire [8*`PKT_LEN-1:0] rx_data_a;
  wire rx_valid_a;
  wire uart_tx_a, m0_a, m1_a;
  wire aux_a;

  e220_driver #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) drv_a (
    .clk(clk), .rst(rst), .aux(aux_a), .m0(m0_a), .m1(m1_a),
    .uart_tx(uart_tx_a), .uart_rx(model_a_txd),
    .tx_start(tx_start_a), .tx_data(tx_data_a), .tx_done(tx_done_a),
    .rx_data(rx_data_a), .rx_valid(rx_valid_a)
  );

  // ---- driver B (acts as "vehicle") ----
  reg tx_start_b = 0;
  reg [8*`PKT_LEN-1:0] tx_data_b = 0;
  wire tx_done_b;
  wire [8*`PKT_LEN-1:0] rx_data_b;
  wire rx_valid_b;
  wire uart_tx_b, m0_b, m1_b;
  wire aux_b;

  e220_driver #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) drv_b (
    .clk(clk), .rst(rst), .aux(aux_b), .m0(m0_b), .m1(m1_b),
    .uart_tx(uart_tx_b), .uart_rx(model_b_txd),
    .tx_start(tx_start_b), .tx_data(tx_data_b), .tx_done(tx_done_b),
    .rx_data(rx_data_b), .rx_valid(rx_valid_b)
  );

  // ---- models, cross-wired "air" ports ----
  wire model_a_txd, model_b_txd;
  wire air_a_valid, air_b_valid;
  wire [7:0] air_a_byte, air_b_byte;

  e220_model #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD), .BUSY_CYCLES(30)) model_a (
    .clk(clk), .rst(rst), .rxd(uart_tx_a), .txd(model_a_txd), .aux(aux_a),
    .air_byte_valid(air_a_valid), .air_byte(air_a_byte),
    .air_in_valid(air_b_valid), .air_in_byte(air_b_byte)
  );
  e220_model #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD), .BUSY_CYCLES(30)) model_b (
    .clk(clk), .rst(rst), .rxd(uart_tx_b), .txd(model_b_txd), .aux(aux_b),
    .air_byte_valid(air_b_valid), .air_byte(air_b_byte),
    .air_in_valid(air_a_valid), .air_in_byte(air_a_byte)
  );

  integer errors = 0;

  initial begin
    @(negedge clk); rst = 0;

    // --- A -> B ---
    tx_data_a = {96'h0}; // will be overwritten byte-by-byte below
    tx_data_a[8*`PKT_IDX_SYNC +: 8] = `PKT_SYNC;
    tx_data_a[8*`PKT_IDX_SEQ  +: 8] = 8'h07;
    tx_data_a[8*2 +: 8] = 8'd42;  // arbitrary payload bytes, framing doesn't care about content
    tx_data_a[8*3 +: 8] = 8'd99;
    @(negedge clk); tx_start_a = 1;
    @(posedge clk);
    @(negedge clk); tx_start_a = 0;

    begin : wait_b_rx
      integer waited;
      waited = 0;
      while (rx_valid_b !== 1'b1 && waited < 20000) begin
        @(posedge clk); #1;
        waited = waited + 1;
      end
      if (rx_valid_b !== 1'b1) begin
        $display("FAIL: driver B never received the packet from driver A (timeout)");
        errors = errors + 1;
      end else if (rx_data_b !== tx_data_a) begin
        $display("FAIL: driver B's received packet does not match what A sent (got %h, expected %h)", rx_data_b, tx_data_a);
        errors = errors + 1;
      end else begin
        $display("PASS: A -> B packet round-trips correctly over the (simulated) air link");
      end
    end

    // --- B -> A, proving the link works in the reverse direction too ---
    tx_data_b[8*`PKT_IDX_SYNC +: 8] = `PKT_SYNC;
    tx_data_b[8*`PKT_IDX_SEQ  +: 8] = 8'hEE;
    tx_data_b[8*2 +: 8] = 8'd7;
    @(negedge clk); tx_start_b = 1;
    @(posedge clk);
    @(negedge clk); tx_start_b = 0;

    begin : wait_a_rx
      integer waited;
      waited = 0;
      while (rx_valid_a !== 1'b1 && waited < 20000) begin
        @(posedge clk); #1;
        waited = waited + 1;
      end
      if (rx_valid_a !== 1'b1) begin
        $display("FAIL: driver A never received the packet from driver B (timeout)");
        errors = errors + 1;
      end else if (rx_data_a !== tx_data_b) begin
        $display("FAIL: driver A's received packet does not match what B sent");
        errors = errors + 1;
      end else begin
        $display("PASS: B -> A packet round-trips correctly over the (simulated) air link");
      end
    end

    if (errors == 0) $display("ALL E220_DRIVER TESTS PASSED");
    else $display("%0d E220_DRIVER TEST(S) FAILED", errors);
    $finish;
  end
endmodule

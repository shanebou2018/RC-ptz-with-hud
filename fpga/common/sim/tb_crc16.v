`timescale 1ns/1ps
`include "crc16.v"

// Verifies crc16_step()/the crc16 module against the standard CRC-16/
// CCITT-FALSE check value for ASCII "123456789" (0x29B1) -- the standard
// test vector for this exact poly/init/xorout combination -- before
// trusting it anywhere in packet_encoder.v/packet_decoder.v.
module tb_crc16;
  reg clk = 0;
  reg rst = 0;
  reg load_init = 0;
  reg byte_valid = 0;
  reg [7:0] data_in = 0;
  wire [15:0] crc_out;

  crc16 dut (
    .clk(clk), .rst(rst), .load_init(load_init),
    .byte_valid(byte_valid), .data_in(data_in), .crc_out(crc_out)
  );

  always #5 clk = ~clk;

  reg [7:0] msg [0:8];
  integer i;
  integer errors = 0;

  initial begin
    msg[0] = "1"; msg[1] = "2"; msg[2] = "3"; msg[3] = "4"; msg[4] = "5";
    msg[5] = "6"; msg[6] = "7"; msg[7] = "8"; msg[8] = "9";

    // --- module-based streaming check ---
    // Drive control signals on negedge so they're stable well before the
    // DUT's posedge-triggered always block samples them -- avoids a
    // classic testbench race between this initial block and the DUT.
    @(negedge clk); load_init = 1;
    @(posedge clk);
    @(negedge clk); load_init = 0;
    for (i = 0; i < 9; i = i + 1) begin
      @(negedge clk);
      data_in = msg[i];
      byte_valid = 1;
      @(posedge clk);
      #1 byte_valid = 0;
    end
    #1;
    if (crc_out !== 16'h29B1) begin
      $display("FAIL: crc16 module streaming result = %h, expected 29B1", crc_out);
      errors = errors + 1;
    end else begin
      $display("PASS: crc16 module streaming result = 29B1");
    end

    // --- function-based unrolled-loop check (mirrors how
    //     packet_encoder/decoder will actually use it) ---
    begin : func_check
      reg [15:0] crc;
      crc = 16'hFFFF;
      for (i = 0; i < 9; i = i + 1)
        crc = crc16_step(crc, msg[i]);
      if (crc !== 16'h29B1) begin
        $display("FAIL: crc16_step() unrolled result = %h, expected 29B1", crc);
        errors = errors + 1;
      end else begin
        $display("PASS: crc16_step() unrolled result = 29B1");
      end
    end

    // --- sanity: a corrupted byte must change the CRC ---
    begin : corruption_check
      reg [15:0] crc_good, crc_bad;
      reg [7:0] corrupted [0:8];
      for (i = 0; i < 9; i = i + 1) corrupted[i] = msg[i];
      corrupted[3] = corrupted[3] ^ 8'h01;  // flip one bit
      crc_good = 16'hFFFF;
      crc_bad = 16'hFFFF;
      for (i = 0; i < 9; i = i + 1) crc_good = crc16_step(crc_good, msg[i]);
      for (i = 0; i < 9; i = i + 1) crc_bad = crc16_step(crc_bad, corrupted[i]);
      if (crc_good === crc_bad) begin
        $display("FAIL: corrupted payload produced the same CRC");
        errors = errors + 1;
      end else begin
        $display("PASS: corrupted payload produces a different CRC (%h vs %h)", crc_good, crc_bad);
      end
    end

    if (errors == 0) $display("ALL CRC16 TESTS PASSED");
    else $display("%0d CRC16 TEST(S) FAILED", errors);
    $finish;
  end
endmodule

`timescale 1ns/1ps
`include "mcp3008_adc.v"
`include "mcp3008_model.v"

module tb_mcp3008_adc;
  localparam CLK_FREQ_HZ = 1_000_000;
  localparam SPI_CLK_DIV = 5;
  localparam NUM_CHANNELS = 5;

  reg clk = 0;
  reg rst = 1;
  wire sclk, mosi, cs, miso;
  wire [10*NUM_CHANNELS-1:0] channel_values;
  wire new_data;

  mcp3008_adc #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SPI_CLK_DIV(SPI_CLK_DIV), .NUM_CHANNELS(NUM_CHANNELS)) dut (
    .clk(clk), .rst(rst), .sclk(sclk), .mosi(mosi), .miso(miso), .cs(cs),
    .channel_values(channel_values), .new_data(new_data)
  );

  mcp3008_model #(.CH0(10'd111), .CH1(10'd222), .CH2(10'd333), .CH3(10'd444), .CH4(10'd555)) model (
    .sclk(sclk), .mosi(mosi), .cs(cs), .miso(miso)
  );

  always #5 clk = ~clk;
  integer errors = 0;

  initial begin
    @(negedge clk); rst = 0;

    begin : wait_round
      integer waited;
      waited = 0;
      while (new_data !== 1'b1 && waited < 20000) begin
        @(posedge clk); #1;
        waited = waited + 1;
      end
      if (new_data !== 1'b1) begin
        $display("FAIL: a full round of all channels never completed (timeout)");
        errors = errors + 1;
      end else $display("PASS: a full round completed (waited %0d cycles)", waited);
    end

    if (channel_values[10*0 +: 10] !== 10'd111) begin
      $display("FAIL: channel 0 = %0d, expected 111", channel_values[10*0 +: 10]);
      errors = errors + 1;
    end else $display("PASS: channel 0 = 111");

    if (channel_values[10*1 +: 10] !== 10'd222) begin
      $display("FAIL: channel 1 = %0d, expected 222", channel_values[10*1 +: 10]);
      errors = errors + 1;
    end else $display("PASS: channel 1 = 222");

    if (channel_values[10*2 +: 10] !== 10'd333) begin
      $display("FAIL: channel 2 = %0d, expected 333", channel_values[10*2 +: 10]);
      errors = errors + 1;
    end else $display("PASS: channel 2 = 333");

    if (channel_values[10*3 +: 10] !== 10'd444) begin
      $display("FAIL: channel 3 = %0d, expected 444", channel_values[10*3 +: 10]);
      errors = errors + 1;
    end else $display("PASS: channel 3 = 444");

    if (channel_values[10*4 +: 10] !== 10'd555) begin
      $display("FAIL: channel 4 = %0d, expected 555", channel_values[10*4 +: 10]);
      errors = errors + 1;
    end else $display("PASS: channel 4 = 555");

    // confirm it keeps polling: a second round also completes
    begin : wait_round2
      integer waited;
      waited = 0;
      while (new_data !== 1'b1 && waited < 20000) begin
        @(posedge clk); #1;
        waited = waited + 1;
      end
      if (new_data !== 1'b1) begin
        $display("FAIL: a second round never completed -- driver doesn't keep polling");
        errors = errors + 1;
      end else $display("PASS: driver continues polling after the first round");
    end

    if (errors == 0) $display("ALL MCP3008_ADC TESTS PASSED");
    else $display("%0d MCP3008_ADC TEST(S) FAILED", errors);
    $finish;
  end
endmodule

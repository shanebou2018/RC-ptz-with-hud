`timescale 1ns/1ps
`include "spi_compass_driver.v"
`include "spi_compass_model.v"

module tb_spi_compass_driver;
  localparam CLK_FREQ_HZ = 1_000_000;
  localparam SPI_CLK_DIV = 5;

  reg clk = 0;
  reg rst = 1;
  reg start = 0;
  wire sclk, mosi, miso, cs;
  wire [15:0] read_data;
  wire done;

  spi_compass_driver #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SPI_CLK_DIV(SPI_CLK_DIV)) dut (
    .clk(clk), .rst(rst), .sclk(sclk), .mosi(mosi), .miso(miso), .cs(cs),
    .start(start), .read_data(read_data), .done(done)
  );

  spi_compass_model #(.LSB_VALUE(8'hA0), .MSB_VALUE(8'h05)) model (
    .sclk(sclk), .mosi(mosi), .cs(cs), .miso(miso)
  );

  always #5 clk = ~clk;
  integer errors = 0;

  initial begin
    @(negedge clk); rst = 0;
    @(negedge clk); start = 1;
    @(posedge clk);
    @(negedge clk); start = 0;

    begin : wait_done
      integer waited;
      waited = 0;
      while (done !== 1'b1 && waited < 20000) begin
        @(posedge clk); #1;
        waited = waited + 1;
      end
      if (done !== 1'b1) begin
        $display("FAIL: transaction never completed (timeout)");
        errors = errors + 1;
      end else $display("PASS: transaction completed (waited %0d cycles)", waited);
    end

    if (read_data !== 16'h05A0) begin
      $display("FAIL: read_data = %h, expected 05a0 (MSB=05, LSB=a0)", read_data);
      errors = errors + 1;
    end else $display("PASS: read_data = 05a0 (MSB/LSB combined correctly)");

    if (errors == 0) $display("ALL SPI_COMPASS_DRIVER TESTS PASSED");
    else $display("%0d SPI_COMPASS_DRIVER TEST(S) FAILED", errors);
    $finish;
  end
endmodule

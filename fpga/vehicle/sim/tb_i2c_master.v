`timescale 1ns/1ps
`include "i2c_master.v"
`include "i2c_slave_model.v"

// Scaled-down clock so a 100kHz-equivalent I2C bus period is fast to
// simulate. tri1 models the bus's external pull-up: reads high when
// neither master nor slave actively pulls it low, matching real
// open-drain I2C wiring.
module tb_i2c_master;
  localparam CLK_FREQ_HZ = 1_000_000;
  localparam I2C_FREQ_HZ = 100_000;

  reg clk = 0;
  reg rst = 1;
  wire scl;
  tri1 sda;

  reg start = 0;
  reg [6:0] dev_addr = 7'h28;
  reg [7:0] reg_addr = 8'h1A;
  wire [15:0] read_data;
  wire done, nack_error;

  i2c_master #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .I2C_FREQ_HZ(I2C_FREQ_HZ)) dut (
    .clk(clk), .rst(rst), .scl(scl), .sda(sda),
    .start(start), .dev_addr(dev_addr), .reg_addr(reg_addr),
    .read_data(read_data), .done(done), .nack_error(nack_error)
  );

  i2c_slave_model #(.DEV_ADDR(7'h28), .HEADING_VALUE(16'h05A0)) slave (
    .scl(scl), .sda(sda)
  );

  always #500 clk = ~clk;

  integer errors = 0;
  integer waited;

  initial begin
    @(negedge clk); rst = 0;
    @(negedge clk); start = 1;
    @(posedge clk);
    @(negedge clk); start = 0;

    waited = 0;
    while (done !== 1'b1 && waited < 100000) begin
      @(posedge clk); #1;
      waited = waited + 1;
    end

    if (done !== 1'b1) begin
      $display("FAIL: transaction never completed (done timeout)");
      errors = errors + 1;
    end else begin
      $display("PASS: transaction completed (waited %0d cycles)", waited);
      if (nack_error !== 1'b0) begin
        $display("FAIL: nack_error asserted on a transaction that should have been fully ACKed");
        errors = errors + 1;
      end else $display("PASS: no NACK errors");
      if (read_data !== 16'h05A0) begin
        $display("FAIL: read_data = %h, expected 05a0", read_data);
        errors = errors + 1;
      end else $display("PASS: read_data = 05a0 as the slave was programmed to return");
    end

    // --- wrong address: slave never acks, master must report nack_error ---
    @(negedge clk); dev_addr = 7'h55; // no slave at this address
    @(negedge clk); start = 1;
    @(posedge clk);
    @(negedge clk); start = 0;
    waited = 0;
    while (done !== 1'b1 && waited < 100000) begin
      @(posedge clk); #1;
      waited = waited + 1;
    end
    if (done !== 1'b1) begin
      $display("FAIL: wrong-address transaction never completed");
      errors = errors + 1;
    end else if (nack_error !== 1'b1) begin
      $display("FAIL: no nack_error reported when addressing a nonexistent device");
      errors = errors + 1;
    end else begin
      $display("PASS: addressing a nonexistent device correctly reports nack_error");
    end

    if (errors == 0) $display("ALL I2C_MASTER TESTS PASSED");
    else $display("%0d I2C_MASTER TEST(S) FAILED", errors);
    $finish;
  end
endmodule

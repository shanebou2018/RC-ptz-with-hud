// Bare-bones behavioral SPI compass stand-in for testing
// spi_compass_driver.v without real hardware: receives an address byte
// (not validated), then returns LSB_VALUE and MSB_VALUE on the next two
// byte transfers. Sim-only, not synthesizable, and not a claim about the
// real chosen compass part's actual protocol -- see
// spi_compass_driver.v's header comment.
module spi_compass_model #(
  parameter [7:0] LSB_VALUE = 8'hA0,
  parameter [7:0] MSB_VALUE = 8'h05
)(
  input  wire sclk,
  input  wire mosi,
  input  wire cs,
  output reg   miso
);
  task xfer_byte(input [7:0] tx, output [7:0] rx);
    integer i;
    reg [7:0] shift;
    begin
      shift = 8'h00;
      for (i = 7; i >= 0; i = i - 1) begin
        miso = tx[i];
        @(posedge sclk);
        shift = {shift[6:0], mosi};
        @(negedge sclk);
      end
      rx = shift;
    end
  endtask

  reg [7:0] addr_byte, dummy;

  always begin
    @(negedge cs);
    xfer_byte(8'h00, addr_byte); // address byte from master -- not validated
    xfer_byte(LSB_VALUE, dummy);
    xfer_byte(MSB_VALUE, dummy);
    @(posedge cs);
  end
endmodule

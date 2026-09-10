// Bare-bones behavioral MCP3008 stand-in for testing mcp3008_adc.v
// without real hardware. Matches the driver's own documented 3-byte
// transaction convention: the ADC result's high bits ride in the LAST 2
// bit-slots of byte2 (interleaved with receiving the channel-select
// bits earlier in that SAME byte -- true SPI full duplex, not two
// separate byte windows), and the low byte rides in byte3 while the
// master clocks out a dummy 0x00. Adequate for testing the DRIVER's own
// sequencing/capture logic; not a cycle-accurate model of the real
// chip's internal conversion timing. Sim-only, not synthesizable.
module mcp3008_model #(
  parameter [9:0] CH0 = 10'd100,
  parameter [9:0] CH1 = 10'd200,
  parameter [9:0] CH2 = 10'd300,
  parameter [9:0] CH3 = 10'd400,
  parameter [9:0] CH4 = 10'd500
)(
  input  wire sclk,
  input  wire mosi,
  input  wire cs,
  output reg   miso
);
  reg [9:0] values [0:7];
  initial begin
    values[0] = CH0; values[1] = CH1; values[2] = CH2; values[3] = CH3; values[4] = CH4;
    values[5] = 10'd0; values[6] = 10'd0; values[7] = 10'd0;
    miso = 1'b0;
  end

  reg b6, b5, b4;
  reg [2:0] ch;
  reg [9:0] result;
  integer i;

  always begin
    @(negedge cs);

    // byte1: start byte (0x01 expected, not validated) -- model outputs
    // nothing meaningful, driver discards this byte's rx.
    for (i = 0; i < 8; i = i + 1) begin
      @(posedge sclk);
      @(negedge sclk);
    end

    // byte2: bits 7..2 are SGL/DIFF + channel[2:0] + 2 don't-care bits
    // (received from the master); bits 1..0 are this model's response,
    // the ADC result's high 2 bits -- driven the moment the channel is
    // fully known (after bit4), in the same byte, matching the driver's
    // own capture timing exactly.
    @(posedge sclk); @(negedge sclk); // bit7 (SGL/DIFF=1) -- ignored
    @(posedge sclk); b6 = mosi; @(negedge sclk);
    @(posedge sclk); b5 = mosi; @(negedge sclk);
    @(posedge sclk); b4 = mosi; @(negedge sclk);
    ch     = {b6, b5, b4};
    result = values[ch];
    @(posedge sclk); @(negedge sclk); // bit3 (don't-care) -- ignored
    @(posedge sclk); @(negedge sclk); // bit2 (don't-care) -- ignored
    miso = result[9];
    @(posedge sclk); @(negedge sclk); // bit1 sampled by master
    miso = result[8];
    @(posedge sclk); @(negedge sclk); // bit0 sampled by master

    // byte3: pure output, result[7:0], MSB first.
    for (i = 7; i >= 0; i = i - 1) begin
      miso = result[i];
      @(posedge sclk);
      @(negedge sclk);
    end

    @(posedge cs);
  end
endmodule

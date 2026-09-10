// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, xorout
// 0x0000) -- the app-layer integrity check over the LoRa command packet
// (see packet_defs.vh). The SX127x's own radio-level CRC already catches
// most RF corruption; this one exists so a receiver with the wrong
// keystream key (see keystream.v) fails a check here too, not just
// produces garbage-looking-but-CRC-valid data.
//
// crc16_step() is a single-byte combinational update, meant to be
// `included and unrolled in a for-loop by packet_encoder.v/
// packet_decoder.v (PKT_PAYLOAD_LEN is a small constant, so a fully
// unrolled 10-byte loop is cheap and keeps the whole CRC combinational --
// no multi-cycle streaming needed for a packet this infrequent).
//
// The crc16 module below is a byte-serial wrapper around the same
// function, used only by the testbench to check against known CRC-16/
// CCITT-FALSE test vectors without re-deriving the unrolled-loop pattern.

`ifndef CRC16_V
`define CRC16_V

function automatic [15:0] crc16_step(input [15:0] crc_in, input [7:0] data);
  integer i;
  reg [15:0] crc;
  begin
    crc = crc_in ^ (data << 8);
    for (i = 0; i < 8; i = i + 1) begin
      if (crc[15])
        crc = (crc << 1) ^ 16'h1021;
      else
        crc = crc << 1;
    end
    crc16_step = crc;
  end
endfunction

module crc16 (
  input  wire       clk,
  input  wire       rst,       // synchronous, also re-seeds to init value
  input  wire        load_init, // pulse: (re)seed crc_out to 16'hFFFF
  input  wire        byte_valid, // pulse: consume data_in this cycle
  input  wire [7:0]  data_in,
  output reg  [15:0] crc_out
);
  always @(posedge clk) begin
    if (rst || load_init)
      crc_out <= 16'hFFFF;
    else if (byte_valid)
      crc_out <= crc16_step(crc_out, data_in);
  end
endmodule

`endif

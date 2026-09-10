// Lightweight XOR-keystream cipher for the LoRa command packet payload
// (packet_defs.vh bytes 2-9). NOT cryptographically hardened -- this is
// the "slightly secure" tier explicitly chosen over a full AES-128 core
// to keep LUT cost low on the iCE40 HX 7680-LUT part (see CLAUDE.md's
// fork section and the plan's open question 9). It deters casual sniffing
// and, combined with the packet sequence number, makes naive replay of a
// captured packet fail once the sequence number has moved on. A
// determined attacker who captures enough traffic could still attack this
// LFSR-based stream cipher -- if that threat model matters, swap this
// module for a real AES-128 core; the encoder/decoder call sites
// (packet_encoder.v/packet_decoder.v) only depend on this file's function
// signatures, not its internals.
//
// KEYSTREAM_SEED below is a placeholder/test value -- DO NOT ship it as a
// real secret. Set a real per-vehicle-pair seed before flashing production
// bitstreams; see fpga/README.md for how.
//
// Design: a 32-bit Galois LFSR, re-seeded per packet from
// (KEYSTREAM_SEED XOR sequence_number) so consecutive packets don't reuse
// the same keystream (a classic XOR-cipher weakness) even though the
// sequence number itself travels in the clear (packet_defs.vh byte 1).
// Both ends compute the identical keystream independently -- the base
// station knows the seq number it just chose, the vehicle reads it off
// the (still-plaintext) packet header before decrypting the payload.

`ifndef KEYSTREAM_V
`define KEYSTREAM_V

// Placeholder only -- override per fpga/README.md before real use.
`define KEYSTREAM_SEED 32'hC0FFEE42

function automatic [31:0] lfsr_next(input [31:0] state);
  reg feedback;
  begin
    feedback = state[31];
    lfsr_next = {state[30:0], 1'b0};
    if (feedback)
      lfsr_next = lfsr_next ^ 32'h04C11DB7;
    if (lfsr_next == 32'h0)
      lfsr_next = 32'h1; // avoid the all-zero lock-up state
  end
endfunction

function automatic [31:0] keystream_init(input [31:0] seed, input [7:0] seq);
  reg [31:0] s;
  begin
    s = seed ^ {24'h0, seq};
    if (s == 32'h0) s = 32'h1;
    keystream_init = s;
  end
endfunction

// Returns the keystream byte at payload index i (0-7, corresponding to
// packet_defs.vh's PKT_IDX_PAN..PKT_IDX_RESERVED) for the given
// seed/sequence number. Callers (packet_encoder.v/packet_decoder.v) call
// this once per payload byte in an unrolled loop -- PKT_PAYLOAD_LEN-2 (8)
// iterations is cheap enough to stay fully combinational at LoRa's packet
// rate.
function automatic [7:0] keystream_byte(input [31:0] seed, input [7:0] seq, input integer idx);
  reg [31:0] state;
  integer j;
  begin
    state = keystream_init(seed, seq);
    for (j = 0; j < idx; j = j + 1)
      state = lfsr_next(state);
    keystream_byte = state[7:0];
  end
endfunction

// Testbench-friendly wrapper: exposes all 8 keystream bytes at once
// (ks_bytes[8*i +: 8] = byte i) so tb_keystream.v doesn't have to
// re-derive the unrolled-loop pattern encoder/decoder actually use.
module keystream_gen (
  input  wire [31:0] seed,
  input  wire [7:0]  seq,
  output wire [63:0] ks_bytes
);
  // Deliberately generate+assign rather than always @* + reg: a
  // procedural always block's sensitivity list can race a module-level
  // "reg = value" static initializer in some simulators (seen in
  // practice with Icarus during development of this module -- the
  // always block evaluated once before the initializer ran and never
  // retriggered, leaving the output stuck at X). Per-bit continuous
  // assigns don't have that race.
  genvar gi;
  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : ks_byte_gen
      assign ks_bytes[8*gi +: 8] = keystream_byte(seed, seq, gi);
    end
  endgenerate
endmodule

`endif

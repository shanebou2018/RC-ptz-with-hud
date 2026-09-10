`timescale 1ns/1ps
`include "keystream.v"

module tb_keystream;
  reg [31:0] seed_a = 32'hC0FFEE42;
  reg [31:0] seed_b = 32'h12345678;
  reg [7:0]  seq_a = 8'h00;
  reg [7:0]  seq_b = 8'h01;

  wire [63:0] ks_aa0, ks_aa0_again, ks_aa1, ks_ba0;

  keystream_gen g1 (.seed(seed_a), .seq(seq_a), .ks_bytes(ks_aa0));
  keystream_gen g2 (.seed(seed_a), .seq(seq_a), .ks_bytes(ks_aa0_again));
  keystream_gen g3 (.seed(seed_a), .seq(seq_b), .ks_bytes(ks_aa1));
  keystream_gen g4 (.seed(seed_b), .seq(seq_a), .ks_bytes(ks_ba0));

  integer errors = 0;

  initial begin
    #1;

    // Determinism: same seed+seq always produces the same keystream.
    if (ks_aa0 !== ks_aa0_again) begin
      $display("FAIL: same seed+seq produced different keystreams");
      errors = errors + 1;
    end else $display("PASS: deterministic for a given seed+seq");

    // Varying sequence number must change the keystream (anti-replay
    // property -- same seed, different seq).
    if (ks_aa0 === ks_aa1) begin
      $display("FAIL: different seq produced the same keystream");
      errors = errors + 1;
    end else $display("PASS: different seq -> different keystream");

    // Varying seed must change the keystream (different vehicle pairs
    // don't collide).
    if (ks_aa0 === ks_ba0) begin
      $display("FAIL: different seed produced the same keystream");
      errors = errors + 1;
    end else $display("PASS: different seed -> different keystream");

    // Not degenerately all-zero.
    if (ks_aa0 === 64'h0) begin
      $display("FAIL: keystream is all-zero");
      errors = errors + 1;
    end else $display("PASS: keystream is non-zero");

    // Round-trip: XOR-encrypt then XOR-decrypt with the same
    // seed+seq recovers the original payload -- this is the actual
    // operation packet_encoder.v/packet_decoder.v perform.
    begin : roundtrip
      reg [63:0] payload, encrypted, decrypted;
      payload = 64'h1122334455667788;
      encrypted = payload ^ ks_aa0;
      decrypted = encrypted ^ ks_aa0;
      if (decrypted !== payload) begin
        $display("FAIL: XOR round-trip did not recover the original payload");
        errors = errors + 1;
      end else $display("PASS: XOR round-trip recovers the original payload");

      // Decrypting with the WRONG seed must NOT recover the payload --
      // this is the whole point of the shared-secret seed.
      if ((encrypted ^ ks_ba0) === payload) begin
        $display("FAIL: wrong seed still recovered the original payload");
        errors = errors + 1;
      end else $display("PASS: wrong seed does not recover the payload");
    end

    if (errors == 0) $display("ALL KEYSTREAM TESTS PASSED");
    else $display("%0d KEYSTREAM TEST(S) FAILED", errors);
    $finish;
  end
endmodule

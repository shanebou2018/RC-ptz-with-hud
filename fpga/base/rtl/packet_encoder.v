// Builds the 12-byte LoRa command packet (packet_defs.vh) from the base
// station's current operator-input registers, on each `send` pulse.
// Sync byte and sequence number travel in the clear; the 8 payload bytes
// (pan/tilt/focus/zoom/flags/motorL/motorR/reserved) are XOR-encrypted
// with keystream.v before the CRC is computed -- see keystream.v's header
// comment for why this is a lightweight, not cryptographically hardened,
// scheme.
//
// One send pulse = one packet, using whatever seq the internal counter is
// currently at, then advancing it (wraps 0-255 naturally on the 8-bit
// register) for the next packet. This module has no notion of transmit
// timing/rate -- that's the caller's job (top_base.v ticks `send`
// periodically); see fpga/README.md for the rate/deadman-timeout
// discussion.
`include "packet_defs.vh"
`include "crc16.v"
`include "keystream.v"

module packet_encoder (
  input  wire        clk,
  input  wire        rst,
  input  wire [31:0] seed,          // shared secret, matches the vehicle's packet_decoder
  input  wire        send,          // pulse: build + emit a new packet, advance seq
  input  wire [7:0]  pan,
  input  wire [7:0]  tilt,
  input  wire [7:0]  focus,
  input  wire [7:0]  zoom,
  input  wire        fire,          // set for exactly the one packet meant to trigger a fire pulse -- see decoder's header comment
  input  wire        load,
  input  wire        motor_l_dir,
  input  wire        motor_r_dir,
  input  wire [7:0]  motor_l_pwm,
  input  wire [7:0]  motor_r_pwm,
  output reg  [8*`PKT_LEN-1:0] pkt_data,   // byte i at pkt_data[8*i +: 8]
  output reg          pkt_valid,           // one-cycle pulse: pkt_data is ready for the SX127x driver to transmit
  output reg  [7:0]   seq_out              // sequence number used for the just-built packet (debug/testbench)
);
  reg [7:0] seq;
  integer i;
  reg [7:0] plain [0:`PKT_PAYLOAD_LEN-3];  // 8 payload bytes (indices 0-7 map to PKT_IDX_PAN..PKT_IDX_RESERVED)
  reg [7:0] enc   [0:`PKT_PAYLOAD_LEN-3];
  reg [15:0] crc;
  reg [7:0] motor_l_pwm_clamped, motor_r_pwm_clamped;

  always @(posedge clk) begin
    if (rst) begin
      seq       <= 8'h00;
      pkt_valid <= 1'b0;
      pkt_data  <= {8*`PKT_LEN{1'b0}};
      seq_out   <= 8'h00;
    end else if (send) begin
      // Hard-clamp motor PWM here too (same MAX_MOTOR_PWM ceiling the
      // vehicle FPGA also enforces authoritatively) -- belt-and-braces,
      // the vehicle's own clamp in motor_pwm.v is the one that actually
      // matters for safety.
      motor_l_pwm_clamped = (motor_l_pwm > `MAX_MOTOR_PWM) ? `MAX_MOTOR_PWM : motor_l_pwm;
      motor_r_pwm_clamped = (motor_r_pwm > `MAX_MOTOR_PWM) ? `MAX_MOTOR_PWM : motor_r_pwm;

      plain[0] = pan;
      plain[1] = tilt;
      plain[2] = focus;
      plain[3] = zoom;
      plain[4] = {4'b0, motor_r_dir, motor_l_dir, load, fire};
      plain[5] = motor_l_pwm_clamped;
      plain[6] = motor_r_pwm_clamped;
      plain[7] = 8'h00; // reserved

      for (i = 0; i <= `PKT_PAYLOAD_LEN - 3; i = i + 1)
        enc[i] = plain[i] ^ keystream_byte(seed, seq, i);

      // CRC covers the packet AS TRANSMITTED (sync + seq in clear, then
      // the already-encrypted payload) -- the decoder must recompute it
      // the same way, before decrypting.
      crc = 16'hFFFF;
      crc = crc16_step(crc, `PKT_SYNC);
      crc = crc16_step(crc, seq);
      for (i = 0; i <= `PKT_PAYLOAD_LEN - 3; i = i + 1)
        crc = crc16_step(crc, enc[i]);

      pkt_data[8*`PKT_IDX_SYNC     +: 8] <= `PKT_SYNC;
      pkt_data[8*`PKT_IDX_SEQ      +: 8] <= seq;
      pkt_data[8*`PKT_IDX_PAN      +: 8] <= enc[0];
      pkt_data[8*`PKT_IDX_TILT     +: 8] <= enc[1];
      pkt_data[8*`PKT_IDX_FOCUS    +: 8] <= enc[2];
      pkt_data[8*`PKT_IDX_ZOOM     +: 8] <= enc[3];
      pkt_data[8*`PKT_IDX_FLAGS    +: 8] <= enc[4];
      pkt_data[8*`PKT_IDX_MOTOR_L  +: 8] <= enc[5];
      pkt_data[8*`PKT_IDX_MOTOR_R  +: 8] <= enc[6];
      pkt_data[8*`PKT_IDX_RESERVED +: 8] <= enc[7];
      pkt_data[8*`PKT_IDX_CRC_HI   +: 8] <= crc[15:8];
      pkt_data[8*`PKT_IDX_CRC_LO   +: 8] <= crc[7:0];

      pkt_valid <= 1'b1;
      seq_out   <= seq;
      seq       <= seq + 8'h1;
    end else begin
      pkt_valid <= 1'b0;
    end
  end
endmodule

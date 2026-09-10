// Validates and decodes a received 12-byte LoRa command packet
// (packet_defs.vh) on the vehicle FPGA. Checks, in order: sync byte,
// CRC16 (recomputed over the packet AS RECEIVED -- i.e. still encrypted,
// matching how packet_encoder.v computed it, so a wrong keystream key
// fails the CRC too, not just decrypts to garbage), then sequence
// freshness (reject an exact repeat of the last accepted sequence number
// -- deliberately not a full monotonic-newer-than check with wraparound
// handling; LoRa's low packet rate makes true reordering unlikely to
// matter, per the project's design notes).
//
// Only on an accepted packet are the command outputs updated -- an
// invalid/duplicate packet leaves pan/tilt/focus/zoom/motor outputs at
// their previous values (this module never zeroes anything itself;
// deadman_timer.v is what forces a safe state on link loss).
//
// fire_pulse/load_pulse fire for exactly one cycle per accepted packet
// that has that flag bit set. This assumes the base station's
// operator_input_capture.v/packet_encoder.v only ever sets that bit for
// the single packet meant to trigger the pulse (an edge-triggered
// button press at the base, not a held-down level) -- fire_load_pulse.v
// downstream also independently ignores a retrigger while a pulse is
// already in flight, so a base-station bug that sets the bit for more
// than one packet in a row degrades to "ignored", not "fires twice".
`include "packet_defs.vh"
`include "crc16.v"
`include "keystream.v"

module packet_decoder (
  input  wire         clk,
  input  wire         rst,
  input  wire [31:0]  seed,          // shared secret, matches the base station's packet_encoder
  input  wire         rx_valid,      // pulse: pkt_data_in holds a freshly-received 12-byte packet
  input  wire [8*`PKT_LEN-1:0] pkt_data_in,

  output reg  [7:0]   pan,
  output reg  [7:0]   tilt,
  output reg  [7:0]   focus,
  output reg  [7:0]   zoom,
  output reg           fire_pulse,
  output reg           load_pulse,
  output reg           motor_l_dir,
  output reg           motor_r_dir,
  output reg  [7:0]   motor_l_pwm,
  output reg  [7:0]   motor_r_pwm,

  output reg           cmd_valid,     // one-cycle pulse on ANY accepted packet -- feeds deadman_timer.v
  output reg  [7:0]   last_seq
);
  integer i;
  reg seen_first;
  reg [7:0] rx_sync, rx_seq, rx_crc_hi, rx_crc_lo;
  reg [7:0] rx_enc [0:`PKT_PAYLOAD_LEN-3];
  reg [7:0] dec    [0:`PKT_PAYLOAD_LEN-3];
  reg [15:0] crc_calc;
  reg sync_ok, crc_ok, fresh_ok, accept;

  always @(posedge clk) begin
    if (rst) begin
      seen_first  <= 1'b0;
      last_seq    <= 8'h00;
      cmd_valid   <= 1'b0;
      fire_pulse  <= 1'b0;
      load_pulse  <= 1'b0;
      pan <= 8'd90; tilt <= 8'd90; focus <= 8'd0; zoom <= 8'd0;
      motor_l_dir <= 1'b1; motor_r_dir <= 1'b1;
      motor_l_pwm <= 8'd0; motor_r_pwm <= 8'd0;
    end else if (rx_valid) begin
      rx_sync   = pkt_data_in[8*`PKT_IDX_SYNC     +: 8];
      rx_seq    = pkt_data_in[8*`PKT_IDX_SEQ      +: 8];
      rx_enc[0] = pkt_data_in[8*`PKT_IDX_PAN       +: 8];
      rx_enc[1] = pkt_data_in[8*`PKT_IDX_TILT      +: 8];
      rx_enc[2] = pkt_data_in[8*`PKT_IDX_FOCUS     +: 8];
      rx_enc[3] = pkt_data_in[8*`PKT_IDX_ZOOM      +: 8];
      rx_enc[4] = pkt_data_in[8*`PKT_IDX_FLAGS     +: 8];
      rx_enc[5] = pkt_data_in[8*`PKT_IDX_MOTOR_L   +: 8];
      rx_enc[6] = pkt_data_in[8*`PKT_IDX_MOTOR_R   +: 8];
      rx_enc[7] = pkt_data_in[8*`PKT_IDX_RESERVED  +: 8];
      rx_crc_hi = pkt_data_in[8*`PKT_IDX_CRC_HI    +: 8];
      rx_crc_lo = pkt_data_in[8*`PKT_IDX_CRC_LO    +: 8];

      sync_ok = (rx_sync == `PKT_SYNC);

      crc_calc = 16'hFFFF;
      crc_calc = crc16_step(crc_calc, rx_sync);
      crc_calc = crc16_step(crc_calc, rx_seq);
      for (i = 0; i <= `PKT_PAYLOAD_LEN - 3; i = i + 1)
        crc_calc = crc16_step(crc_calc, rx_enc[i]);
      crc_ok = (crc_calc == {rx_crc_hi, rx_crc_lo});

      fresh_ok = (!seen_first) || (rx_seq != last_seq);

      accept = sync_ok && crc_ok && fresh_ok;

      if (accept) begin
        for (i = 0; i <= `PKT_PAYLOAD_LEN - 3; i = i + 1)
          dec[i] = rx_enc[i] ^ keystream_byte(seed, rx_seq, i);

        pan   <= dec[0];
        tilt  <= dec[1];
        focus <= dec[2];
        zoom  <= dec[3];
        fire_pulse  <= dec[4][`FLAG_FIRE];
        load_pulse  <= dec[4][`FLAG_LOAD];
        motor_l_dir <= dec[4][`FLAG_MOTOR_L_DIR];
        motor_r_dir <= dec[4][`FLAG_MOTOR_R_DIR];
        motor_l_pwm <= (dec[5] > `MAX_MOTOR_PWM) ? `MAX_MOTOR_PWM : dec[5];
        motor_r_pwm <= (dec[6] > `MAX_MOTOR_PWM) ? `MAX_MOTOR_PWM : dec[6];

        last_seq   <= rx_seq;
        seen_first <= 1'b1;
        cmd_valid  <= 1'b1;
      end else begin
        cmd_valid  <= 1'b0;
        fire_pulse <= 1'b0;
        load_pulse <= 1'b0;
      end
    end else begin
      cmd_valid  <= 1'b0;
      fire_pulse <= 1'b0;
      load_pulse <= 1'b0;
    end
  end
endmodule

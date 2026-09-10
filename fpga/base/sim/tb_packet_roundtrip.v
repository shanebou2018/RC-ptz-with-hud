`timescale 1ns/1ps
`include "packet_defs.vh"
`include "packet_encoder.v"
`include "packet_decoder.v"

// End-to-end encode -> "transmit" (wired directly, no radio in this sim)
// -> decode round trip, plus the failure-mode checks that matter for
// safety: corrupted packet rejected, exact-duplicate packet rejected,
// wrong-key packet still accepted structurally but decodes to garbage
// (see packet_defs.vh's security note -- this is a documented property,
// not a bug, but worth pinning down in a test so a future change doesn't
// silently alter it).
module tb_packet_roundtrip;
  reg clk = 0;
  reg rst = 1;
  reg [31:0] seed = 32'hC0FFEE42;
  reg [31:0] wrong_seed = 32'hDEADBEEF;

  reg send = 0;
  reg [7:0] pan = 8'd45, tilt = 8'd135, focus = 8'd10, zoom = 8'd20;
  reg fire = 0, load = 0;
  reg motor_l_dir = 1, motor_r_dir = 0;
  reg [7:0] motor_l_pwm = 8'd120, motor_r_pwm = 8'd90;

  wire [8*`PKT_LEN-1:0] pkt_data;
  wire pkt_valid;
  wire [7:0] seq_out;

  packet_encoder enc (
    .clk(clk), .rst(rst), .seed(seed), .send(send),
    .pan(pan), .tilt(tilt), .focus(focus), .zoom(zoom),
    .fire(fire), .load(load),
    .motor_l_dir(motor_l_dir), .motor_r_dir(motor_r_dir),
    .motor_l_pwm(motor_l_pwm), .motor_r_pwm(motor_r_pwm),
    .pkt_data(pkt_data), .pkt_valid(pkt_valid), .seq_out(seq_out)
  );

  reg rx_valid_good = 0;
  reg [8*`PKT_LEN-1:0] rx_data_good;
  reg rst_dec = 1;

  wire [7:0] d_pan, d_tilt, d_focus, d_zoom;
  wire d_fire_pulse, d_load_pulse, d_motor_l_dir, d_motor_r_dir;
  wire [7:0] d_motor_l_pwm, d_motor_r_pwm;
  wire d_cmd_valid;
  wire [7:0] d_last_seq;

  packet_decoder dec (
    .clk(clk), .rst(rst_dec), .seed(seed),
    .rx_valid(rx_valid_good), .pkt_data_in(rx_data_good),
    .pan(d_pan), .tilt(d_tilt), .focus(d_focus), .zoom(d_zoom),
    .fire_pulse(d_fire_pulse), .load_pulse(d_load_pulse),
    .motor_l_dir(d_motor_l_dir), .motor_r_dir(d_motor_r_dir),
    .motor_l_pwm(d_motor_l_pwm), .motor_r_pwm(d_motor_r_pwm),
    .cmd_valid(d_cmd_valid), .last_seq(d_last_seq)
  );

  // A second decoder instance, seeded wrong, fed the SAME packets --
  // used only for the "wrong key still accepted, garbage payload" check.
  reg rx_valid_wrongkey = 0;
  reg [8*`PKT_LEN-1:0] rx_data_wrongkey;
  reg rst_wk = 1;
  wire [7:0] wk_pan;
  wire wk_cmd_valid;
  packet_decoder dec_wrongkey (
    .clk(clk), .rst(rst_wk), .seed(wrong_seed),
    .rx_valid(rx_valid_wrongkey), .pkt_data_in(rx_data_wrongkey),
    .pan(wk_pan), .tilt(), .focus(), .zoom(),
    .fire_pulse(), .load_pulse(), .motor_l_dir(), .motor_r_dir(),
    .motor_l_pwm(), .motor_r_pwm(),
    .cmd_valid(wk_cmd_valid), .last_seq()
  );

  always #5 clk = ~clk;

  integer errors = 0;

  // cmd_valid/fire_pulse/load_pulse are one-cycle pulses, registered on
  // the same edge that processes rx_valid=1 -- by the time a task like
  // feed_decoder_good() below finishes (which deasserts rx_valid and
  // waits another edge, to return the bus to idle), the pulse has
  // already been cleared by that next "else" edge. So capture the pulse
  // outputs right after the processing edge, into these regs, and check
  // THOSE afterward rather than re-reading the DUT's outputs once the
  // task has returned.
  reg captured_cmd_valid, captured_fire_pulse, captured_load_pulse;

  task do_send;
    begin
      @(negedge clk); send = 1;
      @(posedge clk);
      @(negedge clk); send = 0;
      @(posedge clk); // pkt_valid/pkt_data now stable (registered on the send edge)
    end
  endtask

  task feed_decoder_good;
    begin
      @(negedge clk);
      rx_data_good = pkt_data;
      rx_valid_good = 1;
      @(posedge clk);
      #1;
      captured_cmd_valid  = d_cmd_valid;
      captured_fire_pulse = d_fire_pulse;
      captured_load_pulse = d_load_pulse;
      @(negedge clk); rx_valid_good = 0;
      @(posedge clk);
    end
  endtask

  initial begin
    @(negedge clk); rst = 0; rst_dec = 0; rst_wk = 0;

    // --- 1. basic round trip ---
    do_send();
    feed_decoder_good();
    #1;
    if (d_pan !== pan || d_tilt !== tilt || d_focus !== focus || d_zoom !== zoom) begin
      $display("FAIL: servo positions did not round-trip (got pan=%0d tilt=%0d focus=%0d zoom=%0d)",
                d_pan, d_tilt, d_focus, d_zoom);
      errors = errors + 1;
    end else $display("PASS: servo positions round-trip correctly");

    if (d_motor_l_pwm !== motor_l_pwm || d_motor_r_pwm !== motor_r_pwm ||
        d_motor_l_dir !== motor_l_dir || d_motor_r_dir !== motor_r_dir) begin
      $display("FAIL: motor state did not round-trip");
      errors = errors + 1;
    end else $display("PASS: motor dir/pwm round-trip correctly");

    if (captured_cmd_valid !== 1'b1) begin
      $display("FAIL: cmd_valid did not pulse on a good packet");
      errors = errors + 1;
    end else $display("PASS: cmd_valid pulsed on a good packet");

    if (captured_fire_pulse !== 1'b0 || captured_load_pulse !== 1'b0) begin
      $display("FAIL: fire/load pulsed when not requested");
      errors = errors + 1;
    end else $display("PASS: fire/load stayed low when not requested");

    // --- 2. fire trigger bit propagates as a pulse ---
    fire = 1;
    do_send();
    fire = 0;
    feed_decoder_good();
    if (captured_fire_pulse !== 1'b1) begin
      $display("FAIL: fire_pulse did not fire when the fire flag was set");
      errors = errors + 1;
    end else $display("PASS: fire_pulse fires when the fire flag was set");

    // --- 3. exact-duplicate packet rejected (replay defense) ---
    begin : dup_check
      reg [7:0] prev_pan;
      prev_pan = d_pan;
      pan = 8'd7; // change the input but re-inject the SAME already-sent packet, not a new one
      feed_decoder_good(); // rx_data_good still holds the previous pkt_data (no new send() happened)
      if (captured_cmd_valid !== 1'b0) begin
        $display("FAIL: an exact-duplicate packet (same seq) was accepted");
        errors = errors + 1;
      end else $display("PASS: an exact-duplicate packet (same seq) was rejected");
      if (d_pan !== prev_pan) begin
        $display("FAIL: decoder outputs changed on a rejected duplicate packet");
        errors = errors + 1;
      end else $display("PASS: decoder outputs held steady on a rejected duplicate packet");
    end

    // --- 4. corrupted packet (bit flip) rejected ---
    begin : corrupt_check
      reg [7:0] prev_pan;
      pan = 8'd99;
      do_send(); // fresh seq this time
      prev_pan = d_pan; // decoder's value from before this corrupted packet
      @(negedge clk);
      rx_data_good = pkt_data ^ (1 << (8*`PKT_IDX_PAN)); // flip one payload bit
      rx_valid_good = 1;
      @(posedge clk);
      #1;
      captured_cmd_valid = d_cmd_valid;
      @(negedge clk); rx_valid_good = 0;
      @(posedge clk);
      if (captured_cmd_valid !== 1'b0) begin
        $display("FAIL: a corrupted packet (bad CRC) was accepted");
        errors = errors + 1;
      end else $display("PASS: a corrupted packet (bad CRC) was rejected");
      if (d_pan === 8'd99) begin
        $display("FAIL: corrupted packet's garbage value leaked into decoder outputs");
        errors = errors + 1;
      end else $display("PASS: corrupted packet did not affect decoder outputs");
    end

    // --- 5. wrong key: structurally accepted, payload is garbage ---
    begin : wrongkey_check
      pan = 8'd150;
      do_send();
      @(negedge clk);
      rx_data_wrongkey = pkt_data;
      rx_valid_wrongkey = 1;
      @(posedge clk);
      #1;
      captured_cmd_valid = wk_cmd_valid;
      @(negedge clk); rx_valid_wrongkey = 0;
      @(posedge clk);
      if (captured_cmd_valid !== 1'b1) begin
        $display("FAIL: wrong-key decoder rejected a structurally valid packet (expected accept-but-garbage per packet_defs.vh's security note)");
        errors = errors + 1;
      end else $display("PASS: wrong-key decoder structurally accepts the packet (as documented -- CRC is unkeyed)");
      if (wk_pan === pan) begin
        $display("FAIL: wrong-key decoder somehow decoded the correct pan value");
        errors = errors + 1;
      end else $display("PASS: wrong-key decoder produces a garbage (wrong) pan value: got %0d, sent %0d", wk_pan, pan);
    end

    if (errors == 0) $display("ALL PACKET ROUNDTRIP TESTS PASSED");
    else $display("%0d PACKET ROUNDTRIP TEST(S) FAILED", errors);
    $finish;
  end
endmodule

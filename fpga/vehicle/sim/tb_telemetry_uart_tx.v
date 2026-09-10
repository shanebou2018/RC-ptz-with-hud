`timescale 1ns/1ps
`include "telemetry_uart_tx.v"

// Scaled-down clock/baud/interval for a fast simulation. Receives the
// telemetry frame with a plain uart_engine instance acting as a "Pi",
// and independently recomputes the CRC to confirm the frame is
// internally consistent -- not just eyeballing fixed expected bytes.
module tb_telemetry_uart_tx;
  localparam CLK_FREQ_HZ = 1_000_000;
  localparam UART_BAUD = 100_000;
  localparam TELEMETRY_INTERVAL_MS = 1; // -> 1000 clk ticks between frames

  reg clk = 0;
  reg rst = 1;
  always #500 clk = ~clk;

  reg [15:0] heading_x10 = 16'd1234;
  reg [7:0] pan = 8'd90, tilt = 8'd45, focus = 8'd10, zoom = 8'd20, fire_pos = 8'd0, load_pos = 8'd0;
  reg motor_l_dir = 1'b1, motor_r_dir = 1'b0;
  reg [7:0] motor_l_pwm = 8'd150, motor_r_pwm = 8'd80;
  wire uart_tx_line;

  telemetry_uart_tx #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .UART_BAUD(UART_BAUD),
    .TELEMETRY_INTERVAL_MS(TELEMETRY_INTERVAL_MS)
  ) dut (
    .clk(clk), .rst(rst),
    .heading_x10(heading_x10), .pan(pan), .tilt(tilt), .focus(focus), .zoom(zoom),
    .fire_pos(fire_pos), .load_pos(load_pos),
    .motor_l_dir(motor_l_dir), .motor_r_dir(motor_r_dir),
    .motor_l_pwm(motor_l_pwm), .motor_r_pwm(motor_r_pwm),
    .uart_tx(uart_tx_line)
  );

  // "Pi" receiver
  wire [7:0] rx_byte;
  wire rx_valid;
  uart_engine #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(UART_BAUD)) rx_uart (
    .clk(clk), .rst(rst),
    .tx_start(1'b0), .tx_byte(8'h00), .tx_busy(), .tx(),
    .rx(uart_tx_line), .rx_byte(rx_byte), .rx_valid(rx_valid)
  );

  reg [7:0] received [0:13];
  integer rx_count = 0;
  always @(posedge clk) begin
    if (rx_valid) begin
      received[rx_count] <= rx_byte;
      rx_count <= rx_count + 1;
    end
  end

  integer errors = 0;

  initial begin
    @(negedge clk); rst = 0;

    // wait for a full 14-byte frame to arrive
    begin : wait_frame
      integer waited;
      waited = 0;
      while (rx_count < 14 && waited < 50000) begin
        @(posedge clk); #1;
        waited = waited + 1;
      end
      if (rx_count < 14) begin
        $display("FAIL: a full 14-byte telemetry frame never arrived (got %0d bytes)", rx_count);
        errors = errors + 1;
      end else begin
        $display("PASS: a full 14-byte frame arrived");
      end
    end

    if (rx_count >= 14) begin
      if (received[0] !== 8'h5A) begin
        $display("FAIL: sync byte = %h, expected 5a", received[0]);
        errors = errors + 1;
      end else $display("PASS: sync byte correct");

      if ({received[1], received[2]} !== heading_x10) begin
        $display("FAIL: heading = %h, expected %h", {received[1], received[2]}, heading_x10);
        errors = errors + 1;
      end else $display("PASS: heading round-trips correctly");

      if (received[3] !== pan || received[4] !== tilt || received[5] !== focus || received[6] !== zoom) begin
        $display("FAIL: servo positions don't match");
        errors = errors + 1;
      end else $display("PASS: pan/tilt/focus/zoom round-trip correctly");

      if (received[9][0] !== motor_l_dir || received[9][1] !== motor_r_dir) begin
        $display("FAIL: motor direction flags don't match");
        errors = errors + 1;
      end else $display("PASS: motor direction flags round-trip correctly");

      if (received[10] !== motor_l_pwm || received[11] !== motor_r_pwm) begin
        $display("FAIL: motor pwm values don't match (L=%0d R=%0d, expected L=%0d R=%0d)",
                  received[10], received[11], motor_l_pwm, motor_r_pwm);
        errors = errors + 1;
      end else $display("PASS: both motor pwm values round-trip correctly");

      // Independently recompute the CRC over the received bytes and
      // confirm it matches what was sent -- catches a framing/field
      // mistake even if individual field checks above happened to pass.
      begin : crc_check
        reg [15:0] crc;
        integer i;
        crc = 16'hFFFF;
        for (i = 0; i <= 11; i = i + 1)
          crc = crc16_step(crc, received[i]);
        if ({received[12], received[13]} !== crc) begin
          $display("FAIL: CRC mismatch (frame says %h, recomputed %h)", {received[12], received[13]}, crc);
          errors = errors + 1;
        end else $display("PASS: CRC matches the received frame");
      end
    end

    if (errors == 0) $display("ALL TELEMETRY_UART_TX TESTS PASSED");
    else $display("%0d TELEMETRY_UART_TX TEST(S) FAILED", errors);
    $finish;
  end
endmodule

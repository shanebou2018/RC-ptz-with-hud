// MCP3008 (8-channel, 10-bit, SPI) ADC driver, for the base station's
// potentiometers: pan, tilt, zoom, throttle, turn -- channels 0-4 (fixed
// mapping, see operator_input_capture.v). Continuously cycles through
// NUM_CHANNELS, each a standard 3-byte single-ended MCP3008 transaction:
//   TX: 0x01, (0x08 | channel) << 4, 0x00
//   RX: don't care, {6'b0, result[9:8]}, result[7:0]
// This exact 3-byte framing is the well-documented, ubiquitous MCP3008
// single-ended read sequence (unlike the compass SPI protocol in
// spi_compass_driver.v, this one is NOT a placeholder-guess -- it's the
// standard convention used across essentially every MCP3008 reference
// design).
module mcp3008_adc #(
  parameter CLK_FREQ_HZ  = 100_000_000, // see servo_pwm.v's header note (fpga/vehicle/rtl) on this being unverified
  parameter SPI_CLK_DIV  = 10,
  parameter NUM_CHANNELS = 5
)(
  input  wire clk,
  input  wire rst,

  output wire sclk,
  output wire mosi,
  input  wire miso,
  output reg  cs, // active low

  output reg [10*NUM_CHANNELS-1:0] channel_values, // channel i at bits [10*i +: 10]
  output reg                        new_data          // one-cycle pulse: a full round of all channels just completed
);
  // ---- low-level bit-banged SPI, mode 0, MSB first (same proven
  // structure as e220_driver.v's inner engine / the earlier SX127x work) ----
  reg spi_start;
  reg [7:0] spi_tx_byte;
  reg [7:0] spi_rx_byte;
  reg spi_done;
  reg spi_sclk_r, spi_mosi_r;
  assign sclk = spi_sclk_r;
  assign mosi = spi_mosi_r;

  localparam SPI_IDLE=2'd0, SPI_LOW=2'd1, SPI_HIGH=2'd2;
  reg [1:0] spi_state;
  reg [2:0] spi_bit_cnt;
  reg [31:0] spi_div_cnt;
  reg [7:0] spi_shift_out, spi_shift_in;

  always @(posedge clk) begin
    spi_done <= 1'b0;
    if (rst) begin
      spi_state <= SPI_IDLE; spi_sclk_r <= 1'b0; spi_mosi_r <= 1'b0;
    end else begin
      case (spi_state)
        SPI_IDLE: if (spi_start) begin
          spi_shift_out <= spi_tx_byte;
          spi_mosi_r    <= spi_tx_byte[7];
          spi_bit_cnt   <= 3'd0;
          spi_div_cnt   <= 0;
          spi_sclk_r    <= 1'b0;
          spi_state     <= SPI_LOW;
        end
        SPI_LOW: begin
          if (spi_div_cnt >= SPI_CLK_DIV - 1) begin
            spi_div_cnt <= 0; spi_sclk_r <= 1'b1; spi_state <= SPI_HIGH;
          end else spi_div_cnt <= spi_div_cnt + 1'b1;
        end
        SPI_HIGH: begin
          // Sample miso at the END of the high phase (not the start) --
          // this keeps the sample and the bit_cnt==7 completion check on
          // the exact same cycle for every SPI_CLK_DIV value, so
          // `{shift_in[6:0], miso}` always folds in exactly one fresh
          // bit, never zero or two. (An earlier version sampled at
          // div_cnt==0 while completion checked div_cnt==SPI_CLK_DIV-1 --
          // for SPI_CLK_DIV>1 those are different cycles, so by
          // completion time spi_shift_in already included the final bit,
          // and re-deriving it via {shift_in[6:0], miso} double-counted
          // that bit, corrupting every received byte. Found via
          // simulation against mcp3008_model.v, not guessed.)
          if (spi_div_cnt >= SPI_CLK_DIV - 1) begin
            spi_div_cnt <= 0; spi_sclk_r <= 1'b0;
            if (spi_bit_cnt == 3'd7) begin
              spi_rx_byte <= {spi_shift_in[6:0], miso};
              spi_done    <= 1'b1;
              spi_state   <= SPI_IDLE;
            end else begin
              spi_shift_in  <= {spi_shift_in[6:0], miso};
              spi_bit_cnt   <= spi_bit_cnt + 1'b1;
              spi_shift_out <= {spi_shift_out[6:0], 1'b0};
              spi_mosi_r    <= spi_shift_out[6];
              spi_state     <= SPI_LOW;
            end
          end else spi_div_cnt <= spi_div_cnt + 1'b1;
        end
        default: spi_state <= SPI_IDLE;
      endcase
    end
  end

  // ---- 3-byte MCP3008 transaction sequencer, one channel at a time,
  // looping forever ----
  localparam S_IDLE=0, S_CS=1, S_B1=2, S_B1_WAIT=3, S_B2=4, S_B2_WAIT=5,
             S_B3=6, S_B3_WAIT=7, S_DESEL=8;
  reg [3:0] state;
  reg [2:0] chan; // 0..NUM_CHANNELS-1
  reg [7:0] rx_b2, rx_b3;

  always @(posedge clk) begin
    spi_start <= 1'b0;
    new_data  <= 1'b0;
    if (rst) begin
      state <= S_IDLE;
      chan  <= 0;
      cs    <= 1'b1;
    end else begin
      case (state)
        S_IDLE: begin
          cs        <= 1'b0;
          spi_tx_byte <= 8'h01;
          spi_start <= 1'b1;
          state     <= S_B1_WAIT;
        end
        S_B1_WAIT: if (spi_done) begin
          spi_tx_byte <= {1'b1, chan, 4'b0000}; // SGL/DIFF=1, 3-bit channel, don't-care nibble
          spi_start   <= 1'b1;
          state       <= S_B2_WAIT;
        end
        S_B2_WAIT: if (spi_done) begin
          rx_b2       <= spi_rx_byte; // bits[1:0] = result[9:8]
          spi_tx_byte <= 8'h00;
          spi_start   <= 1'b1;
          state       <= S_B3_WAIT;
        end
        S_B3_WAIT: if (spi_done) begin
          rx_b3 <= spi_rx_byte; // result[7:0]
          cs    <= 1'b1;
          state <= S_DESEL;
        end
        S_DESEL: begin
          channel_values[10*chan +: 10] <= {rx_b2[1:0], rx_b3};
          if (chan == NUM_CHANNELS - 1) begin
            chan     <= 0;
            new_data <= 1'b1;
          end else begin
            chan <= chan + 3'd1;
          end
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule

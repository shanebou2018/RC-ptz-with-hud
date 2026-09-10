// SPI compass/IMU driver -- replaces i2c_master.v (per user request to
// standardize on SPI rather than mixing bus protocols: the base
// station's MCP3008 ADC is SPI, so the vehicle's compass moves to SPI
// too). Purpose-built for one fixed transaction: send a register address
// byte, then clock in 2 data bytes -- same shape as the I2C version it
// replaces, just a different bus.
//
// PROTOCOL CONVENTION IS UNCONFIRMED FOR THE REAL PART. This driver uses
// "read = address | 0x80, MSB first" -- the same convention this project
// already implemented and verified correctly for the SX127x LoRa radio
// (before that work was superseded by the E220 UART module) and one
// shared by many SPI register-based sensors. It could NOT be confirmed
// against the actual BNO055 datasheet in this session: both
// bosch-sensortec.com and the Adafruit-hosted copy of the datasheet PDF
// are blocked by this dev environment's network egress, and no secondary
// source found gave the exact SPI byte-level framing. CONFIRM THIS
// AGAINST THE REAL DATASHEET (section 5.4, "Serial Peripheral Interface")
// before trusting it on hardware -- along with everything else about the
// compass, it's still a placeholder part per CLAUDE.md.

module spi_compass_driver #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter SPI_CLK_DIV = 10,
  parameter [7:0] HEADING_REG_ADDR = 8'h1A // BNO055 EUL_Heading_LSB placeholder -- same register the I2C version used
)(
  input  wire        clk,
  input  wire        rst,

  output wire         sclk,
  output wire         mosi,
  input  wire         miso,
  output reg           cs, // active low

  input  wire        start,
  output reg  [15:0] read_data, // {MSB byte, LSB byte} -- the combined 16-bit heading register
  output reg           done      // one-cycle pulse
);
  // ---- low-level bit-banged SPI, mode 0, MSB first. Samples miso at
  // the END of the high phase (not the start) so the sample and the
  // bit_cnt==7 completion check always land on the same cycle regardless
  // of SPI_CLK_DIV -- see mcp3008_adc.v's header comment for the bug
  // this avoids (found and fixed there via simulation). ----
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

  // ---- fixed 3-byte transaction: address (read bit set), then 2 data
  // bytes (LSB register first, then MSB, matching auto-increment reads
  // starting at HEADING_REG_ADDR) ----
  localparam T_IDLE=0, T_ADDR=1, T_ADDR_WAIT=2, T_LSB=3, T_LSB_WAIT=4,
             T_MSB=5, T_MSB_WAIT=6, T_DONE=7;
  reg [2:0] tstate;

  always @(posedge clk) begin
    spi_start <= 1'b0;
    done      <= 1'b0;
    if (rst) begin
      tstate <= T_IDLE;
      cs     <= 1'b1;
    end else begin
      case (tstate)
        T_IDLE: if (start) begin
          cs          <= 1'b0;
          spi_tx_byte <= {1'b1, HEADING_REG_ADDR[6:0]}; // MSB=1 -> read, per the convention flagged above
          spi_start   <= 1'b1;
          tstate      <= T_ADDR_WAIT;
        end
        T_ADDR_WAIT: if (spi_done) begin
          spi_tx_byte <= 8'h00;
          spi_start   <= 1'b1;
          tstate      <= T_LSB_WAIT;
        end
        T_LSB_WAIT: if (spi_done) begin
          read_data[7:0] <= spi_rx_byte;
          spi_tx_byte    <= 8'h00;
          spi_start      <= 1'b1;
          tstate         <= T_MSB_WAIT;
        end
        T_MSB_WAIT: if (spi_done) begin
          read_data[15:8] <= spi_rx_byte;
          cs              <= 1'b1;
          tstate          <= T_DONE;
        end
        T_DONE: begin
          done   <= 1'b1;
          tstate <= T_IDLE;
        end
        default: tstate <= T_IDLE;
      endcase
    end
  end
endmodule

// Minimal I2C master, purpose-built for one fixed transaction: write a
// register address, repeated START, read 2 bytes (a 16-bit register) --
// exactly what's needed to poll a compass/IMU's heading register, e.g.
// the BNO055 placeholder from CLAUDE.md (EUL_Heading_LSB/MSB at
// 0x1A/0x1B, 1 degree = 16 LSB per its datasheet). Swap DEV_ADDR and the
// register address at the call site for whatever real part gets chosen
// -- this module doesn't hardcode a specific sensor's register map
// beyond "write one address byte, then read two data bytes", which
// covers most simple I2C sensor register reads.
//
// SCL is master-driven only (no clock-stretching support) -- a
// simplification acceptable for a placeholder sensor interface; revisit
// if the real chosen part needs stretching. 100kHz standard-mode I2C by
// default.
module i2c_master #(
  parameter CLK_FREQ_HZ = 100_000_000, // see servo_pwm.v's header note on this being unverified
  parameter I2C_FREQ_HZ = 100_000
)(
  input  wire       clk,
  input  wire       rst,

  output reg          scl,
  inout  wire         sda,

  input  wire        start,      // pulse: begin a write-reg-then-read-2-bytes transaction
  input  wire [6:0]  dev_addr,
  input  wire [7:0]  reg_addr,
  output reg  [15:0] read_data,  // {byte_msb, byte_lsb} as received, MSB byte read first
  output reg           done,      // one-cycle pulse: transaction complete (check nack_error)
  output reg           nack_error // latched: a byte was NACKed where an ACK was expected
);
  localparam integer QUARTER_PERIOD = CLK_FREQ_HZ / (I2C_FREQ_HZ * 4);
  localparam CNT_WIDTH = $clog2(QUARTER_PERIOD + 1);

  // True open-drain: only ever actively pull SDA LOW. "Driving high" is
  // modeled as releasing the line (tri-state) and relying on the bus's
  // external pull-up (or, in simulation, a `tri1`/`pullup` net) to bring
  // it high -- avoids simulating wire contention between master and
  // slave, and matches how real I2C hardware actually works.
  reg sda_oe;
  reg sda_out;
  assign sda = (sda_oe && !sda_out) ? 1'b0 : 1'bz;
  wire sda_in = sda;

  reg [CNT_WIDTH-1:0] qcnt;
  reg [1:0] quarter; // 0,1,2,3 within one SCL period

  localparam S_IDLE=0, S_START=1, S_ADDR_W=2, S_ADDR_W_ACK=3, S_REGADDR=4,
             S_REGADDR_ACK=5, S_RSTART=6, S_ADDR_R=7, S_ADDR_R_ACK=8,
             S_READ_MSB=9, S_READ_MSB_ACK=10, S_READ_LSB=11, S_READ_LSB_NACK=12,
             S_STOP=13, S_DONE=14;
  reg [3:0] state;
  reg [2:0] bit_idx;
  reg [7:0] shift_out;
  reg [7:0] shift_in;
  reg [7:0] dev_addr_latched;
  reg [7:0] reg_addr_latched;

  // Advances `quarter` every QUARTER_PERIOD clk cycles -- SCL/SDA edges
  // happen at quarter boundaries (standard 4-phase I2C bit-banging: SDA
  // changes at quarter 0 while SCL is low, SCL rises at quarter 1, data
  // sampled at quarter 1-2 while SCL is high, SCL falls at quarter 3).
  reg tick;
  always @(posedge clk) begin
    tick <= 1'b0;
    if (rst) begin
      qcnt <= 0;
    end else if (state != S_IDLE) begin
      if (qcnt >= QUARTER_PERIOD - 1) begin
        qcnt <= 0;
        tick <= 1'b1;
      end else qcnt <= qcnt + 1'b1;
    end else begin
      qcnt <= 0;
    end
  end

  always @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      state      <= S_IDLE;
      scl        <= 1'b1;
      sda_oe     <= 1'b0;
      sda_out    <= 1'b1;
      quarter    <= 2'd0;
      nack_error <= 1'b0;
    end else if (state == S_IDLE) begin
      scl    <= 1'b1;
      sda_oe <= 1'b0;
      if (start) begin
        dev_addr_latched <= {dev_addr, 1'b0}; // W bit = 0
        reg_addr_latched <= reg_addr;
        nack_error       <= 1'b0;
        quarter          <= 2'd0;
        state            <= S_START;
      end
    end else if (tick) begin
      quarter <= quarter + 2'd1;
      case (state)
        S_START: begin
          // SDA high->low while SCL stays high (a repeated start uses the
          // same shape -- see S_RSTART)
          case (quarter)
            2'd0: begin sda_oe <= 1'b1; sda_out <= 1'b1; scl <= 1'b1; end
            2'd1: begin sda_out <= 1'b0; end
            2'd2: begin scl <= 1'b0; end
            2'd3: begin
              shift_out <= dev_addr_latched;
              bit_idx   <= 3'd7;
              state     <= S_ADDR_W;
            end
          endcase
        end
        S_ADDR_W: begin
          case (quarter)
            2'd0: begin sda_out <= shift_out[7]; sda_oe <= 1'b1; end
            2'd1: scl <= 1'b1;
            2'd2: scl <= 1'b0;
            2'd3: begin
              if (bit_idx == 3'd0) begin
                state <= S_ADDR_W_ACK;
              end else begin
                bit_idx   <= bit_idx - 3'd1;
                shift_out <= shift_out << 1;
              end
            end
          endcase
        end
        S_ADDR_W_ACK: begin
          case (quarter)
            2'd0: sda_oe <= 1'b0; // release for slave ACK
            2'd1: scl <= 1'b1;
            2'd2: begin
              if (sda_in) nack_error <= 1'b1; // slave NACKed
              scl <= 1'b0;
            end
            2'd3: begin
              shift_out <= reg_addr_latched;
              bit_idx   <= 3'd7;
              state     <= S_REGADDR;
            end
          endcase
        end
        S_REGADDR: begin
          case (quarter)
            2'd0: begin sda_out <= shift_out[7]; sda_oe <= 1'b1; end
            2'd1: scl <= 1'b1;
            2'd2: scl <= 1'b0;
            2'd3: begin
              if (bit_idx == 3'd0) state <= S_REGADDR_ACK;
              else begin
                bit_idx   <= bit_idx - 3'd1;
                shift_out <= shift_out << 1;
              end
            end
          endcase
        end
        S_REGADDR_ACK: begin
          case (quarter)
            2'd0: sda_oe <= 1'b0;
            2'd1: scl <= 1'b1;
            2'd2: begin
              if (sda_in) nack_error <= 1'b1;
              scl <= 1'b0;
            end
            2'd3: state <= S_RSTART;
          endcase
        end
        S_RSTART: begin
          case (quarter)
            2'd0: begin sda_oe <= 1'b1; sda_out <= 1'b1; scl <= 1'b1; end
            2'd1: begin sda_out <= 1'b0; end
            2'd2: scl <= 1'b0;
            2'd3: begin
              shift_out <= {dev_addr_latched[7:1], 1'b1}; // R bit = 1
              bit_idx   <= 3'd7;
              state     <= S_ADDR_R;
            end
          endcase
        end
        S_ADDR_R: begin
          case (quarter)
            2'd0: begin sda_out <= shift_out[7]; sda_oe <= 1'b1; end
            2'd1: scl <= 1'b1;
            2'd2: scl <= 1'b0;
            2'd3: begin
              if (bit_idx == 3'd0) state <= S_ADDR_R_ACK;
              else begin
                bit_idx   <= bit_idx - 3'd1;
                shift_out <= shift_out << 1;
              end
            end
          endcase
        end
        S_ADDR_R_ACK: begin
          case (quarter)
            2'd0: sda_oe <= 1'b0;
            2'd1: scl <= 1'b1;
            2'd2: begin
              if (sda_in) nack_error <= 1'b1;
              scl <= 1'b0;
            end
            2'd3: begin
              bit_idx <= 3'd7;
              state   <= S_READ_MSB;
            end
          endcase
        end
        S_READ_MSB: begin
          case (quarter)
            2'd0: sda_oe <= 1'b0; // release for slave to drive data
            2'd1: scl <= 1'b1;
            2'd2: begin
              shift_in <= {shift_in[6:0], sda_in};
              scl      <= 1'b0;
            end
            2'd3: begin
              if (bit_idx == 3'd0) state <= S_READ_MSB_ACK;
              else bit_idx <= bit_idx - 3'd1;
            end
          endcase
        end
        S_READ_MSB_ACK: begin
          // master ACKs (drives SDA low) -- more bytes to come
          case (quarter)
            2'd0: begin sda_oe <= 1'b1; sda_out <= 1'b0; end
            2'd1: scl <= 1'b1;
            2'd2: scl <= 1'b0;
            2'd3: begin
              read_data[15:8] <= shift_in;
              bit_idx          <= 3'd7;
              state            <= S_READ_LSB;
            end
          endcase
        end
        S_READ_LSB: begin
          case (quarter)
            2'd0: sda_oe <= 1'b0;
            2'd1: scl <= 1'b1;
            2'd2: begin
              shift_in <= {shift_in[6:0], sda_in};
              scl      <= 1'b0;
            end
            2'd3: begin
              if (bit_idx == 3'd0) state <= S_READ_LSB_NACK;
              else bit_idx <= bit_idx - 3'd1;
            end
          endcase
        end
        S_READ_LSB_NACK: begin
          // master NACKs (drives SDA high) -- last byte, tells slave to stop
          case (quarter)
            2'd0: begin sda_oe <= 1'b1; sda_out <= 1'b1; end
            2'd1: scl <= 1'b1;
            2'd2: scl <= 1'b0;
            2'd3: begin
              read_data[7:0] <= shift_in;
              state           <= S_STOP;
            end
          endcase
        end
        S_STOP: begin
          case (quarter)
            2'd0: begin sda_oe <= 1'b1; sda_out <= 1'b0; scl <= 1'b0; end
            2'd1: scl <= 1'b1;
            2'd2: sda_out <= 1'b1; // SDA low->high while SCL high = STOP
            2'd3: begin sda_oe <= 1'b0; state <= S_DONE; end
          endcase
        end
        S_DONE: begin
          done  <= 1'b1;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule

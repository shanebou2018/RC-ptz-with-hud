// Minimal behavioral I2C slave for testing i2c_master.v without real
// hardware: acks its own address, accepts one register-address byte,
// then on a repeated START with R=1 sends back a fixed 16-bit value
// (HEADING_VALUE) as two bytes, honoring the master's ACK (continue) /
// NACK (stop) after each byte.
//
// Sim-only, not meant to be synthesized -- written as a straight-line
// procedural sequence (blocking waits on bus edges) rather than a
// synthesizable state machine, since that's far easier to get right for
// a bus-functional test model and doesn't need to be real hardware.
// True open-drain (only ever pulls SDA low) -- pair with a `tri1 sda;`
// net in the testbench so an undriven line reads the bus's pulled-up
// idle state.
module i2c_slave_model #(
  parameter [6:0] DEV_ADDR = 7'h28,
  parameter [15:0] HEADING_VALUE = 16'h05A0
)(
  input  wire scl,
  inout  wire sda
);
  reg sda_oe = 1'b0;
  reg sda_out = 1'b1;
  assign sda = (sda_oe && !sda_out) ? 1'b0 : 1'bz;

  task recv_byte(output [7:0] b);
    integer i;
    begin
      b = 8'h00;
      for (i = 0; i < 8; i = i + 1) begin
        @(posedge scl);
        b = {b[6:0], sda};
        @(negedge scl);
      end
    end
  endtask

  task send_ack;
    begin
      sda_oe = 1'b1; sda_out = 1'b0;
      @(posedge scl);
      @(negedge scl);
      sda_oe = 1'b0;
    end
  endtask

  // returns 1 if the master ACKed (wants another byte), 0 if it NACKed (stop)
  task wait_master_ack(output ack);
    begin
      sda_oe = 1'b0; // release for the master to drive
      @(posedge scl);
      ack = (sda === 1'b0);
      @(negedge scl);
    end
  endtask

  task send_byte(input [7:0] b);
    integer i;
    begin
      for (i = 7; i >= 0; i = i - 1) begin
        sda_oe = 1'b1; sda_out = b[i];
        @(posedge scl);
        @(negedge scl);
      end
      sda_oe = 1'b0;
    end
  endtask

  reg [7:0] addr_byte, reg_byte;
  reg ack_ok;

  always begin
    // wait for START: SDA falls while SCL is high
    @(negedge sda);
    if (scl === 1'b1) begin
      recv_byte(addr_byte);
      if (addr_byte[7:1] == DEV_ADDR) begin
        send_ack;
        if (addr_byte[0] == 1'b0) begin
          // write phase: one register-address byte, then ACK, then wait
          // for the repeated START (loop back to the top)
          recv_byte(reg_byte);
          send_ack;
        end else begin
          // read phase: send HEADING_VALUE MSB then LSB, honoring the
          // master's ACK/NACK between bytes
          send_byte(HEADING_VALUE[15:8]);
          wait_master_ack(ack_ok);
          if (ack_ok) begin
            send_byte(HEADING_VALUE[7:0]);
            wait_master_ack(ack_ok); // master NACKs the last byte -- ignored here
          end
        end
      end
      // not our address, or transaction complete: fall through, loop
      // back to waiting for the next START (a repeated START is just
      // another `negedge sda while scl high` event, same as a fresh one)
    end
  end
endmodule

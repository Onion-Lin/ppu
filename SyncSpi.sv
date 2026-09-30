// SyncSpi - 4-wire SPI slave command port for the ppu (T1).
//
// Protocol (CPOL=0, master launches on falling, slave samples on rising):
//   header byte : {rw, 3'b0, reg[3:0]}   rw=0 write, rw=1 read
//   write frame : header + 32 data bits (MSB first); on the 40th rising
//                 edge a one-cycle reg_we strobe commits {reg_idx, wdata}
//   read frame  : header + 32 clocks; the slave launches reg_rdata[31:0]
//                 MSB first starting at the falling edge after the header
// Extra clocks are ignored; cs framing resets everything.
//
// All pin signals arrive already digital from the payload; the double-flop
// synchronizers here are for metastability on the async SPI lines only.

module SyncSpi (
  input  logic        clock,
  input  logic        reset,
  // SPI slave side
  input  logic        sclk,
  input  logic        cs_n,
  input  logic        mosi,
  output logic        miso,
  // register file side
  output logic        reg_we,        // one-cycle write strobe
  output logic        status_ack,    // one-cycle pulse: R5 was read
  output logic [3:0]  reg_idx,       // header register index
  output logic [31:0] reg_wdata,
  input  logic [31:0] reg_rdata      // combinational read mux from Ppu
);

  // ----------------------------------------------------------------
  // input synchronizers + edge detect
  // ----------------------------------------------------------------
  logic [1:0] sck_d, cs_d;
  logic       mosi_d;

  always_ff @(posedge clock) begin
    if (reset) begin
      sck_d <= 2'b00;
      cs_d  <= 2'b11;
    end else begin
      sck_d <= {sck_d[0], sclk};
      cs_d  <= {cs_d[0], cs_n};
    end
    mosi_d <= mosi;
  end

  wire w_rise   = sck_d[0] & ~sck_d[1];
  wire w_fall   = ~sck_d[0] & sck_d[1];
  wire w_cs_low = ~cs_d[0];
  wire w_cs_fall = ~cs_d[0] & cs_d[1];
  wire w_cs_rise = cs_d[0] & ~cs_d[1];

  // ----------------------------------------------------------------
  // frame state
  // ----------------------------------------------------------------
  logic [5:0]  bitcnt;
  logic [7:0]  hdr;
  logic [31:0] wsh;      // write data shifter
  logic [31:0] tx;       // read data shifter

  assign reg_idx = hdr[3:0];

  always_ff @(posedge clock) begin
    if (reset) begin
      bitcnt <= '0; hdr <= '0; wsh <= '0; tx <= '0;
      miso <= 1'b0; reg_we <= 1'b0; reg_wdata <= '0;
      status_ack <= 1'b0;
    end else begin
      reg_we     <= 1'b0;
      status_ack <= 1'b0;

      if (w_cs_fall) begin
        bitcnt <= '0;
      end
      if (w_cs_rise) begin
        miso      <= 1'b0;
      end

      if (w_cs_low) begin
        // sample on the rising edge
        if (w_rise) begin
          if (bitcnt < 6'd8) begin
            hdr <= {hdr[6:0], mosi_d};      // hdr[7] = rw, complete at bit7
          end else if (bitcnt < 6'd40) begin
            wsh <= {wsh[30:0], mosi_d};
            if (bitcnt == 6'd39 && !hdr[7]) begin
              reg_we    <= 1'b1;
              reg_wdata <= {wsh[30:0], mosi_d};
            end
          end
          if (bitcnt < 6'd63) bitcnt <= bitcnt + 6'd1;
        end

        // launch read data on the falling edge
        if (w_fall && hdr[7] && bitcnt >= 6'd8) begin
          if (bitcnt == 6'd8) begin
            // first data bit: reg_idx (== hdr[3:0]) is stable by now
            miso <= reg_rdata[31];
            tx   <= {reg_rdata[30:0], 1'b0};
            if (hdr[3:0] == 4'd5) status_ack <= 1'b1;  // STATUS read acks irq
          end else begin
            miso <= tx[31];
            tx   <= {tx[30:0], 1'b0};
          end
        end
      end
    end
  end

endmodule

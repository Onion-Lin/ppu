// FbSramProbe - ECC/SRAM integration probe for the ppu design line.
//
// Purpose (plan T0): prove that the ECOS ECC rtl2gds flow can carry an
// ICS55 SRAM compiler macro end to end: synthesis keeps the blackbox
// instance, floorplan/placement consumes the macro LEF, STA consumes the
// macro Liberty, and the routed design survives DRC/LVS.
//
// Function: a tiny march-like controller writes a pattern to 64 words,
// reads them back, and exposes pass/busy. Behaviour is irrelevant - the
// instance survival is the test. This file is NOT part of the ppu frame
// design sources (it lives under rtl/probe/ on purpose).

module FbSramProbe (
  input  wire       clock,
  input  wire       reset,
  output reg        pass,
  output reg        busy
);

  reg  [12:0] addr;
  reg         ce_n;
  reg         we_n;      // GWEB
  reg  [63:0] wdata;
  reg  [63:0] chk;
  wire [63:0] rdata;
  reg  [3:0]  step;
  reg  [6:0]  idx;

  TMHDSPZ055ABA_V0L0R0_8192X64M8W0F1 u_fb (
    .A    (addr),
    .CLK  (clock),
    .CEB  (ce_n),
    .GWEB (we_n),
    .WEB  (64'h0),
    .D    (wdata),
    .Q    (rdata),
    .MARE (1'b0),
    .MAR  (4'b0)
  );

  // pattern: address-tagged data, both halves checked
  function [63:0] pat(input [12:0] a);
    pat = {16'hA5A5, 6'h2A, ~a, a, 16'h5A5A};   // 16+6+13+13+16 = 64
  endfunction

  always @(posedge clock) begin
    if (reset) begin
      addr <= 13'd0; ce_n <= 1'b1; we_n <= 1'b1;
      step <= 4'd0; idx <= 7'd0; pass <= 1'b0; busy <= 1'b0;
      chk  <= 64'd0;
    end else begin
      case (step)
        0: begin                     // start
             busy <= 1'b1; idx <= 0; addr <= 0; step <= 1;
           end
        1: begin                     // write phase: one word per cycle
             addr  <= idx[6:0] == 0 ? 13'd0 : addr + 13'd1;
             wdata <= pat(13'(idx));
             ce_n  <= 1'b0; we_n <= 1'b0;
             step  <= 2;
           end
        2: begin
             idx <= idx + 7'd1;
             if (idx == 7'd63) begin we_n <= 1'b1; step <= 3; end
             else step <= 1;
           end
        3: begin                     // settle + first read setup
             ce_n <= 1'b1; addr <= 0; idx <= 0; step <= 4;
           end
        4: begin                     // read phase
             addr <= 13'(idx); ce_n <= 1'b0; step <= 5;
           end
        5: begin                     // rdata valid now (sync read)
             if (rdata != pat(13'(idx))) pass <= 1'b0;
             chk <= rdata;
             step <= 6;
           end
        6: begin
             idx <= idx + 7'd1;
             if (idx == 7'd63) begin step <= 7; ce_n <= 1'b1; end
             else step <= 4;
           end
        7: begin                     // all matched?
             pass <= 1'b1; busy <= 1'b0; step <= 7;
           end
        default: step <= 0;
      endcase
    end
  end

endmodule

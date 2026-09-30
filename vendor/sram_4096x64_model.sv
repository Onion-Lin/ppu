// Behavioral model of the ICS55 single-port SRAM macro
// TMHDSPZ055ABA_V0L0R0_4096X64M8W0F1 (4096 x 64, bit-write mask).
//
// Interface and semantics follow the vendor package
// (ics55_ecos_sram release): CEB/GWEB/WEB active low;
//   write: ~CEB & ~GWEB, per-bit write where WEB[i]=0, Q takes D on
//          written bits (write-through, as in the vendor core model)
//   read : ~CEB &  GWEB, Q <= mem[A]
// MARE/MAR are margin/test pins, ignored here (tied by the wrapper user).
// This file is for RTL simulation only; synthesis uses the vendor
// blackbox stub (see designs/ppu/scripts/ecc_probe.sh).

module TMHDSPZ055ABA_V0L0R0_4096X64M8W0F1 (
  input  logic [11:0] A,
  input  logic        CEB,
  input  logic        CLK,
  input  logic [63:0] D,
  input  logic        GWEB,
  input  logic [3:0]  MAR,
  input  logic        MARE,
  input  logic [63:0] WEB,
  output logic [63:0] Q
);

  logic [63:0] MEMORY [0:4095];

  always_ff @(posedge CLK) begin
    if (!CEB) begin
      if (!GWEB) begin
        for (int i = 0; i < 64; i++) begin
          if (!WEB[i]) begin
            MEMORY[A][i] <= D[i];
            Q[i]         <= D[i];
          end
        end
      end else begin
        Q <= MEMORY[A];
      end
    end
  end

endmodule

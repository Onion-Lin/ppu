// FbSram - framebuffer macro wrapper.
//
// Normalized active-high interface for the ppu; the macro polarity
// (CEB/GWEB/WEB active low) is handled here. The module instantiates
// TMHDSPZ055ABA_V0L0R0_4096X64M8W0F1 by name: RTL sim gets the
// behavioral model (rtl/vendor/sram_4096x64_model.sv), synthesis gets
// the (* blackbox *) stub + Liberty/LEF via the ECC flow.

module FbSram (
  input  logic        clock,
  input  logic        ce,        // chip enable, active high
  input  logic        we,        // 1 = write, 0 = read
  input  logic [11:0] addr,
  input  logic [63:0] wdata,
  input  logic [63:0] wmask,     // 1 = write this bit
  output logic [63:0] rdata
);

  TMHDSPZ055ABA_V0L0R0_4096X64M8W0F1 u_macro (
    .CLK  (clock),
    .CEB  (~ce),
    .GWEB (~we),
    .A    (addr),
    .D    (wdata),
    .WEB  (~wmask),
    .Q    (rdata),
    .MARE (1'b0),
    .MAR  (4'b0)
  );

endmodule

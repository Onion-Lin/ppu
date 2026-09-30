// ICS55 SRAM macro blackbox view for synthesis.
// Derived from the vendor stub in the ECOS Factory SRAM package
// TMHDSPZ055ABA_V0L0R0_8192X64M8W0F1 (ics55_ecos_sram releases); only the
// (* blackbox *) attribute was added so yosys keeps the instance instead
// of flattening the empty module away. Timing/physical views come from the
// package Liberty and LEF through [pdk.overrides] in ecc.toml.

`resetall
`celldefine

(* blackbox *)
module TMHDSPZ055ABA_V0L0R0_8192X64M8W0F1 (
  input  [12:0] A,
  input         CEB,
  input         CLK,
  input  [63:0] D,
  input         GWEB,
  input  [3:0]  MAR,
  input         MARE,
  input  [63:0] WEB,
  output [63:0] Q
);
endmodule

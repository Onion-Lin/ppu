// Ppu - 256x240@4bpp indexed framebuffer PPU with VGA output (T1 skeleton).
//
// Frame design contract: clock/reset + 66-bit io_in/io_out/io_oe;
// io_*[n] <-> FrameTop.user_io[n+7].
//
// Pin map (design bit n):
//   [0] sclk in   [1] cs_n in   [2] mosi in   [3] miso out  - SPI command port
//   [4] irq out   [5] vsync out [6] hsync out [12:7] rgb out
//   [65:13] reserved, released
//
// Register map (SPI header {rw,3'b0,reg}):
//   R0  CMD   {30'b0, op[1:0]} write: 0=NOP 1=CLR 2=FILL -> cmd_strobe pulse
//   R1  X[15:0]        R2  Y[15:0]     R3  {W[8:0],H[8:0]}
//   R4  COLOR[7:0]     R5  STATUS read {30'b0, busy, irq}
//   R8  PSET (palette write-through, storage lands in T4)
//   R9  VSET video config (consumed in T4)   R10 IRQE[1:0]
//
// T1 scope: SPI port + register file + command decode. VGA outputs are
// driven quiescent (syncs/rgb low); busy/irq are tied 0 until T3/T5.

module Ppu #(
  parameter int IO_WIDTH = 66
) (
  input  logic                clock,
  input  logic                reset,
  input  logic [IO_WIDTH-1:0] io_in,
  output logic [IO_WIDTH-1:0] io_out,
  output logic [IO_WIDTH-1:0] io_oe
);

  localparam int SCLK  = 0;
  localparam int CSN   = 1;
  localparam int MOSI  = 2;
  localparam int MISO  = 3;
  localparam int IRQ   = 4;
  localparam int VSYNC = 5;
  localparam int HSYNC = 6;
  localparam int RGB   = 7;   // [12:7]

  // ----------------------------------------------------------------
  // SPI command port
  // ----------------------------------------------------------------
  logic        miso_w;
  logic        reg_we;
  logic        status_ack;
  logic [3:0]  reg_idx;
  logic [31:0] reg_wdata;
  logic [31:0] reg_rdata;

  SyncSpi u_spi (
    .clock(clock), .reset(reset),
    .sclk(io_in[SCLK]), .cs_n(io_in[CSN]),
    .mosi(io_in[MOSI]), .miso(miso_w),
    .reg_we(reg_we), .status_ack(status_ack), .reg_idx(reg_idx),
    .reg_wdata(reg_wdata), .reg_rdata(reg_rdata)
  );

  // ----------------------------------------------------------------
  // register file + command decode
  // ----------------------------------------------------------------
  logic [15:0] r_x, r_y;
  logic [17:0] r_wh;
  logic [7:0]  r_color;
  logic [31:0] r_vset;
  logic [1:0]  r_irqe;
  logic [15:0] r_pal;        // PSET payload (consumed by T4 palette)
  logic        pal_we;
  logic [1:0]  cmd_op;
  logic        cmd_strobe;

  // ----------------------------------------------------------------
  // fill engine + framebuffer arbiter (T3)
  // ----------------------------------------------------------------
  logic        eng_busy, done_pulse;
  logic        wr_req, wr_gnt;
  logic [11:0] wr_addr;
  logic [63:0] wr_data, wr_mask;

  FillEngine u_fill (
    .clock(clock), .reset(reset),
    .cmd_strobe(cmd_strobe), .cmd_op(cmd_op),
    .cmd_x(r_x[7:0]), .cmd_y(r_y[7:0]),
    .cmd_w(r_wh[17:9]), .cmd_h(r_wh[8:0]),
    .cmd_color(r_color[3:0]),
    .wr_req(wr_req), .wr_addr(wr_addr),
    .wr_data(wr_data), .wr_mask(wr_mask), .wr_gnt(wr_gnt),
    .busy(eng_busy), .done_pulse(done_pulse)
  );

  // scan read port driven by ScanPath (T4)
  logic        scan_req;
  logic [11:0] scan_addr;
  logic [63:0] scan_rdata;
  logic [5:0]  rgb_fb;
  logic        rgb_in_win, hsync_d, vsync_d, vsync_pulse;

  ScanPath u_scan (
    .clock(clock), .reset(reset),
    .sx(sx), .sy(sy), .de(de_w),
    .hsync(hsync_w), .vsync(vsync_w),
    .vset(r_vset),
    .pal_we(pal_we), .pal_slot(r_pal[3:0]), .pal_rgb(r_pal[9:4]),
    .scan_req(scan_req), .scan_addr(scan_addr), .scan_rdata(scan_rdata),
    .rgb_fb(rgb_fb), .rgb_in_win(rgb_in_win),
    .hsync_d(hsync_d), .vsync_d(vsync_d), .vsync_pulse(vsync_pulse)
  );

  // single-port arbiter: scan reads win, fill takes the rest
  wire        fb_ce = scan_req | wr_req;
  wire        fb_we = ~scan_req & wr_req;
  wire [11:0] fb_addr = scan_req ? scan_addr : wr_addr;
  assign wr_gnt = wr_req & ~scan_req;

  FbSram u_fb (
    .clock(clock), .ce(fb_ce), .we(fb_we), .addr(fb_addr),
    .wdata(wr_data), .wmask(wr_mask), .rdata(scan_rdata)
  );

  // completion flag: set by the engine, acked by a STATUS read
  logic done_flag;
  always_ff @(posedge clock) begin
    if (reset)          done_flag <= 1'b0;
    else if (done_pulse) done_flag <= 1'b1;
    else if (status_ack) done_flag <= 1'b0;
  end

  // vsync event flag + free-running frame counter (STATUS[31:16])
  logic vsync_flag;
  logic [15:0] frame_ctr;
  always_ff @(posedge clock) begin
    if (reset) begin
      vsync_flag <= 1'b0;
      frame_ctr  <= '0;
    end else begin
      if (vsync_pulse) begin
        vsync_flag <= 1'b1;
        frame_ctr  <= frame_ctr + 16'd1;
      end
      if (status_ack) vsync_flag <= 1'b0;
    end
  end

  wire busy = eng_busy;
  wire irq  = (r_irqe[0] & done_flag) | (r_irqe[1] & vsync_flag);

  // ----------------------------------------------------------------
  // VGA timing generator (Project F simple_480p, MIT - see rtl/vendor)
  // ----------------------------------------------------------------
  logic [9:0] sx, sy;
  logic hsync_w, vsync_w, de_w;

  simple_480p u_vga (
    .clk_pix(clock),
    .rst_pix(reset),
    .sx(sx), .sy(sy),
    .hsync(hsync_w), .vsync(vsync_w), .de(de_w)
  );

  // T2 test pattern (vset[31]): top half = 8 white/gray bars,
  // bottom half = 8px checkerboard; black outside de
  wire testpat = r_vset[31];
  logic [3:0] de_d4;
  logic [9:0] sx_d0, sx_d1, sx_d2, sx_d3;
  logic [9:0] sy_d0, sy_d1, sy_d2, sy_d3;
  always_ff @(posedge clock) begin
    if (reset) de_d4 <= 4'b0;
    else       de_d4 <= {de_d4[2:0], de_w};
    {sx_d3, sx_d2, sx_d1, sx_d0} <= {sx_d2, sx_d1, sx_d0, sx};
    {sy_d3, sy_d2, sy_d1, sy_d0} <= {sy_d2, sy_d1, sy_d0, sy};
  end
  wire de_w_d4 = de_d4[3];
  wire [5:0] pat_bars = {{2{sx_d3[8]}}, {2{sx_d3[7]}}, {2{sx_d3[6]}}};
  wire [5:0] pat_chck = {6{sx_d3[3] ^ sy_d3[3]}};
  wire [5:0] pat_rgb  = sy_d3[8] ? pat_chck : pat_bars;

  always_ff @(posedge clock) begin
    if (reset) begin
      r_x <= '0; r_y <= '0; r_wh <= '0; r_color <= '0;
      r_vset <= '0; r_irqe <= '0; r_pal <= '0;
      pal_we <= 1'b0; cmd_op <= '0; cmd_strobe <= 1'b0;
    end else begin
      cmd_strobe <= 1'b0;
      pal_we     <= 1'b0;
      if (reg_we) begin
        unique case (reg_idx)
          4'd0: if (reg_wdata[1:0] != 2'd0) begin
                  cmd_op     <= reg_wdata[1:0];
                  cmd_strobe <= 1'b1;
                end
          4'd1:  r_x     <= reg_wdata[15:0];
          4'd2:  r_y     <= reg_wdata[15:0];
          4'd3:  r_wh    <= reg_wdata[17:0];
          4'd4:  r_color <= reg_wdata[7:0];
          4'd8: begin
                  r_pal  <= reg_wdata[15:0];
                  pal_we <= 1'b1;
                end
          4'd9:  r_vset  <= reg_wdata;
          4'd10: r_irqe  <= reg_wdata[1:0];
          default: ;
        endcase
      end
    end
  end

  // STATUS is readable; everything else reads back its stored value
  always_comb begin
    unique case (reg_idx)
      4'd1:   reg_rdata = {16'b0, r_x};
      4'd2:   reg_rdata = {16'b0, r_y};
      4'd3:   reg_rdata = {14'b0, r_wh};
      4'd4:   reg_rdata = {24'b0, r_color};
      4'd5:   reg_rdata = {frame_ctr, 14'b0, busy, irq};
      4'd9:   reg_rdata = r_vset;
      4'd10:  reg_rdata = {30'b0, r_irqe};
      default: reg_rdata = 32'b0;
    endcase
  end

  // ----------------------------------------------------------------
  // payload drivers: SPI outputs + quiescent VGA (T1)
  // ----------------------------------------------------------------
  always_comb begin
    io_out = '0;
    io_oe  = '0;

    io_out[MISO] = miso_w;
    io_oe[MISO]  = 1'b1;
    io_out[IRQ]  = irq;
    io_oe[IRQ]   = 1'b1;

    // VGA outputs: latency-matched syncs; rgb = test pattern or framebuffer
    io_out[HSYNC]      = hsync_d;
    io_out[VSYNC]      = vsync_d;
    io_oe[HSYNC]       = 1'b1;
    io_oe[VSYNC]       = 1'b1;
    io_out[RGB+5:RGB]  = testpat ? ((de_w_d4) ? pat_rgb : 6'b0) : rgb_fb;
    io_oe[RGB+5:RGB]   = 6'b111111;
  end

endmodule

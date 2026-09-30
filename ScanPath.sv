// ScanPath - framebuffer scan-out: window mapping, word fetch, 4bpp
// unpack, palette, and video configuration (VidCfg).
//
// Pipeline (chip clock == pixel clock, 25.175MHz):
//   T   : sx/sy/de from the timing generator (already registered)
//   T+1 : stage1 regs (window, lsb, widx); SRAM request issued on word
//         change only (scan has arbiter priority)
//   T+2 : SRAM Q valid; stage2 regs
//   T+3 : word register latched (gated by stage2 req so fill-cycle
//         write-through on Q can never corrupt the display word)
//   T+4 : registered rgb out; hsync/vsync delayed to match (4 cycles)
//
// VidCfg (r_vset, latched at vsync fall so changes are frame-sync):
//   [0]    stretch : horizontal x2.5 (5-output/2-fb phase pattern)
//   [2:1]  scale   : 0=x1 1=x2 2=x4 (both axes, power-of-2)
//   [12:3] x_off   : left offset (centering; default 64 for x2)
//   [21:13] y_off  : top offset
//   [31]   testpat : handled in Ppu (pattern replaces rgb_fb)
//
// Palette: 16 x 6-bit. PSET writes the shadow set; the live set is
// copied at vsync fall (no mid-frame color glitches).

module ScanPath (
  input  logic        clock,
  input  logic        reset,
  // timing generator
  input  logic [9:0]  sx,
  input  logic [9:0]  sy,
  input  logic        de,
  input  logic        hsync,
  input  logic        vsync,
  // live video config register (latched internally at vsync)
  input  logic [31:0] vset,
  // palette write port (from the register file)
  input  logic        pal_we,
  input  logic [3:0]  pal_slot,
  input  logic [5:0]  pal_rgb,
  // framebuffer read port (via arbiter)
  output logic        scan_req,
  output logic [11:0] scan_addr,
  input  logic [63:0] scan_rdata,
  // latency-matched video out
  output logic [5:0]  rgb_fb,        // framebuffer pixel (0 outside window)
  output logic        rgb_in_win,    // pixel came from the framebuffer
  output logic        hsync_d,
  output logic        vsync_d,
  output logic        vsync_pulse    // one cycle at frame start (vsync fall)
);

  // ----------------------------------------------------------------
  // vsync events + config/palette latch
  // ----------------------------------------------------------------
  logic vsync_q;
  always_ff @(posedge clock) vsync_q <= vsync;
  assign vsync_pulse = vsync_q & ~vsync;      // falling edge

  logic [1:0]  cfg_scale;
  logic        cfg_stretch;
  logic [9:0]  cfg_xoff;
  logic [8:0]  cfg_yoff;

  logic [5:0] pal_next [0:15];
  logic [5:0] pal_live [0:15];

  always_ff @(posedge clock) begin
    if (reset) begin
      cfg_scale   <= 2'd1;                    // x2
      cfg_stretch <= 1'b0;
      cfg_xoff    <= 10'd64;                  // centered: (640-512)/2
      cfg_yoff    <= 9'd0;
      for (int i = 0; i < 16; i++) begin
        pal_next[i] <= 6'b0;
        pal_live[i] <= 6'b0;
      end
    end else begin
      if (pal_we) pal_next[pal_slot] <= pal_rgb;
      if (vsync_pulse) begin
        cfg_stretch <= vset[0];
        cfg_scale   <= vset[2:1];
        cfg_xoff    <= vset[12:3];
        cfg_yoff    <= vset[21:13];
        for (int i = 0; i < 16; i++) pal_live[i] <= pal_next[i];
      end
    end
  end

  // ----------------------------------------------------------------
  // stage 1: window mapping (combinational from timing outputs)
  // ----------------------------------------------------------------
  wire [9:0]  dx   = sx - cfg_xoff;
  wire [9:0]  dy   = sy - {1'b0, cfg_yoff};
  wire        dx_ok = (sx >= cfg_xoff);
  wire        dy_ok = (sy >= {1'b0, cfg_yoff});

  // stretch phase accumulator: fb advances 2 every 5 output pixels
  logic [2:0] ph;             // 0..4 within the 5-pixel pattern
  logic [9:0] fb_xs;          // stretched fb x
  // increment decision one cycle ahead so pixel i shows floor(2i/5)
  wire  s_inc = (ph == 3'd2) || (ph == 3'd4);
  wire  win_pre = de && dx_ok && dy_ok;

  // non-stretched fb x
  wire [9:0] dx_sh = (cfg_scale == 2'd0) ? dx
                   : (cfg_scale == 2'd1) ? {1'b0, dx[9:1]}
                   : (cfg_scale == 2'd2) ? {2'b0, dx[9:2]}
                   :                       {3'b0, dx[9:3]};
  wire [8:0] dy_sh = (cfg_scale == 2'd0) ? dy[8:0]
                   : (cfg_scale == 2'd1) ? {1'b0, dy[8:1]}
                   : (cfg_scale == 2'd2) ? {2'b0, dy[8:2]}
                   :                       {3'b0, dy[8:3]};

  wire [9:0] fb_x = cfg_stretch ? fb_xs : dx_sh;
  wire [8:0] fb_y = dy_sh;

  wire win = win_pre && (fb_x < 10'd256) && (fb_y < 9'd240);

  // word index: 16 words per row -> pure concat, no multiplier
  wire [11:0] widx = {fb_y[7:0], fb_x[7:4]};
  wire [3:0]  wlsb = fb_x[3:0];

  // stretch phase update (counts only inside the window)
  always_ff @(posedge clock) begin
    if (reset) begin
      ph <= '0; fb_xs <= '0;
    end else if (!win_pre) begin
      ph <= '0; fb_xs <= '0;
    end else begin
      if (cfg_stretch) begin
        if (s_inc) fb_xs <= fb_xs + 10'd1;
        ph <= (ph == 3'd4) ? 3'd0 : ph + 3'd1;
      end
    end
  end

  // ----------------------------------------------------------------
  // stage 1 registers + fetch request on word change
  // ----------------------------------------------------------------
  logic        q1_win, q1_req;
  logic [3:0]  q1_lsb;
  logic [11:0] widx_r;

  always_ff @(posedge clock) begin
    if (reset) begin
      q1_win <= 1'b0; q1_req <= 1'b0; q1_lsb <= '0; widx_r <= '0;
      scan_req <= 1'b0; scan_addr <= '0;
    end else begin
      q1_win <= win;
      q1_lsb <= wlsb;
      if (win && (widx != widx_r)) begin
        scan_req  <= 1'b1;
        scan_addr <= widx;
        widx_r    <= widx;
        q1_req    <= 1'b1;
      end else begin
        scan_req  <= 1'b0;
        q1_req    <= 1'b0;
      end
    end
  end

  // ----------------------------------------------------------------
  // stages 2..4: align Q with the pixel, unpack, palette, register out
  // ----------------------------------------------------------------

  logic       q2_win, q2_req;
  logic [3:0] q2_lsb;
  logic       q3_win;
  logic [3:0] q3_lsb;
  logic [63:0] word_r;

  always_ff @(posedge clock) begin
    if (reset) begin
      q2_win <= 1'b0; q2_req <= 1'b0; q2_lsb <= '0;
      q3_win <= 1'b0; q3_lsb <= '0;
      word_r <= '0;
    end else begin
      q2_win <= q1_win; q2_req <= q1_req; q2_lsb <= q1_lsb;
      q3_win <= q2_win; q3_lsb <= q2_lsb;
      if (q2_req) word_r <= scan_rdata;   // ignore Q during fill write cycles
    end
  end

  wire [3:0] pix_idx = word_r[{q3_lsb, 2'b00} +: 4];

  // 4-cycle delay line for the syncs to match the video pipeline
  logic [2:0] hs_d, vs_d;
  always_ff @(posedge clock) begin
    if (reset) begin
      hs_d <= 3'b111;
      vs_d <= 3'b111;
    end else begin
      hs_d <= {hs_d[1:0], hsync};
      vs_d <= {vs_d[1:0], vsync};
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      rgb_fb     <= '0;
      rgb_in_win <= 1'b0;
      hsync_d    <= 1'b1;
      vsync_d    <= 1'b1;
    end else begin
      rgb_fb     <= q3_win ? pal_live[pix_idx] : 6'b0;
      rgb_in_win <= q3_win;
      hsync_d    <= hs_d[2];
      vsync_d    <= vs_d[2];
    end
  end

endmodule

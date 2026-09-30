// FillEngine - rectangle fill over the framebuffer SRAM write port.
//
// Geometry: 256x240 @4bpp, 16 px per 64-bit word, 16 words per row.
// Word index = y*16 + x/16, so the row base address is a pure 4-bit
// concat ({y[7:0], 4'b0}) and stepping within a row is +1.
//
// Per row the engine walks columns col_start..col_end; the first and
// last column words use nibble-granular masks (x edges are pixel
// aligned, not word aligned), interior words write all 16 pixels.
// Masks are rebuilt from nibble thermometers - no shifters.
//
// CLR (op=1) is FILL over the full screen with the same color field.
// Handshake: wr_req held until wr_gnt (arbiter may stall for scanout).

module FillEngine (
  input  logic        clock,
  input  logic        reset,
  // command (pulsed from the register file)
  input  logic        cmd_strobe,
  input  logic [1:0]  cmd_op,       // 1=CLR, 2=FILL
  input  logic [7:0]  cmd_x,
  input  logic [7:0]  cmd_y,
  input  logic [8:0]  cmd_w,        // 1..256
  input  logic [8:0]  cmd_h,        // 1..240
  input  logic [3:0]  cmd_color,
  // SRAM write port (via arbiter)
  output logic        wr_req,
  output logic [11:0] wr_addr,
  output logic [63:0] wr_data,
  output logic [63:0] wr_mask,
  input  logic        wr_gnt,
  // status
  output logic        busy,
  output logic        done_pulse
);

  typedef enum logic [1:0] { F_IDLE, F_WORD } fst_t;
  fst_t fst;

  logic [8:0]  e_y, y_end;
  logic [3:0]  e_col, col_start, col_end;
  logic [11:0] e_addr;
  logic [63:0] color_nib;
  logic [3:0]  nib_s, nib_e;

  // --------------------------------------------------------------
  // geometry decode (CLR overrides)
  // --------------------------------------------------------------
  wire       is_clr = (cmd_op == 2'd1);
  wire [9:0] gx  = is_clr ? 10'd0   : {2'b0, cmd_x};
  wire [9:0] gy  = is_clr ? 10'd0   : {2'b0, cmd_y};
  wire [9:0] gw  = is_clr ? 10'd256 : {1'b0, cmd_w};
  wire [9:0] gh  = is_clr ? 10'd240 : {1'b0, cmd_h};
  wire [9:0] gxe = gx + gw - 10'd1;
  wire [9:0] gye = gy + gh - 10'd1;

  wire cmd_valid = cmd_strobe && (cmd_op != 2'd0)
                 && (gw != 10'd0) && (gh != 10'd0) && !busy;

  // --------------------------------------------------------------
  // nibble thermometers -> edge word masks (16 comparators, no shifter)
  // --------------------------------------------------------------
  logic [63:0] m_first, m_last;
  always_comb begin
    for (int j = 0; j < 16; j++) begin
      m_first[4*j +: 4] = {4{(j[3:0] >= nib_s)}};
      m_last [4*j +: 4] = {4{(j[3:0] <= nib_e)}};
    end
  end

  wire [63:0] m_word =
      (e_col == col_start && e_col == col_end) ? (m_first & m_last)
    : (e_col == col_start)                     ? m_first
    : (e_col == col_end)                       ? m_last
    : {64{1'b1}};

  assign wr_req  = (fst == F_WORD);
  assign wr_addr = e_addr;
  assign wr_data = color_nib;
  assign wr_mask = m_word;

  // --------------------------------------------------------------
  // walk
  // --------------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      fst <= F_IDLE; busy <= 1'b0; done_pulse <= 1'b0;
      e_y <= '0; y_end <= '0; e_col <= '0;
      col_start <= '0; col_end <= '0; e_addr <= '0;
      color_nib <= '0; nib_s <= '0; nib_e <= '0;
    end else begin
      done_pulse <= 1'b0;
      unique case (fst)
        F_IDLE: if (cmd_valid) begin
          e_y       <= gy[8:0];
          y_end     <= gye[8:0];
          col_start <= gx[7:4];
          col_end   <= gxe[7:4];
          nib_s     <= gx[3:0];
          nib_e     <= gxe[3:0];
          e_col     <= gx[7:4];
          color_nib <= {16{cmd_color}};
          e_addr    <= {gy[7:0], 4'b0} + {8'b0, gx[7:4]};
          busy      <= 1'b1;
          fst       <= F_WORD;
        end

        F_WORD: if (wr_gnt) begin
          if (e_col == col_end) begin
            if (e_y == y_end) begin
              busy       <= 1'b0;
              done_pulse <= 1'b1;
              fst        <= F_IDLE;
            end else begin
              e_y    <= e_y + 9'd1;
              e_col  <= col_start;
              e_addr <= {e_y[7:0] + 8'd1, 4'b0} + {8'b0, col_start};
            end
          end else begin
            e_col  <= e_col + 4'd1;
            e_addr <= e_addr + 12'd1;
          end
        end

        default: fst <= F_IDLE;
      endcase
    end
  end

endmodule

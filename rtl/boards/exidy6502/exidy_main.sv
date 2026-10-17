//============================================================================
//
//  Exidy 6502 "Universal Game Board" logic PCB (Venture / Mouse Trap / Pepper II generation)
//  Copyright (C) 2026 Rodimus
//
//  From the schematics (Claude/exidy_schematic_facts.md), MAME exidy.cpp for the memory maps:
//    11.289 MHz / 2 = pixel, / 16 = 6502. 336 x 280 raster, 256 x 256 visible, 59.99 Hz.
//    Screen RAM 32 x 32 codes, RAM-defined 8 x 8 characters (1bpp, or 2bpp on Pepper II's plane board).
//    Two 16 x 16 motion objects: 74LS193 position counters loaded by the CPU, counting visible pixels / lines;
//    an object shows while its counter's high nibble is F. Image EPROM 11D: {MO2, bank, image, half, row}.
//    Colour: 74148 priority MO1 > MO2 > character quadrant > background, selecting a bit of the three colour latches.
//    One IRQ flip-flop (LS112 6E): set by vblank, enabled collisions, held set by a coin; cleared by reading 5103.
//    The condition latch (8E) is clocked by that flip-flop, so it holds the first event of each interrupt.
//
//  cfg (MRA index 1 byte 3):
//    [0] collision MO1 x character raises IRQ       [1] MO2 x character raises IRQ    [2] MO1 x MO2 raises IRQ
//    [3] 8E D2 = /MO1 video (Venture, Pepper II), else MO1 x character (Mouse Trap)
//    [4] 8E D4 = MO1 x MO2 (Mouse Trap), else an open input (reads 1)
//    [5] Pepper II map: 2bpp characters, character RAM 6000-6FFF (plane 0 6000, plane 1 6800)
//    [6] Fax map: work RAM 0000-07FF, IN4 at 1A00, IN3 at 1C00, question ROM bank latch (write 2000), bank 2000-3FFF
//
//  Pixel timing: clk = 4 x pixel. ph 0 = addresses out, ph 1 = screen code / MO1 image, ph 2 = character
//  pattern / MO2 image, ph 3 = mix; the colour index is registered at ce_pix, one pixel behind (pix_x, pix_y).
//
//============================================================================

module exidy_main
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,
    input  logic  [1:0] ph,             // phase within the pixel, ce_pix ends phase 3
    input  logic        ce_pix,
    input  logic  [7:0] cfg,

    // main 6502 (owned by exidy_board)
    input  logic        cpu_ce,
    input  logic [15:0] cpu_a,
    input  logic  [7:0] cpu_do,
    input  logic        cpu_rw,
    output logic  [7:0] cpu_di,
    output logic        cpu_irq_n,

    input  logic  [7:0] rom_d,          // program ROM (exidy_board), addressed by cpu_a[14:0]
    output logic [17:0] qrom_a,         // Fax question ROM: {bank, cpu_a[12:0]}
    input  logic  [7:0] qrom_d,
    output logic [10:0] spr_a,          // motion object EPROM 11D
    input  logic  [7:0] spr_d,

    // audio / colour board bus (52xx): main-side PIA lives on the sound board
    output logic        pia_cs,
    input  logic  [7:0] pia_dout,

    input  logic  [7:0] in0,            // 5101 control inputs
    input  logic  [7:0] dsw,            // 5100 option switches (bit 0 = coin 2, active high)
    input  logic  [7:0] in2,            // 5213 (Mouse Trap gate buttons)
    input  logic  [7:0] intsrc,         // 5103 static bits: [3] TABLE, [1:0] language
    input  logic  [7:0] in3,            // Fax 1C00
    input  logic  [7:0] in4,            // Fax 1A00
    output logic        in0_rd,         // 5101 read (Teeter Torture dial steps on it)
    input  logic        coin1,          // active high
    input  logic        coin2,

    // video out, one pixel behind the counters
    output logic  [8:0] pix_x,          // 0-335
    output logic  [8:0] pix_y,          // 0-279
    output logic  [2:0] pix_rgb,        // {R, G, B} 1 bit each
    output logic        vbl_irq_raw,    // raw vblank for pause / hiscore

    // hiscore: work RAM 0000-03FF
    input  logic  [9:0] hs_a,
    input  logic  [7:0] hs_din,
    output logic  [7:0] hs_dout,
    input  logic        hs_we
);

localparam [8:0] H_TOTAL = 9'd336;
localparam [8:0] V_TOTAL = 9'd280;
localparam [8:0] H_VCNT  = 9'h13C;      // VCNTC = NAND(HSYNC, E8, E16, 6phi0): the line changes inside HSYNC
localparam [7:0] MO_HOFS = 8'd8;        // MAME sx = 232 - P; the counter window alone gives 240 - P #unverified

wire pepper = cfg[5];
wire fax    = cfg[6];

/////////////////////////////  Raster counters  /////////////////////////////

logic [8:0] hcnt = 9'd0, vcnt = 9'd0;
always_ff @(posedge clk) begin
    if (ce_pix) begin
        hcnt <= (hcnt == H_TOTAL - 9'd1) ? 9'd0 : hcnt + 9'd1;
        if (hcnt == H_VCNT) vcnt <= (vcnt == V_TOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
    end
end

wire h_vis = (hcnt < 9'd256);
wire v_vis = (vcnt < 9'd256);
wire vis   = h_vis & v_vis;

/////////////////////////////  CPU decode (MAME maps)  /////////////////////////////

wire sel_ram   = fax ? (cpu_a[15:11] == 5'b00000)                      // 0000-07FF
                     : (cpu_a[15:10] == 6'b000000);                    // 0000-03FF
wire sel_in4   = fax & (cpu_a[15:8] == 8'h1A);
wire sel_in3   = fax & (cpu_a[15:8] == 8'h1C);
wire sel_qrom  = fax & (cpu_a[15:13] == 3'b001);                       // 2000-3FFF (write 2000 = bank latch)
wire sel_vram  = (cpu_a[15:11] == 5'b01000);                           // 4000-43FF, mirror 4400
wire sel_cram  = pepper ? (cpu_a[15:12] == 4'h6)                       // 6000-6FFF
                        : (cpu_a[15:11] == 5'b01001);                  // 4800-4FFF
wire sel_mo    = (cpu_a[15:8] == 8'h50);
wire sel_io    = (cpu_a[15:8] == 8'h51);
wire sel_ab    = (cpu_a[15:8] == 8'h52);
wire sel_rom   = cpu_a[15];

assign pia_cs = sel_ab & ~cpu_a[4];
wire   sel_col = sel_ab &  cpu_a[4];                                   // A2-A0: 0 blue, 1 green, 2 red, 3 IN2

wire wr = cpu_ce & ~cpu_rw;
wire rd = cpu_ce &  cpu_rw;

/////////////////////////////  RAMs  /////////////////////////////

logic [7:0] ram_q, vram_q_cpu, vram_q, cram_q_cpu, cram_q, cram1_q;
logic [9:0] vram_va;
logic [10:0] cram_va;

dpram_dc #(.widthad_a(11)) work_ram
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(wr & sel_ram), .q_a(ram_q),
    .clock_b(clk), .address_b({1'b0, hs_a}), .data_b(hs_din), .wren_b(hs_we), .q_b(hs_dout)
);

dpram_dc #(.widthad_a(10)) screen_ram
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_do), .wren_a(wr & sel_vram), .q_a(vram_q_cpu),
    .clock_b(clk), .address_b(vram_va), .data_b(8'd0), .wren_b(1'b0), .q_b(vram_q)
);

// character RAM: 2K plane 0 (1bpp boards: the whole 4800-4FFF); Pepper II plane 1 at 6800-6FFF
wire cram_cpu_p1 = pepper & cpu_a[11];
dpram_dc #(.widthad_a(11)) char_ram0
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(wr & sel_cram & ~cram_cpu_p1), .q_a(cram_q_cpu),
    .clock_b(clk), .address_b(cram_va), .data_b(8'd0), .wren_b(1'b0), .q_b(cram_q)
);

logic [7:0] cram1_q_cpu;
dpram_dc #(.widthad_a(11)) char_ram1
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_do), .wren_a(wr & sel_cram & cram_cpu_p1), .q_a(cram1_q_cpu),
    .clock_b(clk), .address_b(cram_va), .data_b(8'd0), .wren_b(1'b0), .q_b(cram1_q)
);

/////////////////////////////  Latches  /////////////////////////////

logic [7:0] mo1h = 8'd0, mo1v = 8'd0, mo2h = 8'd0, mo2v = 8'd0;   // 74LS193 position counters
logic [7:0] mo_img = 8'd0;                                       // 14B: [3:0] MO1 image, [7:4] MO2
logic [7:0] ocl = 8'd0;                                          // 9D: [5] MO1 bank, [6] MO2 bank
logic [7:0] col_r = 8'd0, col_g = 8'd0, col_b = 8'd0;
logic [4:0] qbank = 5'd0;                                        // Fax question ROM bank

wire mo_wr = wr & sel_mo;
always_ff @(posedge clk) begin
    if (reset) qbank <= 5'd0;
    else if (wr & sel_qrom) qbank <= cpu_do[4:0];
    if (wr & sel_io & (cpu_a[1:0] == 2'd0)) mo_img <= cpu_do;
    if (wr & sel_io & (cpu_a[1:0] == 2'd1)) ocl    <= cpu_do;
    if (wr & sel_col & (cpu_a[2:0] == 3'd0)) col_b <= cpu_do;
    if (wr & sel_col & (cpu_a[2:0] == 3'd1)) col_g <= cpu_do;
    if (wr & sel_col & (cpu_a[2:0] == 3'd2)) col_r <= cpu_do;
end

// H counters count each visible pixel, V counters once per visible line (CBLB rising = end of the line)
wire v_step = ce_pix && v_vis && (hcnt == 9'd255);
always_ff @(posedge clk) begin
    if (mo_wr && cpu_a[7:6] == 2'd0) mo1h <= cpu_do;
    else if (ce_pix && vis)          mo1h <= mo1h + 8'd1;
    if (mo_wr && cpu_a[7:6] == 2'd1) mo1v <= cpu_do;
    else if (v_step)                 mo1v <= mo1v + 8'd1;
    if (mo_wr && cpu_a[7:6] == 2'd2) mo2h <= cpu_do;
    else if (ce_pix && vis)          mo2h <= mo2h + 8'd1;
    if (mo_wr && cpu_a[7:6] == 2'd3) mo2v <= cpu_do;
    else if (v_step)                 mo2v <= mo2v + 8'd1;
end

/////////////////////////////  Pixel pipeline  /////////////////////////////

wire [7:0] m1hx = mo1h + MO_HOFS;
wire [7:0] m2hx = mo2h + MO_HOFS;
wire       m1win = vis && (m1hx[7:4] == 4'hF) && (mo1v[7:4] == 4'hF);
wire       m2win = vis && (m2hx[7:4] == 4'hF) && (mo2v[7:4] == 4'hF);

assign vram_va = {vcnt[7:3], hcnt[7:3]};

logic [7:0] code_q;
logic [2:0] col_q;
logic [7:0] m1_byte, m2_byte;
logic [2:0] m1_bit, m2_bit;
logic       m1win_q, m2win_q, vis_q;

always_comb begin
    cram_va = {vram_q, vcnt[2:0]};
    case (ph)
        2'd0:    spr_a = {1'b0, ocl[5], mo_img[3:0], m1hx[3], mo1v[3:0]};
        default: spr_a = {1'b1, ocl[6], mo_img[7:4], m2hx[3], mo2v[3:0]};
    endcase
end

always_ff @(posedge clk) begin
    case (ph)
        2'd0: begin
            col_q   <= hcnt[2:0];
            m1_bit  <= m1hx[2:0];
            m2_bit  <= m2hx[2:0];
            m1win_q <= m1win;
            m2win_q <= m2win;
            vis_q   <= vis;
        end
        2'd1: begin
            code_q  <= vram_q;
            m1_byte <= spr_d;
        end
        2'd2: m2_byte <= spr_d;
        default: ;
    endcase
end

// phase 3: character pattern (plane 0 = video / collision, plane 1 = colour select on Pepper II) and the mix
wire ch_on = cram_q[3'd7 - col_q];
wire ch_p1 = cram1_q[3'd7 - col_q];
wire m1_on = m1win_q & m1_byte[3'd7 - m1_bit];
wire m2_on = m2win_q & m2_byte[3'd7 - m2_bit];

wire [1:0] quad = pepper ? {code_q[7], ch_p1} : code_q[7:6];
logic [2:0] csel;                       // colour latch bit
always_comb begin
    if      (m1_on) csel = 3'd7;
    else if (m2_on) csel = 3'd6;
    else if (ch_on) csel = 3'd4 - {1'b0, quad};
    else            csel = 3'd0;
end

always_ff @(posedge clk) begin
    if (ce_pix) begin
        pix_x   <= hcnt;
        pix_y   <= vcnt;
        pix_rgb <= vis_q ? {col_r[csel], col_g[csel], col_b[csel]} : 3'b000;
    end
end

/////////////////////////////  Interrupts  /////////////////////////////

wire c_m1ch = vis_q & m1_on & ch_on;
wire c_m2ch = vis_q & m2_on & ch_on;
wire c_m1m2 = vis_q & m1_on & m2_on;
wire coll   = (cfg[0] & c_m1ch) | (cfg[1] & c_m2ch) | (cfg[2] & c_m1m2);
wire vl1    = ce_pix && (hcnt == H_VCNT) && (vcnt == 9'd255);
// DIAG-REVERT-2026-10-16: original below, uncomment to restore
// wire coint  = coin1 | coin2;
logic coin_d = 1'b0;  // DIAG: a coin raises one IRQ event on its leading edge instead of holding the flip-flop preset
always_ff @(posedge clk) coin_d <= coin1 | coin2;
wire coint  = 1'b0;
wire coin_ev = (coin1 | coin2) & ~coin_d;
wire eir    = rd & sel_io & (cpu_a[1:0] == 2'd3);

logic irq_q = 1'b0;
logic [7:0] cond = 8'd0;
wire  in_vbl = ~v_vis | vl1;
always_ff @(posedge clk) begin
    if (reset) irq_q <= 1'b0;
    else if (coint) irq_q <= 1'b1;
    else if (eir) irq_q <= 1'b0;
    else if (vl1 || coin_ev || (ce_pix && coll)) irq_q <= 1'b1;   // DIAG-REVERT-2026-10-16: was (vl1 || (ce_pix && coll))

    // 8E latches on the flip-flop's rising edge
    if (!irq_q && (coint || (!eir && (vl1 || coin_ev || (ce_pix && coll)))))   // DIAG-REVERT-2026-10-16: was (vl1 || (ce_pix && coll))
        cond <= {~in_vbl, coin1, coin2,
                 cfg[4] ? c_m1m2 : 1'b1,
                 intsrc[3],
                 cfg[3] ? ~m1_on : c_m1ch,
                 intsrc[1:0]};
end
assign cpu_irq_n   = ~irq_q;
assign in0_rd      = rd & sel_io & (cpu_a[1:0] == 2'd1);
assign qrom_a      = {qbank, cpu_a[12:0]};
assign vbl_irq_raw = ~v_vis;

/////////////////////////////  CPU read mux  /////////////////////////////

always_comb begin
    cpu_di = 8'hFF;                     // data bus terminators (4.7K up / 6.8K down)
    if      (sel_rom)  cpu_di = rom_d;
    else if (sel_ram)  cpu_di = ram_q;
    else if (sel_qrom) cpu_di = qrom_d;
    else if (sel_in4)  cpu_di = in4;
    else if (sel_in3)  cpu_di = in3;
    else if (sel_vram) cpu_di = vram_q_cpu;
    else if (sel_cram) cpu_di = cram_cpu_p1 ? cram1_q_cpu : cram_q_cpu;
    else if (sel_io) begin
        case (cpu_a[1:0])
            2'd0:    cpu_di = dsw;
            2'd1:    cpu_di = in0;
            2'd3:    cpu_di = cond;
            default: cpu_di = 8'hFF;
        endcase
    end
    else if (pia_cs) cpu_di = pia_dout;
    else if (sel_col && cpu_a[2:0] == 3'd3) cpu_di = in2;
end

endmodule

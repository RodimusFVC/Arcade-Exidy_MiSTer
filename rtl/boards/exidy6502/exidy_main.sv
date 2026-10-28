//============================================================================
//
//  Exidy 6502 "Universal Game Board" logic PCB (Venture / Mouse Trap / Pepper II generation)
//  Copyright (C) 2026 Rodimus
//
//  From the schematics, with MAME exidy.cpp for the memory maps:
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
//  cfg2 (MRA index 1 byte 2), gen-1 boards (Targ / Spectar generation):
//    [0] program ROM also at 0800-3FFF          [1] (board top) FF00-FFFF reads ROM 3F00-3FFF
//    [2] image EPROM A10 / A9 grounded (one 2708 for both objects, no bank bits)
//    [3] Rallys bootleg object registers: 5000 / 5001 MO1 H / V, 5300 / 5301 MO2 H / V
//    [4] 5103 coin bits active low (Rallys bootlegs)
//    [5] character generator is ROM (Side Trak): CPU writes ignored, contents preloaded from ioctl 0x15000
//  Colour latches start from col_init (gen-1 boards set colours with DIP shunts)
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
    input  logic  [7:0] cfg2,
    input  logic [23:0] col_init,       // {R, G, B} colour latches at reset

    input  logic [24:0] ioctl_addr,     // character ROM preload (Side Trak)
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    // main 6502 (owned by exidy_dispatcher)
    input  logic        cpu_ce,
    input  logic [15:0] cpu_a,
    input  logic  [7:0] cpu_do,
    input  logic        cpu_rw,
    output logic  [7:0] cpu_di,
    output logic        cpu_irq_n,

    input  logic  [7:0] rom_d,          // program ROM (exidy_dispatcher), addressed by cpu_a[14:0]
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
    input  logic        hs_we,

    // board RAM pool (rtl/ram_pool_pkg.sv, dispatcher): 2 char plane 0, 3 char plane 1, 4 work, 5 screen
    output ram_pool_pkg::pram_i_t [5:0] pr_i,
    input  ram_pool_pkg::pram_o_t [5:0] pr_o,
    output logic        cram_load       // index-0 preload of char RAM 0 (Side Trak): wins pool block 2 whatever the variant
);

localparam [8:0] H_TOTAL = 9'd336;
localparam [8:0] V_TOTAL = 9'd280;
localparam [8:0] H_VCNT  = 9'h13C;      // VCNTC = NAND(HSYNC, E8, E16, 6phi0): the line changes inside HSYNC
localparam [7:0] MO_HOFS = 8'd8;        // object x = 232 - P; the counter window alone gives 240 - P #unverified

wire pepper = cfg[5];
wire fax    = cfg[6];
wire gen1   = cfg2[0];
wire rallys = cfg2[3];

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

/////////////////////////////  CPU decode (memory map)  /////////////////////////////

wire sel_ram   = fax ? (cpu_a[15:11] == 5'b00000)                      // 0000-07FF
                     : (cpu_a[15:10] == 6'b000000);                    // 0000-03FF
wire sel_in4   = fax & (cpu_a[15:8] == 8'h1A);
wire sel_in3   = fax & (cpu_a[15:8] == 8'h1C);
wire sel_qrom  = fax & (cpu_a[15:13] == 3'b001);                       // 2000-3FFF (write 2000 = bank latch)
wire sel_vram  = (cpu_a[15:11] == 5'b01000);                           // 4000-43FF, mirror 4400
wire sel_cram  = pepper ? (cpu_a[15:12] == 4'h6)                       // 6000-6FFF
                        : (cpu_a[15:11] == 5'b01001);                  // 4800-4FFF
wire sel_mo    = (cpu_a[15:8] == 8'h50) | (rallys & (cpu_a[15:8] == 8'h53));
wire sel_io    = (cpu_a[15:8] == 8'h51);
wire sel_ab    = (cpu_a[15:8] == 8'h52);
wire sel_rom   = cpu_a[15] | (gen1 & (cpu_a[15:14] == 2'b00) & (cpu_a[13:11] != 3'd0));   // 8000-FFFF (+ 0800-3FFF)

assign pia_cs = sel_ab & ~cpu_a[4];
wire   sel_col = sel_ab &  cpu_a[4];                                   // A2-A0: 0 blue, 1 green, 2 red, 3 IN2

wire wr = cpu_ce & ~cpu_rw;
wire rd = cpu_ce &  cpu_rw;

/////////////////////////////  RAMs  /////////////////////////////

logic [7:0] ram_q, vram_q_cpu, vram_q, cram_q_cpu, cram_q, cram1_q;
logic [9:0] vram_va;
logic [10:0] cram_va;

// The four RAMs are pool blocks 4 (work), 5 (screen), 2 / 3 (char planes).
// Character RAM: 2K plane 0 (1bpp boards: the whole 4800-4FFF); Pepper II plane 1 at 6800-6FFF. Plane 0 is preloaded from
// index 0 0x15000-0x157FF (the CPU is in reset).

// character RAM: 2K plane 0 (1bpp boards: the whole 4800-4FFF); Pepper II plane 1 at 6800-6FFF
wire cram_cpu_p1 = pepper & cpu_a[11];
assign cram_load = ioctl_wr0 && ioctl_addr[24:11] == 14'h2A;  // index 0 0x15000-0x157FF (CPU is in reset)
logic [7:0] cram1_q_cpu;

assign pr_i[0] = '0;
assign pr_i[1] = '0;
// block 2: char RAM plane 0 (A = CPU / index-0 preload, B = video)
assign pr_i[2].a_addr = {4'd0, cram_load ? ioctl_addr[10:0] : cpu_a[10:0]};
assign pr_i[2].a_d    = cram_load ? ioctl_dout : cpu_do;
assign pr_i[2].a_we   = cram_load | (wr & sel_cram & ~cram_cpu_p1 & ~cfg2[5]);
assign pr_i[2].b_addr = {4'd0, cram_va};
assign pr_i[2].b_d    = 8'd0;
assign pr_i[2].b_we   = 1'b0;
// block 3: char RAM plane 1 (Pepper II)
assign pr_i[3].a_addr = {4'd0, cpu_a[10:0]};
assign pr_i[3].a_d    = cpu_do;
assign pr_i[3].a_we   = wr & sel_cram & cram_cpu_p1;
assign pr_i[3].b_addr = {4'd0, cram_va};
assign pr_i[3].b_d    = 8'd0;
assign pr_i[3].b_we   = 1'b0;
// block 4: work RAM (A = CPU, B = hiscore)
assign pr_i[4].a_addr = {4'd0, cpu_a[10:0]};
assign pr_i[4].a_d    = cpu_do;
assign pr_i[4].a_we   = wr & sel_ram;
assign pr_i[4].b_addr = {5'd0, hs_a};
assign pr_i[4].b_d    = hs_din;
assign pr_i[4].b_we   = hs_we;
// block 5: screen RAM (A = CPU, B = video)
assign pr_i[5].a_addr = {5'd0, cpu_a[9:0]};
assign pr_i[5].a_d    = cpu_do;
assign pr_i[5].a_we   = wr & sel_vram;
assign pr_i[5].b_addr = {5'd0, vram_va};
assign pr_i[5].b_d    = 8'd0;
assign pr_i[5].b_we   = 1'b0;
assign {cram_q_cpu, cram_q}   = {pr_o[2].a_q, pr_o[2].b_q};
assign {cram1_q_cpu, cram1_q} = {pr_o[3].a_q, pr_o[3].b_q};
assign {ram_q, hs_dout}       = {pr_o[4].a_q, pr_o[4].b_q};
assign {vram_q_cpu, vram_q}   = {pr_o[5].a_q, pr_o[5].b_q};

/////////////////////////////  Latches  /////////////////////////////

logic [7:0] mo1h = 8'd0, mo1v = 8'd0, mo2h = 8'd0, mo2v = 8'd0;   // 74LS193 position counters
logic [7:0] mo_img = 8'd0;                                       // 14B: [3:0] MO1 image, [7:4] MO2
logic [7:0] ocl = 8'd0;                                          // 9D: [5] MO1 bank, [6] MO2 bank
logic [7:0] col_r = 8'd0, col_g = 8'd0, col_b = 8'd0;
logic [4:0] qbank = 5'd0;                                        // Fax question ROM bank

wire mo_wr = wr & sel_mo;
wire [1:0] mo_reg = rallys ? {cpu_a[8], cpu_a[0]} : cpu_a[7:6];   // 0 MO1 H, 1 MO1 V, 2 MO2 H, 3 MO2 V
always_ff @(posedge clk) begin
    if (reset) qbank <= 5'd0;
    else if (wr & sel_qrom) qbank <= cpu_do[4:0];
    if (wr & sel_io & (cpu_a[1:0] == 2'd0)) mo_img <= cpu_do;
    if (wr & sel_io & (cpu_a[1:0] == 2'd1)) ocl    <= cpu_do;
    if (reset) {col_r, col_g, col_b} <= col_init;
    else begin
        if (wr & sel_col & (cpu_a[2:0] == 3'd0)) col_b <= cpu_do;
        if (wr & sel_col & (cpu_a[2:0] == 3'd1)) col_g <= cpu_do;
        if (wr & sel_col & (cpu_a[2:0] == 3'd2)) col_r <= cpu_do;
    end
end

// H counters count each visible pixel, V counters once per visible line (CBLB rising = end of the line)
wire v_step = ce_pix && v_vis && (hcnt == 9'd255);
always_ff @(posedge clk) begin
    if (mo_wr && mo_reg == 2'd0) mo1h <= cpu_do;
    else if (ce_pix && vis)      mo1h <= mo1h + 8'd1;
    if (mo_wr && mo_reg == 2'd1) mo1v <= cpu_do;
    else if (v_step)             mo1v <= mo1v + 8'd1;
    if (mo_wr && mo_reg == 2'd2) mo2h <= cpu_do;
    else if (ce_pix && vis)      mo2h <= mo2h + 8'd1;
    if (mo_wr && mo_reg == 2'd3) mo2v <= cpu_do;
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
        2'd0:    spr_a = {1'b0, ocl[5] & ~cfg2[2], mo_img[3:0], m1hx[3], mo1v[3:0]};
        default: spr_a = {~cfg2[2], ocl[6] & ~cfg2[2], mo_img[7:4], m2hx[3], mo2v[3:0]};
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
logic coin_d = 1'b0;  // a coin raises one IRQ event on its leading edge instead of holding the flip-flop preset
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
    else if (vl1 || coin_ev || (ce_pix && coll)) irq_q <= 1'b1;

    // 8E latches on the flip-flop's rising edge
    if (!irq_q && (coint || (!eir && (vl1 || coin_ev || (ce_pix && coll)))))
        cond <= {~in_vbl, coin1 ^ cfg2[4], coin2 ^ cfg2[4],
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

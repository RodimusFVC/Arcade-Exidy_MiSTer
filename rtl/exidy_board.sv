//============================================================================
//
//  Exidy 6502 raster hardware — board top
//  Copyright (C) 2026 Rodimus
//
//  Owns the shared parts: one main 6502, one sound 6502, one speech Z80, the program / image ROMs,
//  the CRT Flip frame buffer and the video output stage. Boards export bus ports.
//
//  Variant (MRA index 1 byte 0):
//    0: Venture-type logic board + audio/colour board (venture)
//    1: Mouse Trap (adds the Z80 / MC3417 speech section)
//    2: Pepper II-type logic board (2bpp plane board, character RAM 6000) (pepper2, hardhat)
//    3: Teeter Torture (Venture + dial on IN0 bits 2 / 6 + MAME's 600 Hz NMI)
//    4: Fax (Pepper II + question ROM banks; the map is board config bit 6)
//    5: gen-1 board + Targ audio board (targ, targc)
//    6: gen-1 board + Spectar-type audio board (spectar, sidetrac, rallys, panzer, phantoma)
//    7: Circus-family board (rtl/boards/exidy_circus: circus, trapeze, robotbwl, ripcord, crash)
//    8: Star Fire, 9: Fire One (rtl/boards/exidy_starfire: Z80 = the pooled T80pa, bitmap video)
//   10: Victory (rtl/boards/exidy_victory: Z80 = the pooled T80pa, microcode video; Fax's question-ROM BRAMs
//       hold its foreground planes and ROM 8000-BFFF; Venture sound board in Victory mode)
//   11: Car Polo (rtl/boards/exidy_carpolo: main 6502 at 940.75 kHz, collision checker, no sound in MAME)
//  Gen-1 map options are board config 2 (index 1 byte 2), see exidy_main.sv.
//  Board config bits (index 1 byte 3) are documented in rtl/boards/exidy6502/exidy_main.sv.
//
//  ioctl index 0 (MRA), MAME regions:
//    0x00000 - 0x07FFF  maincpu (offset & 0x7FFF: 8000-FFFF program, Targ-era 0800-3FFF lands below 0x4000)
//    0x08000 - 0x0FFFF  soundbd:audiocpu (ROMs 5800-7FFF)
//    0x10000 - 0x13FFF  soundbd:cvsdcpu
//    0x14000 - 0x147FF  gfx1 (motion object EPROM 11D)
//    0x14800 - 0x1493F  proms (5C / 6D / 14H, loaded for reference, not used)
//    0x14A00 - 0x14A1F  Targ audio tone PROM HRA2B-1
//    0x15000 - 0x157FF  Side Trak character ROM (maincpu 0x4800)
//    0x15800 - 0x15FFF  Circus family character PROMs (gfx1); object PROM (gfx2) at 0x14000
//    0x16000 - 0x163FF  Circus family line PROMs 4D / 5D
//    0x20000 - 0x4FFFF  Fax question ROMs (maincpu 0x10000-0x3FFFF): bank n at 0x20000 + n * 0x2000, 24 banks
//
//============================================================================

module exidy_board
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,
    input  logic  [7:0] board_cfg,
    input  logic  [7:0] board_cfg2,
    input  logic [23:0] col_init,
    output logic        ce_pix,

    input  logic  [7:0] in0,
    input  logic  [7:0] dsw,
    input  logic  [7:0] in2,
    input  logic  [7:0] intsrc,
    input  logic  [7:0] coin,           // [0] coin 1, [1] coin 2 (active high)
    input  logic  [7:0] in3,            // Fax
    input  logic  [7:0] in4,
    input  logic  [7:0] dial,           // Teeter Torture dial position (rtl/exidy_dial.sv); Car Polo P1
    input  logic  [7:0] dial2,          // Car Polo P2-P4 dials
    input  logic  [7:0] dial3,
    input  logic  [7:0] dial4,
    input  logic  [7:0] paddle,         // Circus family A/D (rtl/exidy_paddle.sv)
    input  logic  [7:0] stick_x,        // Star Fire A/D
    input  logic  [7:0] stick_y,
    input  logic  [7:0] throttle,
    input  logic  [5:0] pad1,           // Fire One paddles 0-63
    input  logic  [5:0] pad2,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic        crt_flip,
    input  logic        overlay_en,     // Circus family cabinet colour overlay (MAME layouts)
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    input  logic  [3:0] vol_music,
    input  logic  [3:0] vol_sfx,
    input  logic  [3:0] vol_speech,
    // discrete sound engine: program download (MRA index 5), on = the MRA carried a program, Game Audio caps
    input  logic        ds_wr,
    input  logic [12:0] ds_addr,
    input  logic  [7:0] ds_data,
    input  logic        ds_on,
    input  logic [15:0] ds_caps,        // {src7, src6} (tools/dsnd.py)

    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,
    output logic        vblank_raw,

    output logic signed [15:0] audio,
    output logic signed [15:0] audio_r,
    // Victory CMOS RAM through MiSTer NVRAM (ioctl index 4)
    input  logic        nv_wr,
    input  logic  [7:0] nv_din,
    output logic  [7:0] nv_dout,
    input  logic        nv_saved,
    output logic        nv_dirty,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write,

    output logic        q_byte_en,      // Fax question ROMs from the DDR3 copy of index 0 (rtl/ram_rom/ddr_rom.sv byte port)
    output logic [24:0] q_byte_addr,
    input  logic  [7:0] q_byte_q,
    input  logic        q_byte_rdy
);

/////////////////////////////  Clock enables  /////////////////////////////

logic [1:0] ph = 2'd0;
logic [4:0] cdiv = 5'd0;
always_ff @(posedge clk) begin
    ph   <= ph + 2'd1;
    cdiv <= cdiv + 5'd1;
end
wire   ce_exi  = (ph == 2'd3);                          // 6502 boards: 4 clocks per pixel
wire   main_ce = (cdiv == 5'd31) & ~pause;             // 11.289 MHz / 16
logic  cpu_ce;                                          // main_ce, held while Fax waits for a question-ROM byte
wire   circus  = (variant == 8'd7);
wire   sf      = (variant == 8'd8) || (variant == 8'd9);
wire   vic     = (variant == 8'd10);
wire   pal9    = sf | vic;                              // boards with a 9-bit palette (pen-indexed frame buffer)
wire   cp      = (variant == 8'd11);                    // Car Polo: 24-bit colour from its colour PROM
logic [4:0] cp_div = 5'd0;                              // 11.289 MHz / 12 = 940.75 kHz
always_ff @(posedge clk) cp_div <= (cp_div == 5'd23) ? 5'd0 : cp_div + 5'd1;
wire   cp_ce   = (cp_div == 5'd23) & ~pause;
logic  sf_ce_pix, sf_cen_p, sf_cen_n;
assign ce_pix  = sf ? sf_ce_pix : ce_exi;
logic  ce_d = 1'b0;
always_ff @(posedge clk) ce_d <= ce_pix;

// Star Fire board outputs (declared ahead of the muxes that use them)
logic [8:0] s_pix_x, s_pix_y, s_pix_rgb, s_pal_rq;
logic [5:0] s_pix_pen;
logic       s_vblank_raw;
logic [7:0] fb_q;
// Victory board outputs
logic [8:0] v_pix_x, v_pix_y, v_pix_rgb, v_pal_rq;
logic [5:0] v_pix_pen;
logic       v_vblank_raw;
logic [16:0] v_fga_addr, v_fgb_addr;
logic  [7:0] v_fga_d, v_fga_q;
logic        v_fga_we;
// Car Polo board outputs
logic [7:0]  p_di;
logic        p_irq_n, p_vblank_raw;
logic [10:0] p_spr_a;
logic [8:0]  p_pix_x, p_pix_y;
logic [4:0]  p_pix_idx;
logic [23:0] p_pix_rgb, p_pal_rq;
logic        v_snd_wr, v_snd_rd;
logic  [7:0] v_snd_resp;
logic  [1:0] v_snd_status;
logic [15:0] z_a;                       // pooled Z80 address (also the Star Fire ROM address)

/////////////////////////////  ROMs  /////////////////////////////

wire load_main = ioctl_wr0 && ioctl_addr < 25'h08000;
wire load_spr  = ioctl_wr0 && ioctl_addr[24:11] == 14'h0028;   // 0x14000-0x147FF

logic [15:0] m_a;
logic  [7:0] rom_d, spr_d;
logic [10:0] spr_a;

dpram_dc #(.widthad_a(15)) rom_main
(
    .clock_a(clk), .address_a(ioctl_addr[14:0]), .data_a(ioctl_dout), .wren_a(load_main),
    .clock_b(clk), .address_b((sf | vic) ? z_a[14:0] : cp ? {3'b111, m_a[11:0]} : circus ? {3'b000, m_a[11:0]} : (board_cfg2[1] & m_a[15]) ? {1'b0, m_a[13:0]} : m_a[14:0]), .q_b(rom_d)
);

dpram_dc #(.widthad_a(11)) rom_spr
(
    .clock_a(clk), .address_a(ioctl_addr[10:0]), .data_a(ioctl_dout), .wren_a(load_spr),
    .clock_b(clk), .address_b(spr_a), .q_b(spr_d)
);

/////////////////////////////  Main 6502  /////////////////////////////

logic  [7:0] m_do, m_di;
logic        m_rw, m_irq_n, m_sync, m_nmi_n;
logic [23:0] m_a24;

T65 main_cpu
(
    .Mode(2'b00), .Res_n(~(reset | sf | vic)), .Enable(cp ? cp_ce : cpu_ce), .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1),
    .IRQ_n(m_irq_n), .NMI_n(m_nmi_n), .SO_n(1'b1), .R_W_n(m_rw), .Sync(m_sync), .EF(), .MF(), .XF(), .ML_n(), .VP_n(),
    .VDA(), .VPA(), .A(m_a24), .DI(m_di), .DO(m_do), .Regs(), .NMI_ack()
);
assign m_a = m_a24[15:0];

/////////////////////////////  Teeter Torture: NMI + dial  /////////////////////////////

// MAME set_periodic_int(nmi_line_pulse, 10 * 60 Hz) #unverified (prototype, no schematic)
wire        teeter = (variant == 8'd3);
logic [15:0] nmi_div = 16'd0;
always_ff @(posedge clk) if (!pause) nmi_div <= (nmi_div == 16'd37629) ? 16'd0 : nmi_div + 16'd1;
assign m_nmi_n = ~(teeter && nmi_div < 16'd64);

// teetert_input_r: bit 6 = the dial moved since the game's copy, bit 2 = which way; each IN0 read steps the copy
logic [7:0] dial_last = 8'd0;
logic       in0_rd;
wire  [7:0] dial_diff = dial - dial_last;
wire        dial_up   = ~dial_diff[7];
wire  [7:0] in0_b     = teeter ? {in0[7], dial_diff != 8'd0, in0[5:3], dial_up & (dial_diff != 8'd0), in0[1:0]} : in0;
always_ff @(posedge clk)
    if (reset) dial_last <= dial;
    else if (in0_rd && dial_diff != 8'd0) dial_last <= dial_up ? dial_last + 8'd1 : dial_last - 8'd1;

/////////////////////////////  Fax question ROMs  /////////////////////////////

// ROOM-2026-10-24: original block below (192K of block RAM, used in full only by Fax / Fax 2). The question ROMs
// (index 0 0x20000-0x4FFFF) are now read from the DDR3 copy of index 0; Victory keeps its 64K plane RAM + 16K ROM.
// logic [17:0] qrom_a;
// logic  [7:0] qrom_d, q0_d, q1_d;
// wire load_q0 = ioctl_wr0 && ioctl_addr[24:17] == 8'h01;   // 0x20000-0x3FFFF: banks 0-15
// wire load_q1 = ioctl_wr0 && ioctl_addr[24:16] == 9'h004;  // 0x40000-0x4FFFF: banks 16-23
//
// // Victory: qrom0 = foreground planes (port A engine, port B scan), qrom1 = main ROM 8000-BFFF (same load path)
// dpram_dc #(.widthad_a(17)) qrom0
// (
//     .clock_a(clk), .address_a(vic ? v_fga_addr : ioctl_addr[16:0]), .data_a(vic ? v_fga_d : ioctl_dout),
//     .wren_a(vic ? v_fga_we : load_q0), .q_a(v_fga_q),
//     .clock_b(clk), .address_b(vic ? v_fgb_addr : qrom_a[16:0]), .q_b(q0_d)
// );
//
// dpram_dc #(.widthad_a(16)) qrom1
// (
//     .clock_a(clk), .address_a(ioctl_addr[15:0]), .data_a(ioctl_dout), .wren_a(load_q1),
//     .clock_b(clk), .address_b(vic ? {2'b00, z_a[13:0]} : qrom_a[15:0]), .q_b(q1_d)
// );
//
// assign qrom_d = !qrom_a[17] ? q0_d : !qrom_a[16] ? q1_d : 8'hFF;   // banks 24-31 unpopulated
logic [17:0] qrom_a;
logic  [7:0] qrom_d, q0_d, q1_d;
wire load_q1 = ioctl_wr0 && ioctl_addr[24:14] == 11'h010; // 0x40000-0x43FFF: Victory main ROM

// Victory: qrom0 = foreground planes (port A engine, port B scan; addresses {0, plane, 14 bits}), qrom1 = main ROM 8000-BFFF
// REUSE-2026-10-26: the three planes need 48K, not 64K (plane index is 0-2 on both ports, A15-A14 never 11): 32K
// (R, G) + 16K (B), read data muxed by the bank bit registered with the address (dpram_dc: registered address,
// unregistered q). Original below, uncomment (and drop the split) to restore:
// dpram_dc #(.widthad_a(16)) qrom0
// (
//     .clock_a(clk), .address_a(v_fga_addr[15:0]), .data_a(v_fga_d), .wren_a(vic & v_fga_we), .q_a(v_fga_q),
//     .clock_b(clk), .address_b(v_fgb_addr[15:0]), .q_b(q0_d)
// );
logic [7:0] q0l_qa, q0l_qb, q0h_qa, q0h_qb;
logic       fga_hi = 1'b0, fgb_hi = 1'b0;
always_ff @(posedge clk) begin
    fga_hi <= v_fga_addr[15];
    fgb_hi <= v_fgb_addr[15];
end
// RAM pool: Star Fire's vram_e / vram_o banks use these two blocks (Star Fire and Victory never run together)
logic [47:0] sf_pr_aa;
logic [31:0] sf_pr_ad, sf_pr_qa, sf_pr_qb;
logic  [3:0] sf_pr_aw;
logic [11:0] sf_pr_ba;
dpram_dc #(.widthad_a(15)) qrom0_rg
(
    .clock_a(clk), .address_a(sf ? {3'b000, sf_pr_aa[11:0]} : v_fga_addr[14:0]), .data_a(sf ? sf_pr_ad[7:0] : v_fga_d),
    .wren_a(sf ? sf_pr_aw[0] : vic & v_fga_we & ~v_fga_addr[15]), .q_a(q0l_qa),
    .clock_b(clk), .address_b(sf ? {3'b000, sf_pr_ba} : v_fgb_addr[14:0]), .data_b(8'h00), .wren_b(1'b0), .q_b(q0l_qb)
);
dpram_dc #(.widthad_a(14)) qrom0_b
(
    .clock_a(clk), .address_a(sf ? {2'b00, sf_pr_aa[23:12]} : v_fga_addr[13:0]), .data_a(sf ? sf_pr_ad[15:8] : v_fga_d),
    .wren_a(sf ? sf_pr_aw[1] : vic & v_fga_we & v_fga_addr[15]), .q_a(q0h_qa),
    .clock_b(clk), .address_b(sf ? {2'b00, sf_pr_ba} : v_fgb_addr[13:0]), .data_b(8'h00), .wren_b(1'b0), .q_b(q0h_qb)
);
logic [15:0] sf_lend_qa, sf_lend_qb;     // banks 2 / 3 from the sound board's ROM blocks
assign sf_pr_qa = {sf_lend_qa, q0h_qa, q0l_qa};
assign sf_pr_qb = {sf_lend_qb, q0h_qb, q0l_qb};
assign v_fga_q = fga_hi ? q0h_qa : q0l_qa;
assign q0_d    = fgb_hi ? q0h_qb : q0l_qb;

// REUSE-2026-10-26: Victory's main ROM 8000-BFFF now lives in the sound board's cvsd_rom (same pooled Z80, same
// z_a[13:0] port; Victory has no CVSD): one 16K block fewer. Original below, uncomment (and drop the assign) to restore:
// dpram_dc #(.widthad_a(14)) qrom1
// (
//     .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(load_q1),
//     .clock_b(clk), .address_b(z_a[13:0]), .q_b(q1_d)
// );
logic [7:0] z_rom_q;
assign q1_d = z_rom_q;
wire unused_q1 = &{1'b0, load_q1};

// Fax: question ROM byte = index-0 byte 0x20000 + {bank, A12-A0}; banks 24-31 unpopulated (FF, no fetch).
// The 6502 is held (cpu_ce) while a question-ROM read waits for its byte.
wire q_unpop = qrom_a[17:16] == 2'b11;
wire q_read  = !(circus || sf || vic || cp) && board_cfg[6] && m_rw && m_a[15:13] == 3'b001 && !q_unpop;  // exidy_main cfg[6] = Fax
assign q_byte_en   = q_read;
assign q_byte_addr = 25'h20000 + {7'd0, qrom_a};
assign qrom_d      = q_unpop ? 8'hFF : q_byte_q;
assign cpu_ce      = main_ce & ~(q_read & ~q_byte_rdy);

/////////////////////////////  Logic board  /////////////////////////////

logic        pia_cs;
logic  [7:0] pia_dout;
logic  [8:0] pix_x, pix_y, e_pix_x, e_pix_y, c_pix_x, c_pix_y;
logic  [2:0] pix_rgb, e_pix_rgb, c_pix_rgb;
logic  [7:0] e_di, c_di, e_hs_dout, c_hs_dout, s_hs_dout;
logic        e_irq_n, c_irq_n, e_vblank_raw, c_vblank_raw;
logic [10:0] e_spr_a, c_spr_a;

exidy_main main_b
(
    .clk(clk), .reset(reset), .ph(ph), .ce_pix(ce_exi), .cfg(board_cfg), .cfg2(board_cfg2), .col_init(col_init),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .cpu_ce(cpu_ce), .cpu_a(m_a), .cpu_do(m_do), .cpu_rw(m_rw), .cpu_di(e_di), .cpu_irq_n(e_irq_n),
    .rom_d(rom_d), .qrom_a(qrom_a), .qrom_d(qrom_d), .spr_a(e_spr_a), .spr_d(spr_d),
    .pia_cs(pia_cs), .pia_dout(pia_dout),
    .in0(in0_b), .dsw(dsw), .in2(in2), .intsrc(intsrc), .in3(in3), .in4(in4), .in0_rd(in0_rd),
    .coin1(coin[0]), .coin2(coin[1]),
    .pix_x(e_pix_x), .pix_y(e_pix_y), .pix_rgb(e_pix_rgb), .vbl_irq_raw(e_vblank_raw),
    .hs_a(hs_address[9:0]), .hs_din(hs_data_in), .hs_dout(e_hs_dout),
    .hs_we(hs_write && hs_address[15:10] == 6'd0 && !circus)
);

/////////////////////////////  Circus-family logic board  /////////////////////////////

logic [7:0] c_latch;
logic       c_latch_wr;

circus_main circus_b
(
    .clk(clk), .reset(reset), .ph(ph), .ce_pix(ce_exi), .cfg(board_cfg),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .cpu_ce(main_ce), .cpu_a(m_a), .cpu_do(m_do), .cpu_rw(m_rw), .cpu_di(c_di), .cpu_irq_n(c_irq_n),
    .rom_d(rom_d), .spr_a(c_spr_a), .spr_d(spr_d),
    .in0(in0), .dsw(dsw), .paddle(paddle),
    .out_latch(c_latch), .out_wr(c_latch_wr),
    .pix_x(c_pix_x), .pix_y(c_pix_y), .pix_rgb(c_pix_rgb), .vbl_irq_raw(c_vblank_raw),
    .hs_a(hs_address[9:0]), .hs_din(hs_data_in), .hs_dout(c_hs_dout),
    .hs_we(hs_write && hs_address[15:10] == 6'd0 && circus)
);

assign m_di        = cp ? p_di    : circus ? c_di        : e_di;
assign m_irq_n     = cp ? p_irq_n : circus ? c_irq_n     : e_irq_n;
assign spr_a       = cp ? p_spr_a : circus ? c_spr_a     : e_spr_a;
assign pix_x       = sf ? s_pix_x : vic ? v_pix_x : cp ? p_pix_x : circus ? c_pix_x : e_pix_x;
assign pix_y       = sf ? s_pix_y : vic ? v_pix_y : cp ? p_pix_y : circus ? c_pix_y : e_pix_y;
assign pix_rgb     = circus ? c_pix_rgb   : e_pix_rgb;
assign vblank_raw  = sf ? s_vblank_raw : vic ? v_vblank_raw : cp ? p_vblank_raw : circus ? c_vblank_raw : e_vblank_raw;
assign hs_data_out = sf ? s_hs_dout : circus ? c_hs_dout : e_hs_dout;

/////////////////////////////  Audio / colour board  /////////////////////////////

wire         gen1    = (variant == 8'd5) || (variant == 8'd6);
wire         snd_rst = reset | gen1 | circus | sf | cp;   // gen-1, Circus, Star Fire, Car Polo: no 6502 sound board
logic signed [15:0] sndbd_audio, gen1_audio, circus_audio, sf_audio_l, sf_audio_r;
// discrete sound engine sources / outputs (engine block below)
logic [7:0]  g1_lat0, g1_lat1, sf_lat0, sf_lat1;
logic        g1_tone, g1_mus;
logic [2:0]  sf_pit;
logic [31:0] cp_snd;
logic        ds_sample;
logic signed [15:0] ds_l, ds_r;
logic        snd_ce, snd_rw, snd_irq_n;
logic [23:0] snd_a24;
logic  [7:0] snd_do, snd_di;

T65 snd_cpu
(
    .Mode(2'b00), .Res_n(~snd_rst), .Enable(snd_ce), .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1),
    .IRQ_n(snd_irq_n), .NMI_n(1'b1), .SO_n(1'b1), .R_W_n(snd_rw), .Sync(), .EF(), .MF(), .XF(), .ML_n(), .VP_n(),
    .VDA(), .VPA(), .A(snd_a24), .DI(snd_di), .DO(snd_do), .Regs(), .NMI_ack()
);

logic        z_cen_p, z_cen_n, z_reset_n;
logic  [7:0] z_do, z_di, snd_z_di, sf_z_di, v_z_di;
logic        z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_m1_n, sf_nmi_n;
logic        v_cen_p, v_cen_n, v_int_n, v_wait_n;

// one Z80: Mouse Trap's CVSD speech CPU, or the Star Fire / Fire One / Victory main CPU
T80pa #(.Mode(0)) speech_cpu
(
    // every enable source pauses at its origin (phase held), so CEN_p / CEN_n keep alternating across a pause
    .RESET_n((sf | vic) ? ~reset : z_reset_n), .CLK(clk),
    .CEN_p(sf ? sf_cen_p : vic ? v_cen_p : z_cen_p), .CEN_n(sf ? sf_cen_n : vic ? v_cen_n : z_cen_n),
    .WAIT_n(vic ? v_wait_n : 1'b1), .INT_n(vic ? v_int_n : 1'b1), .NMI_n(sf ? sf_nmi_n : 1'b1),
    .BUSRQ_n(1'b1), .M1_n(z_m1_n), .MREQ_n(z_mreq_n), .IORQ_n(z_iorq_n), .RD_n(z_rd_n), .WR_n(z_wr_n),
    .RFSH_n(), .HALT_n(), .BUSAK_n(), .OUT0(1'b0), .A(z_a), .DI(z_di), .DO(z_do),
    .R800_mode(1'b0), .REG(), .DIRSet(1'b0), .DIR(212'd0)
);

exidy_sndbd snd_b
(
    .clk(clk), .reset(snd_rst), .pause(pause), .cvsd_en(variant == 8'd1),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .main_ce(main_ce), .main_pia_cs(pia_cs), .main_rw(m_rw), .main_a(m_a[1:0]), .main_din(m_do), .main_dout(pia_dout),
    .snd_ce(snd_ce), .snd_a(snd_a24[15:0]), .snd_dout(snd_do), .snd_rw(snd_rw), .snd_din(snd_di), .snd_irq_n(snd_irq_n),
    .z80_cen_p(z_cen_p), .z80_cen_n(z_cen_n), .z80_reset_n(z_reset_n),
    .z_a(z_a), .z_dout(z_do), .z_mreq_n(z_mreq_n), .z_iorq_n(z_iorq_n), .z_rd_n(z_rd_n), .z_wr_n(z_wr_n), .z_m1_n(z_m1_n),
    .z_din(snd_z_di),
    .victory(vic), .vic_cmd_wr(v_snd_wr), .vic_cmd(z_do), .vic_resp_rd(v_snd_rd), .vic_resp(v_snd_resp),
    .vic_status(v_snd_status),
    .vol_music(vol_music), .vol_sfx(vol_sfx), .vol_speech(vol_speech),
    .z_rom_q(z_rom_q),          // REUSE-2026-10-26: Victory main ROM 8000-BFFF (was qrom1)
    // REUSE-2026-10-26: Star Fire's cram_e / cram_o banks in snd_rom / cvsd_rom (no sound 6502 / CVSD on Star Fire)
    .lend(sf), .lend_aa({2'b00, sf_pr_aa[47:36], 2'b00, sf_pr_aa[35:24]}), .lend_ad(sf_pr_ad[31:16]),
    .lend_aw(sf_pr_aw[3:2]), .lend_ba({2'b00, sf_pr_ba}), .lend_qa(sf_lend_qa), .lend_qb(sf_lend_qb),
    .audio(sndbd_audio)
);

// gen-1 audio board: decodes only A0 inside the 52xx page (5200 / 5201 latches)
exidy_gen1snd gen1_b
(
    .clk(clk), .reset(reset), .spectar(variant == 8'd6),
    .cpu_ce(main_ce), .wr(main_ce & ~m_rw & (m_a[15:8] == 8'h52) & ~m_a[4]), .a0(m_a[0]), .din(m_do),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .vol_music(vol_music), .vol_sfx(vol_sfx),
    .audio(gen1_audio), .lat0(g1_lat0), .lat1(g1_lat1), .tone(g1_tone), .mus(g1_mus)
);

// Circus-family audio board: static 74S138 levels from the 8000 latch; cfg2 [2:0] = game
circus_snd circus_s
(
    .clk(clk), .reset(reset), .game(board_cfg2[2:0]), .ce(main_ce),
    .latch(c_latch), .latch_wr(c_latch_wr),
    .vol_music(vol_music), .vol_sfx(vol_sfx),
    .audio(circus_audio)
);

assign z_di    = sf ? sf_z_di : vic ? v_z_di : snd_z_di;
// REUSE-2026-10-26: gen-1, Circus-family and Star Fire / Fire One sound is the discrete sound engine's program (every
// MRA of variants 5-9 / 11 carries index 5, which switches audio to the engine). Their analog RTL models were a second
// implementation that never played; with no fanout Quartus prunes them (~11k ALM, 6 DSP). Their digital fronts
// (g1_lat*/tone/mus, sf_lat*/sf_pit) still feed the engine. Original below, uncomment to restore the fallbacks:
// wire signed [15:0] brd_l = sf ? sf_audio_l : cp ? 16'sd0 : circus ? circus_audio : gen1 ? gen1_audio : sndbd_audio;
// wire signed [15:0] brd_r = sf ? sf_audio_r : brd_l;
wire signed [15:0] brd_l = (sf | cp | circus | gen1) ? 16'sd0 : sndbd_audio;
wire signed [15:0] brd_r = brd_l;
wire unused_fallback = &{1'b0, sf_audio_l, sf_audio_r, circus_audio, gen1_audio};
assign audio   = ds_on ? ds_l : brd_l;
assign audio_r = ds_on ? ds_r : brd_r;

/////////////////////////////  Discrete sound engine (MRA index 5)  /////////////////////////////
// One pooled engine runs the board's circuit program (tools/dsnd_boards.py); without a program the board's own
// sound RTL above plays. Sources 0-4 per board, 5 = OSD volumes, 6 / 7 = Game Audio caps.

// audio-rate digital outputs, box-averaged over one engine sample: count of enable cycles at 1
// (gen-1: tone flip-flop, MUSIC bit at phi2, 26 per sample; Circus family: music line at phi2;
//  Fire One: 8253 A / B / C at the Z80 enable, about 92)
wire        c_mus = (board_cfg2[2:0] == 3'd2) ? c_latch[3] : (c_latch[6:4] == 3'b001);   // Robot Bowl: D3
wire  [2:0] bx_in = gen1 ? {1'b0, g1_mus, g1_tone} : circus ? {2'b00, c_mus} : sf_pit;
wire        bx_ce = (gen1 | circus) ? main_ce : sf_cen_p;
logic [7:0] bx_acc [3] = '{8'd0, 8'd0, 8'd0}, bx_q [3] = '{8'd0, 8'd0, 8'd0};
always_ff @(posedge clk)
    for (int i = 0; i < 3; i++)
        if (ds_sample) begin
            bx_q[i]   <= bx_acc[i] + {7'd0, bx_ce & bx_in[i]};
            bx_acc[i] <= 8'd0;
        end
        else if (bx_ce) bx_acc[i] <= bx_acc[i] + {7'd0, bx_in[i]};

// Car Polo ball hit / score (PA7 / PA5) are microsecond low pulses; the board's 7407 + 100 pF edge trigger catches
// every one, so a low anywhere in a sample period is held for the next sample
logic [1:0] cp_bs_acc = 2'b00, cp_bs_q = 2'b00;
always_ff @(posedge clk)
    if (ds_sample) begin
        cp_bs_q   <= cp_bs_acc | ~cp_snd[7:6];
        cp_bs_acc <= 2'b00;
    end
    else cp_bs_acc <= cp_bs_acc | ~cp_snd[7:6];

logic [39:0] ds_board;
always_comb
    if (cp)          ds_board = {8'd0, cp_snd[31:8], ~cp_bs_q, cp_snd[5:0]};
    else if (gen1)   ds_board = {8'd0, bx_q[1], bx_q[0], g1_lat1, g1_lat0};
    else if (sf)     ds_board = {bx_q[2], bx_q[1], bx_q[0], sf_lat1, sf_lat0};
    else if (circus) ds_board = {24'd0, bx_q[0], c_latch};
    else             ds_board = 40'd0;

dsnd_engine dsnd
(
    .clk(clk), .reset(reset), .pause(pause),
    .prog_wr(ds_wr), .prog_addr(ds_addr), .prog_data(ds_data),
    .src({ds_caps, vol_music, vol_sfx, ds_board}),
    .out(ds_l), .out_r(ds_r), .sample(ds_sample)
);

/////////////////////////////  Star Fire / Fire One  /////////////////////////////

logic       sf_tie_n, sf_laser_n, sf_psel, sf_snd_wr, sf_snd_a0, sf_mus_wr;
logic [1:0] sf_mus_a;

starfire_main starfire_b
(
    .clk(clk), .reset(reset | ~sf), .pause(pause), .fireone(variant == 8'd9),
    .ce_pix(sf_ce_pix), .cen_p(sf_cen_p), .cen_n(sf_cen_n),
    .z_a(z_a), .z_do(z_do), .z_mreq_n(z_mreq_n), .z_rd_n(z_rd_n), .z_wr_n(z_wr_n), .z_di(sf_z_di), .z_nmi_n(sf_nmi_n),
    .rom_d(rom_d),
    .dsw(dsw), .sys_in(in0), .p1_in(in2), .p2_in(in3),
    .stick_x(stick_x), .stick_y(stick_y), .throttle(throttle), .pad1(pad1), .pad2(pad2),
    .tie_on_n(sf_tie_n), .laser_on_n(sf_laser_n), .player_sel(sf_psel),
    .snd_wr(sf_snd_wr), .snd_a0(sf_snd_a0), .music_wr(sf_mus_wr), .music_a(sf_mus_a),
    .pix_x(s_pix_x), .pix_y(s_pix_y), .pix_rgb(s_pix_rgb), .pix_pen(s_pix_pen),
    .pal_ri(fb_q[5:0]), .pal_rq(s_pal_rq), .vbl_raw(s_vblank_raw),
    .hs_a(hs_address), .hs_din(hs_data_in), .hs_dout(s_hs_dout), .hs_we(hs_write && sf),
    .pr_aa(sf_pr_aa), .pr_ad(sf_pr_ad), .pr_aw(sf_pr_aw), .pr_ba(sf_pr_ba), .pr_qa(sf_pr_qa), .pr_qb(sf_pr_qb)
);

starfire_snd starfire_s
(
    .clk(clk), .reset(reset | ~sf), .fireone(variant == 8'd9), .cpu_ce(sf_cen_p),
    .snd_wr(sf_snd_wr), .snd_a0(sf_snd_a0), .music_wr(sf_mus_wr), .music_a(sf_mus_a), .din(z_do),
    .tie_on_n(sf_tie_n), .laser_on_n(sf_laser_n), .player_sel(sf_psel),
    .vol_music(vol_music), .vol_sfx(vol_sfx),
    .audio_l(sf_audio_l), .audio_r(sf_audio_r), .lat0(sf_lat0), .lat1(sf_lat1), .pit_q(sf_pit)
);

/////////////////////////////  Victory  /////////////////////////////

victory_main victory_b
(
    .clk(clk), .reset(reset | ~vic), .pause(pause), .ce_pix(ce_exi), .cen_p(v_cen_p), .cen_n(v_cen_n),
    .z_a(z_a), .z_do(z_do), .z_mreq_n(z_mreq_n), .z_iorq_n(z_iorq_n), .z_rd_n(z_rd_n), .z_wr_n(z_wr_n), .z_m1_n(z_m1_n),
    .z_di(v_z_di), .z_int_n(v_int_n), .z_wait_n(v_wait_n),
    .rom_d(z_a[15] ? q1_d : rom_d),
    .fg_a_addr(v_fga_addr), .fg_a_d(v_fga_d), .fg_a_we(v_fga_we), .fg_a_q(v_fga_q),
    .fg_b_addr(v_fgb_addr), .fg_b_q(q0_d),
    .dsw(dsw), .buttons(in0), .coin(coin), .dial(dial),
    .snd_wr(v_snd_wr), .snd_rd(v_snd_rd), .snd_resp(v_snd_resp), .snd_status(v_snd_status),
    .pix_x(v_pix_x), .pix_y(v_pix_y), .pix_rgb(v_pix_rgb), .pix_pen(v_pix_pen),
    .pal_ri(fb_q[5:0]), .pal_rq(v_pal_rq), .vbl_raw(v_vblank_raw),
    .nv_wr(nv_wr), .nv_addr(ioctl_addr[10:0]), .nv_din(nv_din), .nv_dout(nv_dout),
    .nv_saved(nv_saved), .nv_dirty(nv_dirty)
);

/////////////////////////////  Car Polo  /////////////////////////////

carpolo_main carpolo_b
(
    .clk(clk), .reset(reset | ~cp), .ce_pix(ce_exi), .cpu_ce(cp_ce),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .cpu_a(m_a), .cpu_do(m_do), .cpu_rw(m_rw), .cpu_di(p_di), .cpu_irq_n(p_irq_n), .rom_d(rom_d),
    .spr_a(p_spr_a), .spr_d(spr_d),
    .in0(in0), .dsw(dsw), .in2(in2), .pedals(intsrc), .dial1(dial), .dial2(dial2), .dial3(dial3), .dial4(dial4),
    .pix_x(p_pix_x), .pix_y(p_pix_y), .pix_idx(p_pix_idx), .pix_rgb(p_pix_rgb),
    .pal_ri(fb_q[4:0]), .pal_rq(p_pal_rq), .vbl_raw(p_vblank_raw), .snd(cp_snd)
);

/////////////////////////////  CRT Flip + video out  /////////////////////////////

// The objects are position counters running with the beam, so the picture is not mirrored by remapping:
// the visible 256 x 256 frame is double-buffered and, with CRT Flip on, read back from the opposite corner
// (one frame of delay, flipped only).
logic       wbuf = 1'b0;
wire        pix_vis = (pix_x < 9'd256) && (pix_y < 9'd256);
wire [16:0] fb_wa = {wbuf, pix_y[7:0], pix_x[7:0]};
// Circus family: MAME's 248-px window (H 8-255) mirrors onto itself; Star Fire: lines 32-255; Car Polo: its 240-px
// window (H 0-239) mirrors onto itself (FLIP-2026-10-26: was 255 - x, a 180 turn shifted 16 px, board sim).
// Original: wire [16:0] fb_ra = {~wbuf, (sf ? 8'd31 : 8'd255) - pix_y[7:0], (circus ? 8'd7 : 8'd255) - pix_x[7:0]};
wire [16:0] fb_ra = {~wbuf, (sf ? 8'd31 : 8'd255) - pix_y[7:0], (circus ? 8'd7 : cp ? 8'd239 : 8'd255) - pix_x[7:0]};

always_ff @(posedge clk)
    if (ce_pix && pix_x == 9'd0 && pix_y == 9'd256) wbuf <= ~wbuf;

dpram_dc #(.widthad_a(17)) flip_fb
(
    .clock_a(clk), .address_a(fb_wa),
    .data_a(sf ? {2'd0, s_pix_pen} : vic ? {2'd0, v_pix_pen} : cp ? {3'd0, p_pix_idx} : {5'd0, pix_rgb}),
    .wren_a(!reset && ce_d && pix_vis),
    .clock_b(clk), .address_b(fb_ra), .q_b(fb_q)
);

// output stage: one more pixel register; blanking / sync derived from the same pixel coordinates
// 9-bit colour: 6502 boards replicate their 1-bit guns, Star Fire / Victory use their palettes
logic [2:0]  rgb_o;
logic [8:0]  rgb9_o;
logic [23:0] rgb24_o;
logic [8:0] ox, oy;
always_ff @(posedge clk) begin
    if (ce_pix) begin
        rgb_o  <= (crt_flip && pix_vis) ? fb_q[2:0] : pix_rgb;
        rgb9_o <= sf  ? ((crt_flip && pix_vis) ? s_pal_rq : s_pix_rgb) :
                  vic ? ((crt_flip && pix_vis) ? v_pal_rq : v_pix_rgb) : 9'd0;
        rgb24_o <= (crt_flip && pix_vis) ? p_pal_rq : p_pix_rgb;
        ox     <= pix_x;
        oy     <= pix_y;
    end
end

// sync: 6502 boards H 0x120-0x13F (of 336), lines 256-263 (of 280). Star Fire (320 x 262): schematic HSYNC at
// H 0x1D8 (pixel 280; drawn 8 px wide, kept 24 for CRT lock), VSYNC 17 lines into blanking = line 11, 4 lines
wire [8:0] hs_beg = (sf ? 9'd280 : 9'h120) + {{5{h_adj[3]}}, h_adj};
wire [8:0] hs_len = sf ? 9'd24 : 9'd32;
wire [8:0] vs_beg = (sf ? 9'd11 : 9'd256) + {{5{v_adj[3]}}, v_adj};
wire [8:0] vs_len = sf ? 9'd4 : 9'd8;

// Circus family: monochrome monitor under a coloured overlay (MAME circus.lay / crash.lay / crasha.lay),
// board config 2 [5:4] = 1 Circus, 2 Crash, 3 Crash set 2; playfield x = H - 8
wire  [7:0] px = ox[7:0] - 8'd8;
logic [23:0] tint;
always_comb begin
    tint = 24'hFFFFFF;
    case (board_cfg2[5:4])
        2'd1: if      (oy >= 9'd20 && oy < 9'd36) tint = 24'h36A5E9;
              else if (oy >= 9'd36 && oy < 9'd49) tint = 24'h52FF52;
              else if (oy >= 9'd49 && oy < 9'd65) tint = 24'hFFFF52;
        2'd2: tint = (px >= 8'd87 && px < 8'd160 && oy >= 9'd86 && oy < 9'd169) ? 24'h66FF99 : 24'h66F2FF;
        2'd3: tint = (px >= 8'd81 && px < 8'd167 && oy >= 9'd88 && oy < 9'd167) ? 24'h66FF99 : 24'h66F2FF;
        default: ;
    endcase
end
wire use_tint = circus && overlay_en;

assign video_r      = cp ? rgb24_o[23:16] : pal9 ? {rgb9_o[8:6], rgb9_o[8:6], rgb9_o[8:7]} :
                      use_tint ? (rgb_o[2] ? tint[23:16] : 8'd0) : {8{rgb_o[2]}};
assign video_g      = cp ? rgb24_o[15:8] : pal9 ? {rgb9_o[5:3], rgb9_o[5:3], rgb9_o[5:4]} :
                      use_tint ? (rgb_o[1] ? tint[15:8]  : 8'd0) : {8{rgb_o[1]}};
assign video_b      = cp ? rgb24_o[7:0] : pal9 ? {rgb9_o[2:0], rgb9_o[2:0], rgb9_o[2:1]} :
                      use_tint ? (rgb_o[0] ? tint[7:0]   : 8'd0) : {8{rgb_o[0]}};
assign video_hblank = (ox >= 9'd256) || (circus && ox < 9'd8) || (cp && ox >= 9'd240);
assign video_vblank = (oy >= 9'd256) || (sf && oy < 9'd32);
assign video_hs     = (ox >= hs_beg) && (ox < hs_beg + hs_len);
assign video_vs     = (oy >= vs_beg) && (oy < vs_beg + vs_len);

endmodule

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
//    3: Teeter Torture (Venture + dial on IN0 bits 2 / 6 + 600 Hz NMI)
//    4: Fax (Pepper II + question ROM banks; the map is board config bit 6)
//    5: gen-1 board + Targ audio board (targ, targc)
//    6: gen-1 board + Spectar-type audio board (spectar, sidetrac, rallys, panzer, phantoma)
//    7: Circus-family board (rtl/boards/exidy_circus: circus, trapeze, robotbwl, ripcord, crash)
//    8: Star Fire, 9: Fire One (rtl/boards/exidy_starfire: Z80 = the pooled T80pa, bitmap video)
//   10: Victory (rtl/boards/exidy_victory: Z80 = the pooled T80pa, microcode video; Fax's question-ROM BRAMs
//       hold its foreground planes and ROM 8000-BFFF; Venture sound board in Victory mode)
//   11: Car Polo (rtl/boards/exidy_carpolo: main 6502 at 940.75 kHz, collision checker)
//  Gen-1 map options are board config 2 (index 1 byte 2), see exidy_main.sv.
//  Board config bits (index 1 byte 3) are documented in rtl/boards/exidy6502/exidy_main.sv.
//
//  ioctl index 0 (MRA), ROM regions:
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

module exidy_dispatcher
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
    input  logic        overlay_en,     // Circus family cabinet colour overlay (layouts)
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

// The boards' ROMs. Load decode by index-0 address only (never by variant: index 1 arrives after the ROMs); two boards
// that load the same window share a block.
//   rom_cp0,  2K at 0x15800: Circus-family character PROM (port B) | Car Polo goal ROM, first 256 B (ports A and B)
//   rom_cp1,  1K at 0x16000: Circus-family line PROMs 4D / 5D (port B) | Car Polo alphanumeric ROM, first 512 B (port A)
//   rom_snd, 16K at 0x0C000: sound board 6502 ROM (CPU 4000-7FFF)
//   rom_cvsd, 16K at 0x10000: Mouse Trap CVSD Z80 ROM; also 0x40000: Victory main ROM 8000-BFFF (same pooled Z80)
logic [10:0] c_chr_a;
logic  [9:0] c_lp_a;
logic  [7:0] p_goal_sa, p_goal_ca;
logic  [8:0] p_alpha_a;
logic [13:0] sb_snd_rom_a, sb_cvsd_rom_a;
logic  [7:0] rom_cp0_qa, rom_cp0_qb, rom_cp1_qa, rom_cp1_qb, rom_snd_q, rom_cvsd_q;
wire load_cp0  = ioctl_wr0 && ioctl_addr[24:11] == 14'h2B;                            // 0x15800-0x15FFF
wire load_cp1  = ioctl_wr0 && ioctl_addr[24:10] == 15'h58;                            // 0x16000-0x163FF
wire load_snd  = ioctl_wr0 && ioctl_addr[24:14] == 11'd3;                             // 0x0C000-0x0FFFF
wire load_cvsd = ioctl_wr0 && (ioctl_addr[24:14] == 11'd4 || ioctl_addr[24:14] == 11'h010);   // 0x10000 / 0x40000

dpram_dc #(.widthad_a(11)) rom_cp0
(
    .clock_a(clk), .address_a(ioctl_wr0 ? ioctl_addr[10:0] : {3'd0, p_goal_sa}), .data_a(ioctl_dout), .wren_a(load_cp0),
    .q_a(rom_cp0_qa),
    .clock_b(clk), .address_b(cp ? {3'd0, p_goal_ca} : c_chr_a), .data_b(8'h00), .wren_b(1'b0), .q_b(rom_cp0_qb)
);
dpram_dc #(.widthad_a(10)) rom_cp1
(
    .clock_a(clk), .address_a(ioctl_wr0 ? ioctl_addr[9:0] : {1'b0, p_alpha_a}), .data_a(ioctl_dout), .wren_a(load_cp1),
    .q_a(rom_cp1_qa),
    .clock_b(clk), .address_b(c_lp_a), .data_b(8'h00), .wren_b(1'b0), .q_b(rom_cp1_qb)
);
dpram_dc #(.widthad_a(14)) rom_snd
(
    .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(load_snd), .q_a(),
    .clock_b(clk), .address_b(sb_snd_rom_a), .data_b(8'h00), .wren_b(1'b0), .q_b(rom_snd_q)
);
dpram_dc #(.widthad_a(14)) rom_cvsd
(
    .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(load_cvsd), .q_a(),
    .clock_b(clk), .address_b(sb_cvsd_rom_a), .data_b(8'h00), .wren_b(1'b0), .q_b(rom_cvsd_q)
);

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////
// chip_pool_pkg buses. Every CPU / sound engine exists once, here; the boards keep their own signal names
// (m_*, snd_*, z_*), which drive / read these buses.

// t65_0: main 6502 (Venture / Pepper II / Mouse Trap / Teeter / Fax logic boards, gen-1, Circus family, Car Polo)
logic  [7:0] m_do, m_di;
logic        m_rw, m_irq_n, m_sync, m_nmi_n;
chip_pool_pkg::t65_i_t t65_0_i;
chip_pool_pkg::t65_o_t t65_0_o;
logic [23:0] t65_0_a24;
assign t65_0_i.res_n  = ~(reset | sf | vic);
assign t65_0_i.enable = cp ? cp_ce : cpu_ce;
assign t65_0_i.rdy    = 1'b1;
assign t65_0_i.irq_n  = m_irq_n;
assign t65_0_i.nmi_n  = m_nmi_n;
assign t65_0_i.di     = m_di;
T65 t65_0
(
    .Mode(2'b00), .Res_n(t65_0_i.res_n), .Enable(t65_0_i.enable), .Clk(clk), .Rdy(t65_0_i.rdy), .Abort_n(1'b1),
    .IRQ_n(t65_0_i.irq_n), .NMI_n(t65_0_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_0_o.rw), .Sync(m_sync),  // Sync: harness probe
    .EF(), .MF(), .XF(), .ML_n(), .VP_n(), .VDA(), .VPA(), .A(t65_0_a24), .DI(t65_0_i.di), .DO(t65_0_o.dout), .Regs(),
    .NMI_ack()
);
assign t65_0_o.a = t65_0_a24[15:0];
assign m_a  = t65_0_o.a;
assign m_do = t65_0_o.dout;
assign m_rw = t65_0_o.rw;

// Sound chips. Each board drives its own bus (its own reset on rst); the variant picks the owner:
//   pia6821[0] / [1]: Venture-type sound board main-side / sound-side PIA (variants 0-4, 10) | Car Polo pia0 / pia1 (11)
//   pit8253_0:        sound board music 8253 | Fire One music 8253 (variants 8 / 9; Star Fire leaves it idle)
//   riot6532_0, ptm6840_0, mc3417_0, tms5220rsws_0: Venture-type sound board only
// (The sound board is held in reset on gen-1 / Circus / Star Fire / Car Polo, so its slots are free there.)
chip_pool_pkg::pia6821_i_t [1:0] sb_pia6821_i, cp_pia6821_i, pia6821_i;
chip_pool_pkg::pia6821_o_t [1:0] pia6821_o;
chip_pool_pkg::pit8253_i_t       sb_pit8253_i, sf_pit8253_i, pit8253_0_i;
chip_pool_pkg::pit8253_o_t       pit8253_0_o;
chip_pool_pkg::riot6532_i_t      riot6532_0_i;
chip_pool_pkg::riot6532_o_t      riot6532_0_o;
chip_pool_pkg::ptm6840_i_t       ptm6840_0_i;
chip_pool_pkg::ptm6840_o_t       ptm6840_0_o;
chip_pool_pkg::mc3417_i_t        mc3417_0_i;
chip_pool_pkg::mc3417_o_t        mc3417_0_o;
chip_pool_pkg::tms5220rsws_i_t   tms5220rsws_0_i;
chip_pool_pkg::tms5220rsws_o_t   tms5220rsws_0_o;
assign pia6821_i   = cp ? cp_pia6821_i : sb_pia6821_i;
assign pit8253_0_i = sf ? sf_pit8253_i : sb_pit8253_i;

genvar pi;
generate
    for (pi = 0; pi < 2; pi++) begin : g_pia6821
        pia6821 u
        (
            .clk(clk), .rst(pia6821_i[pi].rst), .ce(pia6821_i[pi].ce), .cs(pia6821_i[pi].cs), .rw(pia6821_i[pi].rw),
            .rs(pia6821_i[pi].rs), .din(pia6821_i[pi].din), .dout(pia6821_o[pi].dout),
            .irqa(pia6821_o[pi].irqa), .irqb(pia6821_o[pi].irqb),
            .pa_i(pia6821_i[pi].pa_i), .pa_o(pia6821_o[pi].pa_o), .pa_oe(pia6821_o[pi].pa_oe),
            .ca1(pia6821_i[pi].ca1), .ca2_i(pia6821_i[pi].ca2_i), .ca2_o(pia6821_o[pi].ca2_o), .ca2_oe(pia6821_o[pi].ca2_oe),
            .pb_i(pia6821_i[pi].pb_i), .pb_o(pia6821_o[pi].pb_o), .pb_oe(pia6821_o[pi].pb_oe),
            .cb1(pia6821_i[pi].cb1), .cb2_i(pia6821_i[pi].cb2_i), .cb2_o(pia6821_o[pi].cb2_o), .cb2_oe(pia6821_o[pi].cb2_oe)
        );
    end
endgenerate

pit8253 pit8253_0
(
    .clk(clk), .rst(pit8253_0_i.rst), .wr_en(pit8253_0_i.wr_en), .a(pit8253_0_i.a), .din(pit8253_0_i.din),
    .clk_ce(pit8253_0_i.clk_ce), .gate(pit8253_0_i.gate), .out(pit8253_0_o.out)
);

riot6532 riot6532_0
(
    .clk(clk), .rst(riot6532_0_i.rst), .ce(riot6532_0_i.ce), .ram_cs(riot6532_0_i.ram_cs), .io_cs(riot6532_0_i.io_cs),
    .rw(riot6532_0_i.rw), .a(riot6532_0_i.a), .din(riot6532_0_i.din), .dout(riot6532_0_o.dout), .irq(riot6532_0_o.irq),
    .pa_i(riot6532_0_i.pa_i), .pa_pins(riot6532_0_o.pa_pins), .pb_i(riot6532_0_i.pb_i), .pb_pins(riot6532_0_o.pb_pins)
);

ptm6840 ptm6840_0
(
    .clk(clk), .rst(ptm6840_0_i.rst), .ce(ptm6840_0_i.ce), .cs(ptm6840_0_i.cs), .rw(ptm6840_0_i.rw), .rs(ptm6840_0_i.rs),
    .din(ptm6840_0_i.din), .dout(ptm6840_0_o.dout), .cx(ptm6840_0_i.cx), .o(ptm6840_0_o.o), .irq(ptm6840_0_o.irq)
);

logic signed [23:0] mc3417_0_integ;
mc3417 mc3417_0
(
    .clk(clk), .rst(mc3417_0_i.rst), .bclk(mc3417_0_i.bclk), .din(mc3417_0_i.din), .integ(mc3417_0_integ)
);
assign mc3417_0_o.integ = mc3417_0_integ;

logic signed [15:0] tms5220rsws_0_audio;
tms5220_rsws #(.CLK_HZ(22578000), .TMS_HZ(640000)) tms5220rsws_0
(
    .clk(clk), .reset(tms5220rsws_0_i.reset), .pause(tms5220rsws_0_i.pause),
    .rs_n(tms5220rsws_0_i.rs_n), .ws_n(tms5220rsws_0_i.ws_n), .d_in(tms5220rsws_0_i.d_in), .d_out(tms5220rsws_0_o.d_out),
    .ready_n(tms5220rsws_0_o.ready_n), .int_n(tms5220rsws_0_o.int_n), .audio(tms5220rsws_0_audio)
);
assign tms5220rsws_0_o.audio = tms5220rsws_0_audio;

/////////////////////////////  Teeter Torture: NMI + dial  /////////////////////////////

// NMI pulse at 10 * 60 Hz #unverified (prototype, no schematic)
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

// The Fax question ROMs (index 0 0x20000-0x4FFFF) are read from the DDR3 copy of index 0.
logic [17:0] qrom_a;
logic  [7:0] qrom_d, q0_d, q1_d;
wire load_q1 = ioctl_wr0 && ioctl_addr[24:14] == 11'h010; // 0x40000-0x43FFF: Victory main ROM

// Victory: qrom0 = foreground planes (port A engine, port B scan; addresses {0, plane, 14 bits}), qrom1 = main ROM 8000-BFFF
// The three planes need 48K (plane index is 0-2 on both ports, A15-A14 never 11): 32K (R, G) + 16K (B), read data
// muxed by the bank bit registered with the address (dpram_dc: registered address, unregistered q).
logic       fga_hi = 1'b0, fgb_hi = 1'b0;
always_ff @(posedge clk) begin
    fga_hi <= v_fga_addr[15];
    fgb_hi <= v_fgb_addr[15];
end

/////////////////////////////  Shared RAM pool  /////////////////////////////
// Only one board runs at a time (plus the sound board with its logic board), so the boards' RAMs
// share six true dual-port blocks (rtl/ram_pool_pkg.sv; two read / write ports each, one clock to q as dpram_dc).
// Each block is sized to its largest user; the owner is picked by variant.
//   block 0, 32K: Victory foreground planes R / G (addr bit 15 = 0)   | Star Fire vram_e
//   block 1, 16K: Victory foreground plane B (addr bit 15 = 1)         | Star Fire vram_o
//   block 2,  8K: Victory char RAM | Star Fire cram_e | logic-board char plane 0 (its index-0 preload always wins)
//   block 3,  8K: Victory work / CMOS RAM | Star Fire cram_o | logic-board char plane 1
//   block 4,  2K: Victory tile RAM | Car Polo work RAM | logic-board work RAM (port B = hiscore)
//   block 5,  1K: Victory sound-board RAM 0080-00FF | Circus screen RAM | Car Polo alpha RAM | logic-board screen RAM
// Not pooled: Circus work RAM (POOL-EXCEPTION in circus_main.sv: power-on fill before the variant is known).
localparam RAM_BLOCKS = 6;
ram_pool_pkg::pram_i_t [RAM_BLOCKS-1:0] e_pr_i, c_pr_i, sf_pr_i, vic_pr_i, cp_pr_i, sb_pr_i, vpl_pr_i, pool_i;
ram_pool_pkg::pram_o_t [RAM_BLOCKS-1:0] pool_o;
logic e_cram_load;

// Victory foreground planes: 48K over blocks 0 / 1, read data muxed by the bank bit registered with the address
assign vpl_pr_i[0].a_addr = v_fga_addr[14:0];
assign vpl_pr_i[0].a_d    = v_fga_d;
assign vpl_pr_i[0].a_we   = vic & v_fga_we & ~v_fga_addr[15];
assign vpl_pr_i[0].b_addr = v_fgb_addr[14:0];
assign vpl_pr_i[0].b_d    = 8'h00;
assign vpl_pr_i[0].b_we   = 1'b0;
assign vpl_pr_i[1].a_addr = {1'b0, v_fga_addr[13:0]};
assign vpl_pr_i[1].a_d    = v_fga_d;
assign vpl_pr_i[1].a_we   = vic & v_fga_we & v_fga_addr[15];
assign vpl_pr_i[1].b_addr = {1'b0, v_fgb_addr[13:0]};
assign vpl_pr_i[1].b_d    = 8'h00;
assign vpl_pr_i[1].b_we   = 1'b0;
assign vpl_pr_i[5:2] = '0;
assign v_fga_q = fga_hi ? pool_o[1].a_q : pool_o[0].a_q;
assign q0_d    = fgb_hi ? pool_o[1].b_q : pool_o[0].b_q;

assign pool_i[0] = sf ? sf_pr_i[0] : vpl_pr_i[0];
assign pool_i[1] = sf ? sf_pr_i[1] : vpl_pr_i[1];
assign pool_i[2] = e_cram_load ? e_pr_i[2] : sf ? sf_pr_i[2] : vic ? vic_pr_i[2] : e_pr_i[2];
assign pool_i[3] = sf ? sf_pr_i[3] : vic ? vic_pr_i[3] : e_pr_i[3];
assign pool_i[4] = vic ? vic_pr_i[4] : cp ? cp_pr_i[4] : e_pr_i[4];
assign pool_i[5] = vic ? sb_pr_i[5] : circus ? c_pr_i[5] : cp ? cp_pr_i[5] : e_pr_i[5];

genvar rp;
generate
    for (rp = 0; rp < RAM_BLOCKS; rp++) begin : rpool
        localparam int AW = (rp == 0) ? 15 : (rp == 1) ? 14 : (rp < 4) ? 13 : (rp == 4) ? 11 : 10;
        dpram_dc #(.widthad_a(AW)) ram
        (
            .clock_a(clk), .address_a(pool_i[rp].a_addr[AW-1:0]), .data_a(pool_i[rp].a_d), .wren_a(pool_i[rp].a_we),
            .q_a(pool_o[rp].a_q),
            .clock_b(clk), .address_b(pool_i[rp].b_addr[AW-1:0]), .data_b(pool_i[rp].b_d), .wren_b(pool_i[rp].b_we),
            .q_b(pool_o[rp].b_q)
        );
    end
endgenerate

// Victory's main ROM 8000-BFFF lives in the sound board's cvsd_rom (same pooled Z80, same z_a[13:0] port; Victory has no CVSD).
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
    .hs_we(hs_write && hs_address[15:10] == 6'd0 && !circus),
    .pr_i(e_pr_i), .pr_o(pool_o), .cram_load(e_cram_load)
);

/////////////////////////////  Circus-family logic board  /////////////////////////////

logic [7:0] c_latch;
logic       c_latch_wr;

circus_main circus_b
(
    .clk(clk), .reset(reset), .ph(ph), .ce_pix(ce_exi), .cfg(board_cfg),
    .cpu_ce(main_ce), .cpu_a(m_a), .cpu_do(m_do), .cpu_rw(m_rw), .cpu_di(c_di), .cpu_irq_n(c_irq_n),
    .rom_d(rom_d), .spr_a(c_spr_a), .spr_d(spr_d),
    .in0(in0), .dsw(dsw), .paddle(paddle),
    .out_latch(c_latch), .out_wr(c_latch_wr),
    .pix_x(c_pix_x), .pix_y(c_pix_y), .pix_rgb(c_pix_rgb), .vbl_irq_raw(c_vblank_raw),
    .hs_a(hs_address[9:0]), .hs_din(hs_data_in), .hs_dout(c_hs_dout),
    .hs_we(hs_write && hs_address[15:10] == 6'd0 && circus),
    .pr_i(c_pr_i), .pr_o(pool_o),
    .chr_rom_a(c_chr_a), .chr_rom_q(rom_cp0_qb), .lp_rom_a(c_lp_a), .lp_rom_q(rom_cp1_qb)
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

// pool slot t65_1 (sound board 6502: Venture-type sound board, variants 0-4 / 10)
chip_pool_pkg::t65_i_t t65_1_i;
chip_pool_pkg::t65_o_t t65_1_o;
assign t65_1_i.res_n  = ~snd_rst;
assign t65_1_i.enable = snd_ce;
assign t65_1_i.rdy    = 1'b1;
assign t65_1_i.irq_n  = snd_irq_n;
assign t65_1_i.nmi_n  = 1'b1;
assign t65_1_i.di     = snd_di;
T65 t65_1
(
    .Mode(2'b00), .Res_n(t65_1_i.res_n), .Enable(t65_1_i.enable), .Clk(clk), .Rdy(t65_1_i.rdy), .Abort_n(1'b1),
    .IRQ_n(t65_1_i.irq_n), .NMI_n(t65_1_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_1_o.rw), .Sync(), .EF(), .MF(), .XF(),
    .ML_n(), .VP_n(), .VDA(), .VPA(), .A(snd_a24), .DI(t65_1_i.di), .DO(t65_1_o.dout), .Regs(), .NMI_ack()
);
assign t65_1_o.a = snd_a24[15:0];
assign snd_do    = t65_1_o.dout;
assign snd_rw    = t65_1_o.rw;

logic        z_cen_p, z_cen_n, z_reset_n;
logic  [7:0] z_do, z_di, snd_z_di, sf_z_di, v_z_di;
logic        z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_m1_n, sf_nmi_n;
logic        v_cen_p, v_cen_n, v_int_n, v_wait_n;

// one Z80: Mouse Trap's CVSD speech CPU, or the Star Fire / Fire One / Victory main CPU
// pool slot z80pa_0 (master z80pa type)
chip_pool_pkg::z80pa_i_t z80pa_0_i;
chip_pool_pkg::z80pa_o_t z80pa_0_o;
// every enable source pauses at its origin (phase held), so CEN_p / CEN_n keep alternating across a pause
assign z80pa_0_i.reset_n = (sf | vic) ? ~reset : z_reset_n;
assign z80pa_0_i.cen_p   = sf ? sf_cen_p : vic ? v_cen_p : z_cen_p;
assign z80pa_0_i.cen_n   = sf ? sf_cen_n : vic ? v_cen_n : z_cen_n;
assign z80pa_0_i.wait_n  = vic ? v_wait_n : 1'b1;
assign z80pa_0_i.int_n   = vic ? v_int_n : 1'b1;
assign z80pa_0_i.nmi_n   = sf ? sf_nmi_n : 1'b1;
assign z80pa_0_i.di      = z_di;
T80pa #(.Mode(0)) z80pa_0
(
    .RESET_n(z80pa_0_i.reset_n), .CLK(clk), .CEN_p(z80pa_0_i.cen_p), .CEN_n(z80pa_0_i.cen_n),
    .WAIT_n(z80pa_0_i.wait_n), .INT_n(z80pa_0_i.int_n), .NMI_n(z80pa_0_i.nmi_n),
    .BUSRQ_n(1'b1), .M1_n(z80pa_0_o.m1_n), .MREQ_n(z80pa_0_o.mreq_n), .IORQ_n(z80pa_0_o.iorq_n), .RD_n(z80pa_0_o.rd_n),
    .WR_n(z80pa_0_o.wr_n), .RFSH_n(z80pa_0_o.rfsh_n), .HALT_n(), .BUSAK_n(), .OUT0(1'b0), .A(z80pa_0_o.a),
    .DI(z80pa_0_i.di), .DO(z80pa_0_o.dout), .R800_mode(1'b0), .REG(), .DIRSet(1'b0), .DIR(212'd0)
);
assign z_a      = z80pa_0_o.a;
assign z_do     = z80pa_0_o.dout;
assign z_m1_n   = z80pa_0_o.m1_n;
assign z_mreq_n = z80pa_0_o.mreq_n;
assign z_iorq_n = z80pa_0_o.iorq_n;
assign z_rd_n   = z80pa_0_o.rd_n;
assign z_wr_n   = z80pa_0_o.wr_n;

exidy_sndbd snd_b
(
    .clk(clk), .reset(snd_rst), .pause(pause), .cvsd_en(variant == 8'd1),
    .main_ce(main_ce), .main_pia_cs(pia_cs), .main_rw(m_rw), .main_a(m_a[1:0]), .main_din(m_do), .main_dout(pia_dout),
    .snd_ce(snd_ce), .snd_a(t65_1_o.a), .snd_dout(snd_do), .snd_rw(snd_rw), .snd_din(snd_di), .snd_irq_n(snd_irq_n),
    .z80_cen_p(z_cen_p), .z80_cen_n(z_cen_n), .z80_reset_n(z_reset_n),
    .z_a(z_a), .z_dout(z_do), .z_mreq_n(z_mreq_n), .z_iorq_n(z_iorq_n), .z_rd_n(z_rd_n), .z_wr_n(z_wr_n), .z_m1_n(z_m1_n),
    .z_din(snd_z_di),
    .victory(vic), .vic_cmd_wr(v_snd_wr), .vic_cmd(z_do), .vic_resp_rd(v_snd_rd), .vic_resp(v_snd_resp),
    .vic_status(v_snd_status),
    .vol_music(vol_music), .vol_sfx(vol_sfx), .vol_speech(vol_speech),
    .z_rom_q(z_rom_q),          // Victory main ROM 8000-BFFF
    .pr_i(sb_pr_i), .pr_o(pool_o),
    .snd_rom_a(sb_snd_rom_a), .snd_rom_q(rom_snd_q), .cvsd_rom_a(sb_cvsd_rom_a), .cvsd_rom_q(rom_cvsd_q),
    // the board's chips are the pool above
    .pia6821_i(sb_pia6821_i), .pia6821_o(pia6821_o), .pit8253_i(sb_pit8253_i), .pit8253_o(pit8253_0_o),
    .riot6532_i(riot6532_0_i), .riot6532_o(riot6532_0_o), .ptm6840_i(ptm6840_0_i), .ptm6840_o(ptm6840_0_o),
    .mc3417_i(mc3417_0_i), .mc3417_o(mc3417_0_o), .tms5220rsws_i(tms5220rsws_0_i), .tms5220rsws_o(tms5220rsws_0_o),
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
// gen-1, Circus-family and Star Fire / Fire One sound is the discrete sound engine's program (every MRA of variants 5-9 / 11
// carries index 5, which switches audio to the engine); the board audio is zero for them. Their digital fronts
// (g1_lat*/tone/mus, sf_lat*/sf_pit) feed the engine.
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

// pool slot dsnd_0 (gen-1, Circus family, Star Fire / Fire One, Car Polo)
// DSNDMERGE-2026-10-27: original below (dsndlr folded into dsnd)
// chip_pool_pkg::dsndlr_i_t dsnd_0_i;
// chip_pool_pkg::dsndlr_o_t dsnd_0_o;
chip_pool_pkg::dsnd_i_t dsnd_0_i;
chip_pool_pkg::dsnd_o_t dsnd_0_o;
assign dsnd_0_i.src = {ds_caps, vol_music, vol_sfx, ds_board};
dsnd_engine dsnd_0
(
    .clk(clk), .reset(reset), .pause(pause),
    .prog_wr(ds_wr), .prog_addr(ds_addr), .prog_data(ds_data),
    .src(dsnd_0_i.src),
    .out(dsnd_0_o.out), .out_r(dsnd_0_o.out_r), .sample(dsnd_0_o.sample)
);
assign ds_l      = dsnd_0_o.out;
assign ds_r      = dsnd_0_o.out_r;
assign ds_sample = dsnd_0_o.sample;

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
    .pr_i(sf_pr_i), .pr_o(pool_o)
);

starfire_snd starfire_s
(
    .clk(clk), .reset(reset | ~sf), .fireone(variant == 8'd9), .cpu_ce(sf_cen_p),
    .snd_wr(sf_snd_wr), .snd_a0(sf_snd_a0), .music_wr(sf_mus_wr), .music_a(sf_mus_a), .din(z_do),
    .tie_on_n(sf_tie_n), .laser_on_n(sf_laser_n), .player_sel(sf_psel),
    .vol_music(vol_music), .vol_sfx(vol_sfx),
    .audio_l(sf_audio_l), .audio_r(sf_audio_r), .lat0(sf_lat0), .lat1(sf_lat1), .pit_q(sf_pit),
    .pit8253_i(sf_pit8253_i), .pit8253_o(pit8253_0_o)          // pool slot pit8253_0
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
    .nv_saved(nv_saved), .nv_dirty(nv_dirty),
    .pr_i(vic_pr_i), .pr_o(pool_o)
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
    .pal_ri(fb_q[4:0]), .pal_rq(p_pal_rq), .vbl_raw(p_vblank_raw), .snd(cp_snd),
    .pia6821_i(cp_pia6821_i), .pia6821_o(pia6821_o),           // pool slots pia6821[0] / [1]
    .pr_i(cp_pr_i), .pr_o(pool_o),
    .goal_rom_sa(p_goal_sa), .goal_rom_sq(rom_cp0_qa), .goal_rom_ca(p_goal_ca), .goal_rom_cq(rom_cp0_qb),
    .alpha_rom_a(p_alpha_a), .alpha_rom_q(rom_cp1_qa)
);

/////////////////////////////  CRT Flip + video out  /////////////////////////////

// The objects are position counters running with the beam, so the picture is not mirrored by remapping:
// the visible 256 x 256 frame is double-buffered and, with CRT Flip on, read back from the opposite corner
// (one frame of delay, flipped only).
logic       wbuf = 1'b0;
wire        pix_vis = (pix_x < 9'd256) && (pix_y < 9'd256);
wire [16:0] fb_wa = {wbuf, pix_y[7:0], pix_x[7:0]};
// Circus family: the 248-px window (H 8-255) mirrors onto itself; Star Fire: lines 32-255; Car Polo: its 240-px
// window (H 0-239) mirrors onto itself.
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

// Circus family: monochrome monitor under a coloured overlay,
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

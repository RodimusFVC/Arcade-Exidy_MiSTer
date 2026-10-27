// ============================================================================
// exidy_sndbd.sv — Exidy Venture-type Audio/Color board, sound section
//   Venture / Pepper II (77-3387 / 77-0007) and Mouse Trap (177-3392, + Z80/MC3417 CVSD)
//   Victory (victory = 1): Victory sound map, F800/F801 command link, TMS5220 on the RIOT.
// Sources: the schematics (schematic = target), MAME exidysound.cpp (fallback).
//
// Sound 6502 map (74LS154 on A14-A11, A15 undecoded):
//   0000-07FF RIOT RAM (A0-A6; Mouse Trap: only with A7=0, A7=1 = unfitted /EXRAM -> open bus)
//   0800-0FFF RIOT I/O       1000-17FF sound PIA (A1:A0)     1800-1FFF 8253 (write only)
//   2000-27FF filter latch   2800-2FFF 6840 (A2:A0)           3000-37FF sfx latches (A1:A0)
//   5800-7FFF ROM            everything else / write-only devices read: open bus
// Open bus = last value on the sound CPU data bus (previous read or write data).
// /IRQ = sound PIA IRQA | RIOT IRQ (6840 IRQ not connected).
// All clocks are enables from one 22.578 MHz clk: CLK = 3.579545/2 (8253, Z80),
// E = CLK/2 (6502 Phi0, 6840, 6532, sound-side PIA).
//
// Victory map (A15-A12): 0000-0FFF RIOT RAM (A7=0) / 128 B RAM (A7=1),
//   1xxx RIOT I/O, 2xxx PIA, 3xxx 8253 (write only), 5xxx 6840, 6xxx sfx latches, C000-FFFF ROM; rest open bus.
//   No filter latch. RIOT PA = TMS5220 data, PB0 -> /RS, PB1 -> /WS, PB2 <- /READY, PB3 <- /INT.
//   PIA: PA <- command latch, CA1 <- command pending (0), CA2 falling -> CA1 = 1; PB -> response,
//   CB1 <- response flag (main read F800 -> 0, CB2 falling edge (flip-flop F4) -> 1).
// ============================================================================

module exidy_sndbd #(
    parameter bit MTRAP_EXRAM_OPEN = 1'b1   // 1 = schematic: Mouse Trap 0080-00FF (A7=1) is open bus; 0 = RAM mirror
)
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,          // active high; held during ROM download
    input  logic        pause,          // OSD pause: freezes every clock enable on the board (CPUs stay in lockstep)
    input  logic        cvsd_en,        // 1 = Mouse Trap speech section fitted
    input  logic        victory,        // 1 = Victory map + command latch + TMS5220

    input  logic        main_ce,
    input  logic        main_pia_cs,
    input  logic        main_rw,
    input  logic  [1:0] main_a,
    input  logic  [7:0] main_din,
    output logic  [7:0] main_dout,

    output logic        snd_ce,
    input  logic [15:0] snd_a,
    input  logic  [7:0] snd_dout,
    input  logic        snd_rw,
    output logic  [7:0] snd_din,
    output logic        snd_irq_n,

    output logic        z80_cen_p,
    output logic        z80_cen_n,
    output logic        z80_reset_n,
    input  logic [15:0] z_a,
    input  logic  [7:0] z_dout,
    input  logic        z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_m1_n,
    output logic  [7:0] z_din,

    input  logic        vic_cmd_wr,     // one clk pulse: main CPU wrote F800, data on vic_cmd
    input  logic  [7:0] vic_cmd,
    input  logic        vic_resp_rd,    // one clk pulse: main CPU finished a read of F800
    output logic  [7:0] vic_resp,       // PIA port B output
    output logic  [1:0] vic_status,     // {CA1, CB1}: main reads F801 as {vic_status, 6'b0}

    input  logic  [3:0] vol_music,
    input  logic  [3:0] vol_sfx,
    input  logic  [3:0] vol_speech,

    output logic  [7:0] z_rom_q,        // cvsd_rom read data (also Victory's main ROM 8000-BFFF)

    // sound / CVSD ROMs in the dispatcher's shared ROM blocks (read ports)
    output logic [13:0] snd_rom_a,
    input  logic  [7:0] snd_rom_q,
    output logic [13:0] cvsd_rom_a,
    input  logic  [7:0] cvsd_rom_q,
    // board RAM pool (rtl/ram_pool_pkg.sv, dispatcher): block 5 = Victory 0080-00FF RAM
    output ram_pool_pkg::pram_i_t [5:0] pr_i,
    input  ram_pool_pkg::pram_o_t [5:0] pr_o,

    // this board's chips are the dispatcher's shared pool (rtl/exidy_board.sv), driven here
    output chip_pool_pkg::pia6821_i_t [1:0] pia6821_i,      // [0] main-side PIA, [1] sound-side PIA
    input  chip_pool_pkg::pia6821_o_t [1:0] pia6821_o,
    output chip_pool_pkg::pit8253_i_t       pit8253_i,
    input  chip_pool_pkg::pit8253_o_t       pit8253_o,
    output chip_pool_pkg::riot6532_i_t      riot6532_i,
    input  chip_pool_pkg::riot6532_o_t      riot6532_o,
    output chip_pool_pkg::ptm6840_i_t       ptm6840_i,
    input  chip_pool_pkg::ptm6840_o_t       ptm6840_o,
    output chip_pool_pkg::mc3417_i_t        mc3417_i,
    input  chip_pool_pkg::mc3417_o_t        mc3417_o,
    output chip_pool_pkg::tms5220rsws_i_t   tms5220rsws_i,
    input  chip_pool_pkg::tms5220rsws_o_t   tms5220rsws_o,

    output logic signed [15:0] audio
);

// ============================================================================
// Clock enables: CLK = 3579545/2 Hz from 22578000 Hz (exact rational accumulator)
// ============================================================================
localparam logic [26:0] CK_INC  = 27'd3579545;
localparam logic [26:0] CK_MOD  = 27'd45156000;     // 2 * 22578000
localparam logic [26:0] CK_HALF = 27'd22578000;

logic [26:0] ck_acc;
logic        cen_p, cen_n, e_ph;
wire  [26:0] ck_nxt = ck_acc + CK_INC;

always_ff @(posedge clk) begin
    if (reset) begin
        ck_acc <= 27'd0;
        cen_p  <= 1'b0;
        cen_n  <= 1'b0;
        e_ph   <= 1'b0;
        snd_ce <= 1'b0;
    end else begin
        cen_p  <= 1'b0;
        cen_n  <= 1'b0;
        snd_ce <= 1'b0;
        if (pause) ;                                    // hold the accumulator: nothing on the board advances
        else if (ck_nxt >= CK_MOD) begin
            ck_acc <= ck_nxt - CK_MOD;
            cen_p  <= 1'b1;
            e_ph   <= ~e_ph;
            snd_ce <= e_ph;
        end else begin
            ck_acc <= ck_nxt;
            if ((ck_acc < CK_HALF) && (ck_nxt >= CK_HALF)) cen_n <= 1'b1;
        end
    end
end

assign z80_cen_p = cen_p;
assign z80_cen_n = cen_n;
wire   e_ce      = snd_ce;

// ============================================================================
// ROMs (dpram_dc, 1-clk read latency; CPU addresses are stable for many clks)
// ============================================================================
// Both ROMs are dispatcher ROM blocks (rom_wr / cvr_wr load decode there).
// The cvsd_rom block also holds Victory's main ROM 8000-BFFF (index 0 0x40000-0x43FFF, read by the same pooled
// Z80 at z_a[13:0]); Victory has no CVSD section. Fax's question bytes at 0x40000 land here too, unread (Fax reads DDR3).
logic [7:0] rom_q, cvr_q;
// (ROM blocks are in the dispatcher)
assign snd_rom_a  = snd_a[13:0];
assign rom_q      = snd_rom_q;
assign cvsd_rom_a = z_a[13:0];
assign cvr_q      = cvsd_rom_q;
assign z_rom_q    = cvr_q;

// ============================================================================
// Sound CPU decode
// ============================================================================
wire [3:0] blk     = snd_a[14:11];
wire [3:0] vblk    = snd_a[15:12];       // Victory decode
wire       s_ram   = victory ? ((vblk == 4'd0) & ~snd_a[7]) : ((blk == 4'd0) & ~(cvsd_en & MTRAP_EXRAM_OPEN & snd_a[7]));
wire       s_vram  = victory & (vblk == 4'd0) & snd_a[7];
wire       s_rio   = victory ? (vblk == 4'd1) : (blk == 4'd1);
wire       s_pia   = victory ? (vblk == 4'd2) : (blk == 4'd2);
wire       s_pit   = victory ? (vblk == 4'd3) : (blk == 4'd3);
wire       s_flt   = ~victory & (blk == 4'd4);
wire       s_ptm   = victory ? (vblk == 4'd5) : (blk == 4'd5);
wire       s_sfx   = victory ? (vblk == 4'd6) : (blk == 4'd6);
wire       s_rom   = victory ? (snd_a[15:14] == 2'b11) : (blk >= 4'd11);
wire       s_wr    = e_ce & ~snd_rw;

// Victory 0080-00FF RAM (mirror 0F00)
logic [7:0] vram_q;
// pool block 5
assign pr_i[0] = '0;
assign pr_i[1] = '0;
assign pr_i[2] = '0;
assign pr_i[3] = '0;
assign pr_i[4] = '0;
assign pr_i[5].a_addr = {8'd0, snd_a[6:0]};
assign pr_i[5].a_d    = snd_dout;
assign pr_i[5].a_we   = s_wr & s_vram;
assign pr_i[5].b_addr = {8'd0, snd_a[6:0]};
assign pr_i[5].b_d    = 8'h00;
assign pr_i[5].b_we   = 1'b0;
assign vram_q = pr_o[5].b_q;

// ============================================================================
// RIOT 6532
// ============================================================================
logic [7:0] riot_q, riot_pa, riot_pb;
logic       riot_irq;
logic       busy_ff;          // Mouse Trap E2: /BUSY from the Z80 -> PB0
logic [7:0] tms_bus;          // Victory: TMS5220 data bus (FF when not driving)
logic       tms_ready_n, tms_int_n;

// pool slot riot6532_0 (dispatcher)
assign riot6532_i.rst    = reset;
assign riot6532_i.ce     = e_ce;
assign riot6532_i.ram_cs = s_ram;
assign riot6532_i.io_cs  = s_rio;
assign riot6532_i.rw     = snd_rw;
assign riot6532_i.a      = snd_a[6:0];
assign riot6532_i.din    = snd_dout;
assign riot6532_i.pa_i   = victory ? tms_bus : 8'hFF;
assign riot6532_i.pb_i   = victory ? {4'hF, tms_int_n, tms_ready_n, 2'b11} : {7'h7F, cvsd_en ? busy_ff : 1'b1};
assign riot_q   = riot6532_o.dout;
assign riot_irq = riot6532_o.irq;
assign riot_pa  = riot6532_o.pa_pins;
assign riot_pb  = riot6532_o.pb_pins;

// ============================================================================
// PIAs: main side (5200-520F, main CPU E) and sound side (1000-17FF, sound E)
//   main PA <- snd PB, main PB -> snd PA, main CA2 -> snd CB1, main CB2 -> snd CA1,
//   snd CA2 -> main CB1, snd CB2 -> main CA1. Undriven lines float high.
// ============================================================================
logic [7:0] mp_pa_o, mp_pa_oe, mp_pb_o, mp_pb_oe, mp_q;
logic       mp_ca2_o, mp_ca2_oe, mp_cb2_o, mp_cb2_oe;
logic [7:0] sp_pa_o, sp_pa_oe, sp_pb_o, sp_pb_oe, sp_q;
logic       sp_ca2_o, sp_ca2_oe, sp_cb2_o, sp_cb2_oe;
logic       sp_irqa;

wire [7:0] net_a   = (mp_pa_oe & mp_pa_o) | (~mp_pa_oe & ((sp_pb_oe & sp_pb_o) | ~sp_pb_oe));   // main PA = snd PB
wire [7:0] net_b   = (mp_pb_oe & mp_pb_o) | (~mp_pb_oe & ((sp_pa_oe & sp_pa_o) | ~sp_pa_oe));   // main PB = snd PA
wire       n_mca2  = mp_ca2_oe ? mp_ca2_o : 1'b1;    // -> snd CB1
wire       n_mcb2  = mp_cb2_oe ? mp_cb2_o : 1'b1;    // -> snd CA1
wire       n_sca2  = sp_ca2_oe ? sp_ca2_o : 1'b1;    // -> main CB1
wire       n_scb2  = sp_cb2_oe ? sp_cb2_o : 1'b1;    // -> main CA1

// pool slot pia6821[0] (dispatcher)
assign pia6821_i[0].rst   = reset;
assign pia6821_i[0].ce    = main_ce;
assign pia6821_i[0].cs    = main_pia_cs;
assign pia6821_i[0].rw    = main_rw;
assign pia6821_i[0].rs    = main_a;
assign pia6821_i[0].din   = main_din;
assign pia6821_i[0].pa_i  = net_a;
assign pia6821_i[0].ca1   = n_scb2;
assign pia6821_i[0].ca2_i = n_mca2;
assign pia6821_i[0].pb_i  = net_b;
assign pia6821_i[0].cb1   = n_sca2;
assign pia6821_i[0].cb2_i = n_mcb2;
assign mp_q      = pia6821_o[0].dout;
assign mp_pa_o   = pia6821_o[0].pa_o;   assign mp_pa_oe  = pia6821_o[0].pa_oe;
assign mp_ca2_o  = pia6821_o[0].ca2_o;  assign mp_ca2_oe = pia6821_o[0].ca2_oe;
assign mp_pb_o   = pia6821_o[0].pb_o;   assign mp_pb_oe  = pia6821_o[0].pb_oe;
assign mp_cb2_o  = pia6821_o[0].cb2_o;  assign mp_cb2_oe = pia6821_o[0].cb2_oe;
assign main_dout = mp_q;

// Victory: main-side link replaces the main PIA
logic [7:0] vic_latch;
logic       vic_ca1, vic_cb1, vic_ca2_d, vic_cb2_d;

// pool slot pia6821[1] (dispatcher)
assign pia6821_i[1].rst   = reset;
assign pia6821_i[1].ce    = e_ce;
assign pia6821_i[1].cs    = s_pia;
assign pia6821_i[1].rw    = snd_rw;
assign pia6821_i[1].rs    = snd_a[1:0];
assign pia6821_i[1].din   = snd_dout;
assign pia6821_i[1].pa_i  = victory ? vic_latch : net_b;
assign pia6821_i[1].ca1   = victory ? vic_ca1 : n_mcb2;
assign pia6821_i[1].ca2_i = n_sca2;
assign pia6821_i[1].pb_i  = victory ? 8'h00 : net_a;
assign pia6821_i[1].cb1   = victory ? vic_cb1 : n_mca2;
assign pia6821_i[1].cb2_i = n_scb2;
assign sp_q      = pia6821_o[1].dout;
assign sp_irqa   = pia6821_o[1].irqa;
assign sp_pa_o   = pia6821_o[1].pa_o;   assign sp_pa_oe  = pia6821_o[1].pa_oe;
assign sp_ca2_o  = pia6821_o[1].ca2_o;  assign sp_ca2_oe = pia6821_o[1].ca2_oe;
assign sp_pb_o   = pia6821_o[1].pb_o;   assign sp_pb_oe  = pia6821_o[1].pb_oe;
assign sp_cb2_o  = pia6821_o[1].cb2_o;  assign sp_cb2_oe = pia6821_o[1].cb2_oe;

// CA2 / CB2 pins as seen by the link logic (undriven = high): CA2 falling = irq_clear_w(0), CB2 falling = main_ack_w
always_ff @(posedge clk) begin
    if (reset) begin
        vic_latch <= 8'h00; vic_ca1 <= 1'b1; vic_cb1 <= 1'b1; vic_ca2_d <= 1'b1; vic_cb2_d <= 1'b1;
    end else begin
        vic_ca2_d <= n_sca2;
        vic_cb2_d <= n_scb2;
        if (vic_ca2_d & ~n_sca2) vic_ca1 <= 1'b1;
        if (vic_cb2_d & ~n_scb2) vic_cb1 <= 1'b1;
        if (vic_cmd_wr) begin vic_latch <= vic_cmd; vic_ca1 <= 1'b0; end
        if (vic_resp_rd) vic_cb1 <= 1'b0;
    end
end
assign vic_resp   = sp_pb_o & sp_pb_oe;
assign vic_status = {vic_ca1, vic_cb1};

assign snd_irq_n = ~(sp_irqa | riot_irq);

// ============================================================================
// 8253 (music), filter latch, sfx latches
// ============================================================================
logic [2:0] pit_out;
// pool slot pit8253_0 (dispatcher)
assign pit8253_i.rst    = reset;
assign pit8253_i.wr_en  = s_wr & s_pit;
assign pit8253_i.a      = snd_a[1:0];
assign pit8253_i.din    = snd_dout;
assign pit8253_i.clk_ce = cen_p;
assign pit8253_i.gate   = 3'b111;
assign pit_out = pit8253_o.out;

logic [7:0] filt;
logic [1:0] sfxctrl;          // bit0 = noise clock (0 = E, 1 = 6840 O1), bit1 = mute O1
logic [2:0] lvl1, lvl2, lvl3;
always_ff @(posedge clk) begin
    if (reset) begin
        filt <= 8'h00; sfxctrl <= 2'b00; lvl1 <= 3'd0; lvl2 <= 3'd0; lvl3 <= 3'd0;
    end else begin
        if (s_wr & s_flt) filt <= snd_dout;
        if (s_wr & s_sfx) begin
            case (snd_a[1:0])
                2'd0: sfxctrl <= snd_dout[1:0];
                2'd1: lvl1    <= snd_dout[2:0];
                2'd2: lvl2    <= snd_dout[2:0];
                default: lvl3 <= snd_dout[2:0];
            endcase
        end
    end
end

// ============================================================================
// 6840 + MC14562 noise (128-bit SR, data = (tap127 ^ tap95) ^ previous, clock tap = stage 64)
// ============================================================================
logic [2:0]   ptm_o;
logic [7:0]   ptm_q;
logic [127:0] lfsr;
logic         oldxor, o1_d;

wire noise_tap = lfsr[64];

// pool slot ptm6840_0 (dispatcher)
assign ptm6840_i.rst = reset;
assign ptm6840_i.ce  = e_ce;
assign ptm6840_i.cs  = s_ptm;
assign ptm6840_i.rw  = snd_rw;
assign ptm6840_i.rs  = snd_a[2:0];
assign ptm6840_i.din = snd_dout;
assign ptm6840_i.cx  = {3{noise_tap}};
assign ptm_q = ptm6840_o.dout;
assign ptm_o = ptm6840_o.o;

// noise SR clock: E, or 6840 O1 through the LS04 (shifts on the O1 falling edge)
wire noise_step = e_ce & (~sfxctrl[0] | (o1_d & ~ptm_o[0]));
wire newxor     = lfsr[127] ^ lfsr[95];

always_ff @(posedge clk) begin
    if (reset) begin
        lfsr   <= {128{1'b1}};
        oldxor <= 1'b0;
        o1_d   <= 1'b0;
    end else begin
        if (e_ce) o1_d <= ptm_o[0];
        if (noise_step) begin
            lfsr   <= {lfsr[126:0], newxor ^ oldxor};
            oldxor <= newxor;
        end
    end
end

wire [2:0] ch_gate = {ptm_o[2], ptm_o[1], ptm_o[0] & ~sfxctrl[1]};

// ============================================================================
// Sound CPU read mux + open bus
// ============================================================================
logic [7:0] last_bus;
always_comb begin
    if      (s_ram | s_rio) snd_din = riot_q;
    else if (s_pia)         snd_din = sp_q;
    else if (s_ptm)         snd_din = ptm_q;
    else if (s_rom)         snd_din = rom_q;
    else if (s_vram)        snd_din = vram_q;
    else                    snd_din = last_bus;
end

always_ff @(posedge clk) begin
    if (reset)     last_bus <= 8'hFF;
    else if (e_ce) last_bus <= snd_rw ? snd_din : snd_dout;
end

// ============================================================================
// Mouse Trap speech: Z80 I/O, 555 bit clock, MC3417
// ============================================================================
// 555 F2: high 0.693*(2.4K+20K)*2200p = 34.15 us, low 0.693*20K*2200p = 30.49 us
localparam logic [9:0] T555_HI = 10'd771;
localparam logic [9:0] T555_LO = 10'd688;
logic [9:0] t555;
logic       bclk;
always_ff @(posedge clk) begin
    if (reset) begin
        t555 <= 10'd0; bclk <= 1'b1;
    end else if (t555 == 10'd0) begin
        bclk <= ~bclk;
        t555 <= bclk ? (T555_LO - 10'd1) : (T555_HI - 10'd1);
    end else
        t555 <= t555 - 10'd1;
end

// I/O: A7=0 read -> RIOT PA3/PA0/PA2/PA1 on ZD3-ZD0; A6=0 read -> 555 on ZD7;
//      A5=0 write -> ZD0 to /BUSY FF; A4=0 write -> ZD0 to MC3417 data FF.
// HW clocks the FFs at the end of the I/O cycle; writes qualified by /WR here.
logic [7:0] z_io_q;
always_comb begin
    z_io_q = 8'hFF;
    if (!z_a[7]) z_io_q[3:0] = {riot_pa[3], riot_pa[0], riot_pa[2], riot_pa[1]};
    if (!z_a[6]) z_io_q[7]   = bclk;
end
assign z_din = (!z_iorq_n) ? z_io_q : cvr_q;

wire  z_wstb = ~z_iorq_n & ~z_wr_n & z_m1_n;
logic z_wstb_d, z_wd0, z_wa4, z_wa5;
logic cvsd_bit;
always_ff @(posedge clk) begin
    if (reset) begin
        z_wstb_d <= 1'b0; z_wd0 <= 1'b0; z_wa4 <= 1'b1; z_wa5 <= 1'b1;
        cvsd_bit <= 1'b0; busy_ff <= 1'b1;
    end else begin
        z_wstb_d <= z_wstb;
        if (z_wstb) begin
            z_wd0 <= z_dout[0]; z_wa4 <= z_a[4]; z_wa5 <= z_a[5];
        end
        if (z_wstb_d & ~z_wstb) begin
            if (!z_wa4) cvsd_bit <= z_wd0;
            if (!z_wa5) busy_ff  <= z_wd0;
        end
    end
end

assign z80_reset_n = riot_pa[4] & ~reset & cvsd_en;

logic signed [23:0] cvsd_int;
// pool slot mc3417_0 (dispatcher)
assign mc3417_i.rst  = reset | ~cvsd_en;
assign mc3417_i.bclk = bclk;
assign mc3417_i.din  = cvsd_bit;
assign cvsd_int = mc3417_o.integ;

// ============================================================================
// Victory speech: TMS5220 (640 kHz) on the RIOT
// ============================================================================
logic signed [15:0] tms_audio;
// pool slot tms5220rsws_0 (dispatcher, same CLK_HZ / TMS_HZ)
assign tms5220rsws_i.reset = reset | ~victory;
assign tms5220rsws_i.pause = pause;
assign tms5220rsws_i.rs_n  = riot_pb[0];
assign tms5220rsws_i.ws_n  = riot_pb[1];
assign tms5220rsws_i.d_in  = riot_pa;
assign tms_bus     = tms5220rsws_o.d_out;
assign tms_ready_n = tms5220rsws_o.ready_n;
assign tms_int_n   = tms5220rsws_o.int_n;
assign tms_audio   = tms5220rsws_o.audio;

// ============================================================================
// Analog section
// ============================================================================
exidy_snd_mixer mixer
(
    .clk(clk), .rst(reset), .ce(e_ce), .mtrap(cvsd_en),
    .gate(ch_gate), .lvl1(lvl1), .lvl2(lvl2), .lvl3(lvl3), .filt(filt),
    .music(pit_out), .speech_on(cvsd_en), .speech(cvsd_int),
    .tms_on(victory), .tms(tms_audio),
    .vol_music(vol_music), .vol_sfx(vol_sfx), .vol_speech(vol_speech),
    .audio(audio)
);

// unused inputs
wire unused = &{1'b0, z_mreq_n, z_rd_n, riot_pb[7:2], riot_pa[7:5], z_a[15:14], z_dout[7:1]};

endmodule

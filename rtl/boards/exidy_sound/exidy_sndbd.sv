// ============================================================================
// exidy_sndbd.sv — Exidy Venture-type Audio/Color board, sound section
//   Venture / Pepper II (77-3387 / 77-0007) and Mouse Trap (177-3392, + Z80/MC3417 CVSD)
// Sources: Claude/exidy_schematic_facts.md (schematic = target), MAME exidysound.cpp (fallback).
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
// ============================================================================

module exidy_sndbd #(
    parameter bit MTRAP_EXRAM_OPEN = 1'b1   // 1 = schematic: Mouse Trap 0080-00FF (A7=1) is open bus; 0 = MAME mirror
)
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,          // active high; held during ROM download
    input  logic        cvsd_en,        // 1 = Mouse Trap speech section fitted

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

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

    input  logic  [3:0] vol_music,
    input  logic  [3:0] vol_sfx,
    input  logic  [3:0] vol_speech,

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
        if (ck_nxt >= CK_MOD) begin
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
wire rom_wr = ioctl_wr0 & (ioctl_addr[24:14] == 11'd3);    // 0x0C000-0x0FFFF = CPU 4000-7FFF
wire cvr_wr = ioctl_wr0 & (ioctl_addr[24:14] == 11'd4);    // 0x10000-0x13FFF = Z80 0000-3FFF

logic [7:0] rom_q, cvr_q;
dpram_dc #(.widthad_a(14), .width_a(8)) snd_rom
(
    .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(rom_wr), .q_a(),
    .clock_b(clk), .address_b(snd_a[13:0]), .data_b(8'h00), .wren_b(1'b0), .q_b(rom_q)
);
dpram_dc #(.widthad_a(14), .width_a(8)) cvsd_rom
(
    .clock_a(clk), .address_a(ioctl_addr[13:0]), .data_a(ioctl_dout), .wren_a(cvr_wr), .q_a(),
    .clock_b(clk), .address_b(z_a[13:0]), .data_b(8'h00), .wren_b(1'b0), .q_b(cvr_q)
);

// ============================================================================
// Sound CPU decode
// ============================================================================
wire [3:0] blk     = snd_a[14:11];
wire       s_ram   = (blk == 4'd0) & ~(cvsd_en & MTRAP_EXRAM_OPEN & snd_a[7]);
wire       s_rio   = (blk == 4'd1);
wire       s_pia   = (blk == 4'd2);
wire       s_pit   = (blk == 4'd3);
wire       s_flt   = (blk == 4'd4);
wire       s_ptm   = (blk == 4'd5);
wire       s_sfx   = (blk == 4'd6);
wire       s_rom   = (blk >= 4'd11);
wire       s_wr    = e_ce & ~snd_rw;

// ============================================================================
// RIOT 6532
// ============================================================================
logic [7:0] riot_q, riot_pa, riot_pb;
logic       riot_irq;
logic       busy_ff;          // Mouse Trap E2: /BUSY from the Z80 -> PB0

riot6532 riot
(
    .clk(clk), .rst(reset), .ce(e_ce),
    .ram_cs(s_ram), .io_cs(s_rio), .rw(snd_rw), .a(snd_a[6:0]), .din(snd_dout), .dout(riot_q),
    .irq(riot_irq),
    .pa_i(8'hFF), .pa_pins(riot_pa),
    .pb_i({7'h7F, cvsd_en ? busy_ff : 1'b1}), .pb_pins(riot_pb)
);

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

pia6821 main_pia
(
    .clk(clk), .rst(reset), .ce(main_ce), .cs(main_pia_cs), .rw(main_rw), .rs(main_a),
    .din(main_din), .dout(mp_q), .irqa(), .irqb(),
    .pa_i(net_a), .pa_o(mp_pa_o), .pa_oe(mp_pa_oe), .ca1(n_scb2), .ca2_i(n_mca2), .ca2_o(mp_ca2_o), .ca2_oe(mp_ca2_oe),
    .pb_i(net_b), .pb_o(mp_pb_o), .pb_oe(mp_pb_oe), .cb1(n_sca2), .cb2_i(n_mcb2), .cb2_o(mp_cb2_o), .cb2_oe(mp_cb2_oe)
);
assign main_dout = mp_q;

pia6821 snd_pia
(
    .clk(clk), .rst(reset), .ce(e_ce), .cs(s_pia), .rw(snd_rw), .rs(snd_a[1:0]),
    .din(snd_dout), .dout(sp_q), .irqa(sp_irqa), .irqb(),
    .pa_i(net_b), .pa_o(sp_pa_o), .pa_oe(sp_pa_oe), .ca1(n_mcb2), .ca2_i(n_sca2), .ca2_o(sp_ca2_o), .ca2_oe(sp_ca2_oe),
    .pb_i(net_a), .pb_o(sp_pb_o), .pb_oe(sp_pb_oe), .cb1(n_mca2), .cb2_i(n_scb2), .cb2_o(sp_cb2_o), .cb2_oe(sp_cb2_oe)
);

assign snd_irq_n = ~(sp_irqa | riot_irq);

// ============================================================================
// 8253 (music), filter latch, sfx latches
// ============================================================================
logic [2:0] pit_out;
pit8253 pit
(
    .clk(clk), .rst(reset), .wr_en(s_wr & s_pit), .a(snd_a[1:0]), .din(snd_dout),
    .clk_ce(cen_p), .gate(3'b111), .out(pit_out)
);

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

ptm6840 ptm
(
    .clk(clk), .rst(reset), .ce(e_ce), .cs(s_ptm), .rw(snd_rw), .rs(snd_a[2:0]),
    .din(snd_dout), .dout(ptm_q), .cx({3{noise_tap}}), .o(ptm_o), .irq()
);

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
// HW clocks the FFs at the end of the I/O cycle; writes qualified by /WR here (MAME).
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
mc3417 cvsd
(
    .clk(clk), .rst(reset | ~cvsd_en), .bclk(bclk), .din(cvsd_bit), .integ(cvsd_int)
);

// ============================================================================
// Analog section
// ============================================================================
exidy_snd_mixer mixer
(
    .clk(clk), .rst(reset), .ce(e_ce), .mtrap(cvsd_en),
    .gate(ch_gate), .lvl1(lvl1), .lvl2(lvl2), .lvl3(lvl3), .filt(filt),
    .music(pit_out), .speech_on(cvsd_en), .speech(cvsd_int),
    .vol_music(vol_music), .vol_sfx(vol_sfx), .vol_speech(vol_speech),
    .audio(audio)
);

// unused inputs
wire unused = &{1'b0, z_mreq_n, z_rd_n, snd_a[15], riot_pb, riot_pa[7:5], z_a[15:14], z_dout[7:1]};

endmodule

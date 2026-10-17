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
    input  logic  [7:0] dial,           // Teeter Torture dial position (rtl/exidy_dial.sv)

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    input  logic  [3:0] vol_music,
    input  logic  [3:0] vol_sfx,
    input  logic  [3:0] vol_speech,

    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,
    output logic        vblank_raw,

    output logic signed [15:0] audio,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  Clock enables  /////////////////////////////

logic [1:0] ph = 2'd0;
logic [4:0] cdiv = 5'd0;
always_ff @(posedge clk) begin
    ph   <= ph + 2'd1;
    cdiv <= cdiv + 5'd1;
end
assign ce_pix = (ph == 2'd3);
wire   main_ce = (cdiv == 5'd31) & ~pause;             // 11.289 MHz / 16

/////////////////////////////  ROMs  /////////////////////////////

wire load_main = ioctl_wr0 && ioctl_addr < 25'h08000;
wire load_spr  = ioctl_wr0 && ioctl_addr[24:11] == 14'h0028;   // 0x14000-0x147FF

logic [15:0] m_a;
logic  [7:0] rom_d, spr_d;
logic [10:0] spr_a;

dpram_dc #(.widthad_a(15)) rom_main
(
    .clock_a(clk), .address_a(ioctl_addr[14:0]), .data_a(ioctl_dout), .wren_a(load_main),
    .clock_b(clk), .address_b((board_cfg2[1] & m_a[15]) ? {1'b0, m_a[13:0]} : m_a[14:0]), .q_b(rom_d)
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
    .Mode(2'b00), .Res_n(~reset), .Enable(main_ce), .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1),
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

logic [17:0] qrom_a;
logic  [7:0] qrom_d, q0_d, q1_d;
wire load_q0 = ioctl_wr0 && ioctl_addr[24:17] == 8'h01;   // 0x20000-0x3FFFF: banks 0-15
wire load_q1 = ioctl_wr0 && ioctl_addr[24:16] == 9'h004;  // 0x40000-0x4FFFF: banks 16-23

dpram_dc #(.widthad_a(17)) qrom0
(
    .clock_a(clk), .address_a(ioctl_addr[16:0]), .data_a(ioctl_dout), .wren_a(load_q0),
    .clock_b(clk), .address_b(qrom_a[16:0]), .q_b(q0_d)
);

dpram_dc #(.widthad_a(16)) qrom1
(
    .clock_a(clk), .address_a(ioctl_addr[15:0]), .data_a(ioctl_dout), .wren_a(load_q1),
    .clock_b(clk), .address_b(qrom_a[15:0]), .q_b(q1_d)
);

assign qrom_d = !qrom_a[17] ? q0_d : !qrom_a[16] ? q1_d : 8'hFF;   // banks 24-31 unpopulated

/////////////////////////////  Logic board  /////////////////////////////

logic        pia_cs;
logic  [7:0] pia_dout;
logic  [8:0] pix_x, pix_y;
logic  [2:0] pix_rgb;

exidy_main main_b
(
    .clk(clk), .reset(reset), .ph(ph), .ce_pix(ce_pix), .cfg(board_cfg), .cfg2(board_cfg2), .col_init(col_init),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .cpu_ce(main_ce), .cpu_a(m_a), .cpu_do(m_do), .cpu_rw(m_rw), .cpu_di(m_di), .cpu_irq_n(m_irq_n),
    .rom_d(rom_d), .qrom_a(qrom_a), .qrom_d(qrom_d), .spr_a(spr_a), .spr_d(spr_d),
    .pia_cs(pia_cs), .pia_dout(pia_dout),
    .in0(in0_b), .dsw(dsw), .in2(in2), .intsrc(intsrc), .in3(in3), .in4(in4), .in0_rd(in0_rd),
    .coin1(coin[0]), .coin2(coin[1]),
    .pix_x(pix_x), .pix_y(pix_y), .pix_rgb(pix_rgb), .vbl_irq_raw(vblank_raw),
    .hs_a(hs_address[9:0]), .hs_din(hs_data_in), .hs_dout(hs_data_out),
    .hs_we(hs_write && hs_address[15:10] == 6'd0)
);

/////////////////////////////  Audio / colour board  /////////////////////////////

wire         gen1    = (variant == 8'd5) || (variant == 8'd6);
wire         snd_rst = reset | gen1;        // gen-1 games have no 6502 sound board
logic signed [15:0] sndbd_audio, gen1_audio;
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
logic [15:0] z_a;
logic  [7:0] z_do, z_di;
logic        z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_m1_n;

T80pa #(.Mode(0)) speech_cpu
(
    .RESET_n(z_reset_n), .CLK(clk), .CEN_p(z_cen_p), .CEN_n(z_cen_n), .WAIT_n(1'b1), .INT_n(1'b1), .NMI_n(1'b1),
    .BUSRQ_n(1'b1), .M1_n(z_m1_n), .MREQ_n(z_mreq_n), .IORQ_n(z_iorq_n), .RD_n(z_rd_n), .WR_n(z_wr_n),
    .RFSH_n(), .HALT_n(), .BUSAK_n(), .OUT0(1'b0), .A(z_a), .DI(z_di), .DO(z_do),
    .R800_mode(1'b0), .REG(), .DIRSet(1'b0), .DIR(212'd0)
);

exidy_sndbd snd_b
(
    .clk(clk), .reset(snd_rst), .cvsd_en(variant == 8'd1),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .main_ce(main_ce), .main_pia_cs(pia_cs), .main_rw(m_rw), .main_a(m_a[1:0]), .main_din(m_do), .main_dout(pia_dout),
    .snd_ce(snd_ce), .snd_a(snd_a24[15:0]), .snd_dout(snd_do), .snd_rw(snd_rw), .snd_din(snd_di), .snd_irq_n(snd_irq_n),
    .z80_cen_p(z_cen_p), .z80_cen_n(z_cen_n), .z80_reset_n(z_reset_n),
    .z_a(z_a), .z_dout(z_do), .z_mreq_n(z_mreq_n), .z_iorq_n(z_iorq_n), .z_rd_n(z_rd_n), .z_wr_n(z_wr_n), .z_m1_n(z_m1_n),
    .z_din(z_di),
    .vol_music(vol_music), .vol_sfx(vol_sfx), .vol_speech(vol_speech),
    .audio(sndbd_audio)
);

// gen-1 audio board: decodes only A0 inside the 52xx page (5200 / 5201 latches)
exidy_gen1snd gen1_b
(
    .clk(clk), .reset(reset), .spectar(variant == 8'd6),
    .cpu_ce(main_ce), .wr(main_ce & ~m_rw & (m_a[15:8] == 8'h52) & ~m_a[4]), .a0(m_a[0]), .din(m_do),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr0(ioctl_wr0),
    .vol_music(vol_music), .vol_sfx(vol_sfx),
    .audio(gen1_audio)
);

assign audio = gen1 ? gen1_audio : sndbd_audio;

/////////////////////////////  CRT Flip + video out  /////////////////////////////

// The objects are position counters running with the beam, so the picture is not mirrored by remapping:
// the visible 256 x 256 frame is double-buffered and, with CRT Flip on, read back from the opposite corner
// (one frame of delay, flipped only).
logic       wbuf = 1'b0;
logic [7:0] fb_q;
wire        pix_vis = (pix_x < 9'd256) && (pix_y < 9'd256);
wire [16:0] fb_wa = {wbuf, pix_y[7:0], pix_x[7:0]};
wire [16:0] fb_ra = {~wbuf, 8'd255 - pix_y[7:0], 8'd255 - pix_x[7:0]};

always_ff @(posedge clk)
    if (ce_pix && pix_x == 9'd0 && pix_y == 9'd256) wbuf <= ~wbuf;

dpram_dc #(.widthad_a(17)) flip_fb
(
    .clock_a(clk), .address_a(fb_wa), .data_a({5'd0, pix_rgb}), .wren_a(!reset && ph == 2'd0 && pix_vis),
    .clock_b(clk), .address_b(fb_ra), .q_b(fb_q)
);

// output stage: one more pixel register; blanking / sync derived from the same pixel coordinates
logic [2:0] rgb_o;
logic [8:0] ox, oy;
always_ff @(posedge clk) begin
    if (ce_pix) begin
        rgb_o <= (crt_flip && pix_vis) ? fb_q[2:0] : pix_rgb;
        ox    <= pix_x;
        oy    <= pix_y;
    end
end

wire [8:0] hs_beg = 9'h120 + {{5{h_adj[3]}}, h_adj};
wire [8:0] vs_beg = 9'd256 + {{5{v_adj[3]}}, v_adj};

assign video_r      = {8{rgb_o[2]}};
assign video_g      = {8{rgb_o[1]}};
assign video_b      = {8{rgb_o[0]}};
assign video_hblank = (ox >= 9'd256);
assign video_vblank = (oy >= 9'd256);
assign video_hs     = (ox >= hs_beg) && (ox < hs_beg + 9'd32);
assign video_vs     = (oy >= vs_beg) && (oy < vs_beg + 9'd8);

endmodule

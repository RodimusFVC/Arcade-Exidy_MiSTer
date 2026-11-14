//============================================================================
//
//  Exidy 6502 raster arcade hardware for MiSTer
//  Copyright (C) 2026 Rodimus
//
//  Top level carried over from the Rodimus Pac-Man core (MikeJ / Sorgelig lineage)
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

wire        CLK_SYS;
wire        locked;
wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire [10:0] ps2_key;
wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
wire        ioctl_wr;
wire  [7:0] ioctl_index;
wire        ddr_ioctl_wait;
wire [26:0] ioctl_addr27;
wire [24:0] ioctl_addr = ioctl_addr27[24:0];
wire  [7:0] ioctl_dout;
wire [15:0] joystick_0, joystick_1, joystick_2, joystick_3;
wire [15:0] joystick_r_analog_0, joystick_r_analog_1;
wire  [8:0] spinner_0, spinner_1, spinner_2, spinner_3;
wire  [7:0] paddle_0, paddle_1;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire [24:0] ps2_mouse;
wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;
wire        pause_cpu;
wire        hblank, vblank;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio, audio_r;
assign AUDIO_L = pause_cpu ? 16'd0 : audio;
assign AUDIO_R = pause_cpu ? 16'd0 : audio_r;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

reg [7:0] game_var    = 8'd0;
reg [7:0] game_flags  = 8'h04;
reg [7:0] game_cfg2   = 8'd0;
reg [7:0] col_init[3] = '{8'd0, 8'd0, 8'd0};
reg [7:0] game_flags2 = 8'h0B;
wire      game_cp     = (game_var == 8'd11);
wire      game_sf     = (game_var == 8'd8);
reg [5:0] in_map[64];
reg [7:0] port_idle[8] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'hFF,8'hFF};
reg [7:0] port_dip[8]  = '{8'h80,8'h80,8'h80,8'h80,8'h80,8'h80,8'h80,8'h80};
wire [7:0] map_idx8  = ioctl_addr[7:0] - 8'd20;
wire [7:0] perm_idx8 = ioctl_addr[7:0] - 8'd84;
wire [5:0] map_idx   = map_idx8[5:0];
wire [5:0] perm_idx  = perm_idx8[5:0];
wire [2:0] idle_idx  = ioctl_addr[2:0] - 3'd4;
wire [2:0] dip_idx   = ioctl_addr[2:0] - 3'd4;
reg  [2:0] dip_bit[64];
initial for (int i = 0; i < 64; i++) dip_bit[i] = i % 8;

reg ds_on = 1'b0;
always @(posedge CLK_SYS) if (ioctl_wr) begin
    if (ioctl_index == 8'd1 && ioctl_addr == 25'd0) ds_on <= 1'b0;
    if (ioctl_index == 8'd5) ds_on <= 1'b1;
end

always @(posedge CLK_SYS) begin
    if (ioctl_wr && ioctl_index == 8'd1) begin
        if (ioctl_addr >= 25'd84 && ioctl_addr < 25'd148) dip_bit[perm_idx] <= ioctl_dout[2:0];
        if (ioctl_addr == 25'd0) game_var   <= ioctl_dout;
        if (ioctl_addr == 25'd1) game_flags  <= ioctl_dout;
        if (ioctl_addr == 25'd2) game_cfg2   <= ioctl_dout;
        if (ioctl_addr >= 25'd148 && ioctl_addr < 25'd151) col_init[ioctl_addr[1:0]] <= ioctl_dout;
        if (ioctl_addr == 25'd3) game_flags2 <= ioctl_dout;
        if (ioctl_addr >= 25'd4  && ioctl_addr < 25'd12) port_idle[idle_idx] <= ioctl_dout;
        if (ioctl_addr >= 25'd12 && ioctl_addr < 25'd20) port_dip[dip_idx]   <= ioctl_dout;
        if (ioctl_addr >= 25'd20 && ioctl_addr < 25'd84) in_map[map_idx] <= ioctl_dout[5:0];
    end
end

wire game_vert = game_flags[4];
wire vert_view = game_vert & ~status[12];

wire [1:0] ar = status[9:8];

wire        art_fb;
wire        art_ioctl_wait, art_avail;
wire [11:0] art_cw, art_ch;
assign VIDEO_ARX = (!ar) ? (art_fb ? art_cw : vert_view ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (art_fb ? art_ch : vert_view ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"EXIDY;;",
	"P1,Video Options;",
	"P1O89,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1O[40:37],H Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[44:41],V Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1OGI,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[57],Colour Overlay,On,Off;",
	"-;",
	"H4P5,Game Options;",
	"H1P5-,Paddle;",
	"H1P5O[60:58],Paddle Sensitivity,1.0x,0.75x,0.5x,0.25x,0.125x,1.25x,1.5x,2.0x;",
	"H1P5O[61],Paddle Direction,Normal,Reversed;",
	"H1P5-,Paddle / spinner / mouse / stick;",
	"H3P5-,Flight Stick;",
	"H3P5O[75],Stick Mode,Flight Control,Standard Control;",
	"H5P5-,Artwork (layout views);",
	"H5P5O[83:80],View,Off,View 1,View 2,View 3,View 4,View 5,View 6,View 7,View 8,View 9,View 10,View 11,View 12,View 13,View 14,View 15;",
	"H5P5O[84],Backdrop,On,Off;",
	"H5P5O[85],Overlay,On,Off;",
	"H5P5O[86],Bezel,On,Off;",
	"H5P5O[87],Control Panel,On,Off;",
	"H5P5O[88],Side Art,On,Off;",
	"H5P5O[89],Zoom to Screen,Off,On;",
	"-;",
	"P2,Game Audio;",
	"P2O[48:45],Music Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[52:49],Effects Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"P2O[56:53],Speech Volume,Default,+1,+2,+3,+4,+5,+6,+7,Off,-7,-6,-5,-4,-3,-2,-1;",
	"H2P2-;",
	"H2P2O[66:64],Timing Caps,Factory,-10%,-20%,-30%,+10%,+20%,+30%;",
	"H2P2O[69:67],Filter Caps,Factory,-10%,-20%,-30%,+10%,+20%,+30%;",
	"H2P2O[72:70],Oscillator Caps,Factory,-10%,-20%,-30%,+10%,+20%,+30%;",
	"H2P2O[74:73],Aged Caps,Off,Light,Heavy;",
	"-;",
	"P3,Pause Options;",
	"P3OJ,Pause when OSD is open,On,Off;",
	"P3OK,Dim video after 10s,On,Off;",
	"-;",
	"P4,High Score Options;",
	"P4OL,Autosave Hiscores,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4,Coin,Start 1P,Start 2P,Pause,Button 5,Button 6,Rack Test;",
	"jn,A,B,X,Y,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_SYS),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({~art_avail, ~(game_flags[6] | game_sf | art_avail), ~game_sf, ~ds_on, ~game_flags[6], direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr27),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ddr_ioctl_wait | art_ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1),
	.spinner_0(spinner_0),
	.spinner_1(spinner_1),
	.spinner_2(spinner_2),
	.spinner_3(spinner_3),
	.paddle_0(paddle_0),
	.paddle_1(paddle_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.ps2_mouse(ps2_mouse),
	.ps2_key(ps2_key)
);

wire        CLK_2X;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(CLK_SYS),
	.outclk_1(CLK_2X),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(0),
	.mgmt_address(0),
	.mgmt_writedata(0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~locked;

wire [12:0] kb;
/* verilator lint_off UNUSED */
wire        kbx_unused;
/* verilator lint_on UNUSED */
ctl_keyboard u_kb(.clk(CLK_SYS), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb), .kbx(kbx_unused));

wire [3:0] dir1_raw = {joystick_0[3] | kb[0], joystick_0[2] | kb[1], joystick_0[1] | kb[2], joystick_0[0] | kb[3]};
wire [3:0] dir2_raw = joystick_1[3:0];
wire [3:0] dir1, dir2;

ctl_joy4way u_j4_1(.clk(CLK_SYS), .en(game_flags[0]), .in(dir1_raw), .out(dir1));
ctl_joy4way u_j4_2(.clk(CLK_SYS), .en(game_flags[0]), .in(dir2_raw), .out(dir2));

wire m_pause = joystick_0[11] | kb[12];

wire coin1_raw = joystick_0[8] | kb[8];
wire coin2_raw = joystick_1[8] | kb[9];
wire coin1, coin2;
ctl_coin_impulse #(.FRAMES(4'd2), .PAUSE_MODE(1)) u_coin1(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank),
	.en(game_flags[2]), .coin_raw(coin1_raw), .coin(coin1));
ctl_coin_impulse #(.FRAMES(4'd2), .PAUSE_MODE(1)) u_coin2(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank),
	.en(game_flags[2]), .coin_raw(coin2_raw), .coin(coin2));

wire rack_btn = joystick_0[14] | joystick_1[14];
wire rack_tog;
ctl_toggle u_rack(.clk(CLK_SYS), .clear(ioctl_download), .btn(rack_btn), .pause(pause_cpu), .q(rack_tog));

wire [3:0] rstick0, rstick1;
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) u_rs0(.stick(joystick_r_analog_0), .dir(rstick0));
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) u_rs1(.stick(joystick_r_analog_1), .dir(rstick1));

wire [35:0] ids;
ctl_ids u_ids(.joy0(joystick_0), .joy1(joystick_1), .kb(kb), .dir1(dir1), .dir2(dir2), .coin1(coin1), .coin2(coin2),
	.coin3(joystick_2[8]), .ctl(ids));
wire [63:0] ctl =
{
	11'd0,
	joystick_3[8],
	joystick_3[6:4],
	joystick_2[6:4],
	joystick_1[13] | rstick1[3],
	joystick_1[12] | rstick1[2],
	joystick_1[7]  | rstick1[1],
	joystick_1[6]  | rstick1[0],
	joystick_0[13] | rstick0[3],
	joystick_0[12] | rstick0[2],
	joystick_0[7]  | rstick0[1],
	joystick_0[6]  | rstick0[0],
	rack_tog,
	rack_btn,
	ids
};

reg [7:0] dip_sw[8] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_SYS) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end

wire   [7:0] in_port[8];
wire  [63:0] pm_idle, pm_sel, pm_dips, pm_ports;
wire [511:0] pm_map;
wire [191:0] pm_dbit;
// genvars at module scope: Quartus 17 rejects `for (genvar ...)` (error 10170)
genvar pm_p, pm_b;
generate
	for (pm_p = 0; pm_p < 8; pm_p = pm_p + 1) begin : g_pm
		assign pm_idle[pm_p*8 +: 8] = port_idle[pm_p];
		assign pm_sel[pm_p*8 +: 8]  = port_dip[pm_p];
		assign pm_dips[pm_p*8 +: 8] = dip_sw[pm_p];
		assign in_port[pm_p]        = pm_ports[pm_p*8 +: 8];
		for (pm_b = 0; pm_b < 8; pm_b = pm_b + 1) begin : g_b
			assign pm_map[(pm_p*8 + pm_b)*8 +: 8]  = {2'b00, in_map[pm_p*8 + pm_b]};
			assign pm_dbit[(pm_p*8 + pm_b)*3 +: 3] = dip_bit[pm_p*8 + pm_b];
		end
	end
endgenerate
ctl_port_map #(.NP(8), .IDW(6), .BASE_MODE(2)) u_pm(.clk(CLK_SYS), .idle(pm_idle), .in_map(pm_map), .dips(32'd0),
	.port_sel(pm_sel), .dip_bytes(pm_dips), .dip_bit(pm_dbit), .ctl(ctl), .ovr_mask(64'd0), .ovr_val(64'd0), .ports(pm_ports));

wire [23:0] rgb_out;
pause #(8,8,8,20) pause
(
	.*,
	.clk_sys(CLK_SYS),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[20:19])
);

wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;
wire bd_ce;

wire rotate_ccw = ~game_flags[7];
wire no_rotate  = ~game_vert | status[12] | direct_video;
wire flip       = status[11];

wire  [7:0] av_r, av_g, av_b;
wire        av_hs, av_vs, av_hbl, av_vbl;
wire [27:0] v_px;
wire        a_wr;
wire [26:0] a_addr;
wire  [7:0] a_dout;
wire        art_wait;
art_xclk #(.IDX(8'd6), .VW(28)) art_xclk
(
	.clk_sys(CLK_SYS), .clk_art(CLK_2X),
	.bd_ce(bd_ce), .bd_px({hs, vs, hblank, vblank, rgb_out}), .ce_art(ce_pix), .px(v_px),
	.ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr27), .ioctl_dout(ioctl_dout),
	.ioctl_wait(art_ioctl_wait), .a_wr(a_wr), .a_addr(a_addr), .a_dout(a_dout), .art_wait(art_wait)
);

wire        art_run;
wire [31:0] art_fb_base;
wire  [7:0] art_burstcnt, art_be;
wire [28:0] art_addr;
wire [63:0] art_din, art_dout;
wire        art_rd, art_we, art_busy, art_dout_ready;
artwork #(.IDX(8'd6)) artwork
(
	.clk(CLK_2X),
	.sel(status[83:80]), .layer_off({status[87], status[86:84]}), .side_off(status[88]), .zoom(status[89]),
	.crt_flip(status[22]), .hdmi_flip(status[11]), .turn(status[12]), .avail(art_avail),
	.hdmi_w(HDMI_WIDTH), .hdmi_h(HDMI_HEIGHT),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(a_wr),
	.ioctl_addr(a_addr), .ioctl_dout(a_dout), .ioctl_wait(art_wait),
	.ce_pix(ce_pix),
	.hs_in(v_px[27]), .vs_in(v_px[26]), .hblank_in(v_px[25]), .vblank_in(v_px[24]), .rgb_in(v_px[23:0]),
	.hs_out(av_hs), .vs_out(av_vs), .hblank_out(av_hbl), .vblank_out(av_vbl), .rgb_out({av_r, av_g, av_b}),
	.running(art_run), .ddr_owner(), .canvas_w(art_cw), .canvas_h(art_ch),
	.fb_base(art_fb_base), .fb_vbl(FB_VBL),
	.DDRAM_CLK(), .DDRAM_BUSY(art_busy), .DDRAM_BURSTCNT(art_burstcnt), .DDRAM_ADDR(art_addr),
	.DDRAM_DOUT(art_dout), .DDRAM_DOUT_READY(art_dout_ready), .DDRAM_RD(art_rd),
	.DDRAM_DIN(art_din), .DDRAM_BE(art_be), .DDRAM_WE(art_we)
);
assign art_fb = art_run & ~direct_video;

wire        sr_fb_en;
wire  [4:0] sr_fb_format;
wire [11:0] sr_fb_w, sr_fb_h;
wire [31:0] sr_fb_base;
wire [13:0] sr_fb_stride;
wire        sr_we;
wire [28:0] sr_addr;
wire [63:0] sr_din;
wire  [7:0] sr_be;
wire        ddr_byte_en, ddr_byte_rdy;
wire [24:0] ddr_byte_addr;
wire  [7:0] ddr_byte_q;

screen_rotate screen_rotate
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(flip), .video_rotated(video_rotated),
	.FB_EN(sr_fb_en), .FB_FORMAT(sr_fb_format), .FB_WIDTH(sr_fb_w), .FB_HEIGHT(sr_fb_h), .FB_BASE(sr_fb_base),
	.FB_STRIDE(sr_fb_stride), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(), .DDRAM_ADDR(sr_addr), .DDRAM_DIN(sr_din),
	.DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD()
);

assign FB_EN     = art_fb | sr_fb_en;
assign FB_FORMAT = art_fb ? 5'b00110    : sr_fb_format;
assign FB_WIDTH  = art_fb ? art_cw      : sr_fb_w;
assign FB_HEIGHT = art_fb ? art_ch      : sr_fb_h;
assign FB_BASE   = art_fb ? art_fb_base : sr_fb_base;
assign FB_STRIDE = art_fb ? 14'd8192    : sr_fb_stride;

wire        g_busy, g_dout_ready, g_rd, g_we;
wire [63:0] g_dout, g_din;
wire [28:0] g_addr;
wire  [7:0] g_be;
ddr_rom ddr_rom
(
	.clk(CLK_SYS),
	.ioctl_download(ioctl_download),
	.ioctl_wr0(ioctl_wr & (ioctl_index == 8'd0)),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ddr_ioctl_wait),
	.row_req(1'b0), .row_addr(25'd0), .row_q(), .row_rdy(),
	.byte_en(ddr_byte_en), .byte_addr(ddr_byte_addr), .byte_q(ddr_byte_q), .byte_rdy(ddr_byte_rdy),
	.sr_we(1'b0), .sr_addr(29'd0), .sr_din(64'd0), .sr_be(8'd0),
	.DDRAM_CLK(), .DDRAM_BUSY(g_busy), .DDRAM_BURSTCNT(), .DDRAM_ADDR(g_addr),
	.DDRAM_DOUT(g_dout), .DDRAM_DOUT_READY(g_dout_ready), .DDRAM_RD(g_rd), .DDRAM_DIN(g_din),
	.DDRAM_BE(g_be), .DDRAM_WE(g_we)
);

ddr_arb #(.CHUNK(8), .RWIN(64), .RWIN_G(32), .G_HOLD(4096), .SDEPTH(8)) ddr_arb
(
	.clk(CLK_2X), .clk_sys(CLK_SYS),
	.sr_we(sr_we & ~art_fb), .sr_addr(sr_addr), .sr_din(sr_din), .sr_be(sr_be),
	.g_rd(g_rd), .g_we(g_we), .g_addr(g_addr), .g_din(g_din), .g_be(g_be),
	.g_busy(g_busy), .g_dout(g_dout), .g_dout_ready(g_dout_ready),
	.a_rd(art_rd), .a_we(art_we), .a_burstcnt(art_burstcnt), .a_addr(art_addr), .a_din(art_din), .a_be(art_be),
	.a_busy(art_busy), .a_dout(art_dout), .a_dout_ready(art_dout_ready),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_2X),

	.RGB_in({av_r, av_g, av_b}),
	.HBlank(av_hbl),
	.VBlank(av_vbl),
	.HSync(av_hs),
	.VSync(av_vs),

	.fx(status[18:16])
);

wire       ms_ev;
wire [9:0] ms_dx;
/* verilator lint_off UNUSED */
wire [9:0] ms_dy;
wire [2:0] ms_btn;
/* verilator lint_on UNUSED */
ctl_mouse u_ms(.clk(CLK_SYS), .ps2_mouse(ps2_mouse), .ev(ms_ev), .dx(ms_dx), .dy(ms_dy), .btn(ms_btn));

wire       dial_tick1, dial_tick2;
ctl_tick #(.MODE(1), .DW(18)) u_dt1(.clk(CLK_SYS), .pause(pause_cpu), .vblank(1'b0),
	.period(game_cp ? 18'd75259 : 18'd188149), .tick(dial_tick1));
ctl_tick #(.MODE(1), .DW(18)) u_dt2(.clk(CLK_SYS), .pause(pause_cpu), .vblank(1'b0), .period(18'd75259), .tick(dial_tick2));
wire [7:0] dial_pos;
/* verilator lint_off UNUSED */
wire [7:0] dial_y1, dial_y2, dial_y3, dial_y4;
wire [1:0] dial_dir1, dial_dir2, dial_dir3, dial_dir4;
/* verilator lint_on UNUSED */
ctl_trackball #(.CW(8), .OUT_W(8), .DPAD_STEP(1)) u_dial1(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .rev(2'b01),
	.unit_sh(2'd0), .base_sh(4'd0), .speed(2'd0), .mouse_ev(ms_ev), .mouse_dx(ms_dx), .mouse_dy(10'd0), .spinner(spinner_0),
	.quad_ce(2'b00), .quad_dir(2'b00), .tick(dial_tick1), .stick_en(1'b1), .stick(16'd0), .dpad({2'b00, dir1_raw[1:0]}),
	.x(dial_pos), .y(dial_y1), .dir(dial_dir1));

wire [7:0] dial_p2, dial_p3, dial_p4;
ctl_trackball #(.CW(8), .OUT_W(8), .DPAD_STEP(1)) u_dial2(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .rev(2'b01),
	.unit_sh(2'd0), .base_sh(4'd0), .speed(2'd0), .mouse_ev(1'b0), .mouse_dx(10'd0), .mouse_dy(10'd0), .spinner(spinner_1),
	.quad_ce(2'b00), .quad_dir(2'b00), .tick(dial_tick2), .stick_en(1'b1), .stick(16'd0), .dpad({2'b00, joystick_1[1:0]}),
	.x(dial_p2), .y(dial_y2), .dir(dial_dir2));
ctl_trackball #(.CW(8), .OUT_W(8), .DPAD_STEP(1)) u_dial3(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .rev(2'b01),
	.unit_sh(2'd0), .base_sh(4'd0), .speed(2'd0), .mouse_ev(1'b0), .mouse_dx(10'd0), .mouse_dy(10'd0), .spinner(spinner_2),
	.quad_ce(2'b00), .quad_dir(2'b00), .tick(dial_tick2), .stick_en(1'b1), .stick(16'd0), .dpad({2'b00, joystick_2[1:0]}),
	.x(dial_p3), .y(dial_y3), .dir(dial_dir3));
ctl_trackball #(.CW(8), .OUT_W(8), .DPAD_STEP(1)) u_dial4(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .rev(2'b01),
	.unit_sh(2'd0), .base_sh(4'd0), .speed(2'd0), .mouse_ev(1'b0), .mouse_dx(10'd0), .mouse_dy(10'd0), .spinner(spinner_3),
	.quad_ce(2'b00), .quad_dir(2'b00), .tick(dial_tick2), .stick_en(1'b1), .stick(16'd0), .dpad({2'b00, joystick_3[1:0]}),
	.x(dial_p4), .y(dial_y4), .dir(dial_dir4));

wire [7:0] paddle_pos;
wire       pad_rev  = game_flags[5] ^ status[61];
wire [2:0] pad_sens = status[60:58];
wire pad_tick;
ctl_tick #(.MODE(0)) u_pt(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank), .period(18'd0), .tick(pad_tick));
ctl_paddle #(.PMIN(8'd64), .PMAX(8'd167), .PCEN(8'd115), .PAUSE_MODE(1)) u_paddle
(
	.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .tick(pad_tick), .sensitivity(pad_sens), .reverse(pad_rev),
	.paddle(paddle_0), .spinner(spinner_0), .mouse_ev(ms_ev), .mouse_dx(ms_dx), .stick_x(joystick_l_analog_0[7:0]),
	.left(dir1_raw[1]), .right(dir1_raw[0]), .pos(paddle_pos)
);

wire [7:0] sf_x, sf_y, sf_z;
wire [7:0] sf_ay  = joystick_l_analog_0[15:8];
wire [7:0] sf_ry  = joystick_r_analog_0[15:8];
wire       sf_std = status[75];
ctl_ad_stick #(.DZ(7'd16)) u_sf_x(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .tick(pad_tick),
	.rest(8'h80), .lo(8'h00), .hi(8'hFF), .keyd(8'd10), .stick(joystick_l_analog_0[7:0]),
	.inc(dir1_raw[0]), .dec(dir1_raw[1]), .val(sf_x));
ctl_ad_stick #(.DZ(7'd16)) u_sf_y(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .tick(pad_tick),
	.rest(8'h80), .lo(8'h00), .hi(8'hFF), .keyd(8'd10), .stick(sf_std ? sf_ay : 8'd0 - sf_ay),
	.inc(sf_std ? dir1_raw[2] : dir1_raw[3]), .dec(sf_std ? dir1_raw[3] : dir1_raw[2]), .val(sf_y));
ctl_ad_stick #(.DZ(7'd16), .HOLD(1'b1)) u_sf_z(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .tick(pad_tick),
	.rest(8'h80), .lo(8'h00), .hi(8'hFF), .keyd(8'd10), .stick(8'd0 - sf_ry),
	.inc(joystick_0[5]), .dec(joystick_0[6]), .val(sf_z));

wire [7:0] fo_p1, fo_p2;
ctl_paddle #(.PMIN(8'd0), .PMAX(8'd63), .PCEN(8'd32), .PAUSE_MODE(1)) fo_paddle1
(
	.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .tick(pad_tick), .sensitivity(pad_sens), .reverse(pad_rev),
	.paddle(paddle_0), .spinner(spinner_0), .mouse_ev(ms_ev), .mouse_dx(ms_dx), .stick_x(joystick_l_analog_0[7:0]),
	.left(dir1_raw[1]), .right(dir1_raw[0]), .pos(fo_p1)
);
ctl_paddle #(.PMIN(8'd0), .PMAX(8'd63), .PCEN(8'd32), .PAUSE_MODE(1)) fo_paddle2
(
	.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .tick(pad_tick), .sensitivity(pad_sens), .reverse(pad_rev),
	.paddle(paddle_1), .spinner(spinner_1), .mouse_ev(1'b0), .mouse_dx(10'd0), .stick_x(joystick_l_analog_1[7:0]),
	.left(dir2_raw[1]), .right(dir2_raw[0]), .pos(fo_p2)
);

exidy_dispatcher board
(
	.clk(CLK_SYS),
	.reset(reset),
	.pause(pause_cpu),
	.variant(game_var),
	.board_cfg(game_flags2),
	.board_cfg2(game_cfg2),
	.col_init({col_init[0], col_init[1], col_init[2]}),
	.ce_pix(bd_ce),

	.in0(in_port[0]),
	.dsw(in_port[1]),
	.in2(in_port[2]),
	.intsrc(in_port[3]),
	.coin(in_port[5]),
	.in3(in_port[4]),
	.in4(in_port[6]),
	.dial(dial_pos),
	.dial2(dial_p2),
	.dial3(dial_p3),
	.dial4(dial_p4),
	.paddle(paddle_pos),
	.stick_x(sf_x),
	.stick_y(sf_y),
	.throttle(sf_z),
	.pad1(fo_p1[5:0]),
	.pad2(fo_p2[5:0]),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr0(ioctl_wr & (ioctl_index == 8'd0)),

	.crt_flip(status[22]),
	.overlay_en(~status[57]),
	.h_adj(status[40:37]),
	.v_adj(status[44:41]),

	.vol_music(status[48:45] ^ 4'd8),
	.vol_sfx(status[52:49] ^ 4'd8),
	.vol_speech(status[56:53] ^ 4'd8),
	.ds_wr(ioctl_wr & (ioctl_index == 8'd5)), .ds_addr(ioctl_addr[12:0]), .ds_data(ioctl_dout), .ds_on(ds_on),
	.ds_caps({3'd0, status[74:70], 2'd0, status[69:64]}),

	.video_r(r),
	.video_g(g),
	.video_b(b),
	.video_hs(hs),
	.video_vs(vs),
	.video_hblank(hblank),
	.video_vblank(vblank),
	.vblank_raw(),

	.audio(audio),
	.audio_r(audio_r),
	.nv_wr(ioctl_wr & ioctl_download & (ioctl_index == 8'd4)),
	.nv_din(ioctl_dout),
	.nv_dout(nv_dout),
	.nv_saved(ioctl_upload & (ioctl_index == 8'd4)),
	.nv_dirty(nv_dirty),

	.hs_address(hs_address),
	.hs_data_in(hs_data_in),
	.hs_data_out(hs_data_out),
	.hs_write(hs_write_enable),

	.q_byte_en(ddr_byte_en),
	.q_byte_addr(ddr_byte_addr),
	.q_byte_q(ddr_byte_q),
	.q_byte_rdy(ddr_byte_rdy)
);

wire [15:0] hs_address;
wire  [7:0] hs_data_in;
wire  [7:0] hs_data_out;
wire        hs_write_enable;
wire        hs_access_read;
wire        hs_access_write;
wire        hs_pause;
wire        hs_configured;

wire        game_vic = (game_var == 8'd10);
wire  [7:0] nv_dout, hs_to_hps;
wire        nv_dirty, hs_upload_req;
assign ioctl_din        = game_vic ? nv_dout : hs_to_hps;
assign ioctl_upload_req = game_vic ? nv_dirty : hs_upload_req;

hiscore #(
	.HS_ADDRESSWIDTH(16),
	.CFG_ADDRESSWIDTH(4),
	.CFG_LENGTHWIDTH(2)
) hi (
	.*,
	.clk(CLK_SYS),
	.paused(pause_cpu),
	.autosave(status[21]),
	.ram_address(hs_address),
	.data_from_ram(hs_data_out),
	.data_to_ram(hs_data_in),
	.data_from_hps(ioctl_dout),
	.data_to_hps(hs_to_hps),
	.ioctl_upload_req(hs_upload_req),
	.ioctl_index(game_vic ? 8'hFF : ioctl_index),
	.ram_write(hs_write_enable),
	.ram_intent_read(hs_access_read),
	.ram_intent_write(hs_access_write),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

endmodule

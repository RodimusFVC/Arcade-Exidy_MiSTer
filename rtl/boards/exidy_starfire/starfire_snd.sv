//  Based on MAME nl_starfire.cpp, nl_fireone.cpp (Ryan Holtz, BSD-3-Clause)
module starfire_snd
(
    input  logic        clk,
    input  logic        reset,
    input  logic        fireone,      // 0 = Star Fire (mono), 1 = Fire One (stereo)
    input  logic        cpu_ce,
    input  logic        snd_wr,
    input  logic        snd_a0,
    input  logic        music_wr,
    input  logic  [1:0] music_a,
    input  logic  [7:0] din,
    output logic        tie_on_n,
    output logic        laser_on_n,
    output logic        player_sel,
    input  logic  [3:0] vol_music,    // OSD, 8 = unity, 0 = off, 15 = loudest (Fire One 8253 music)
    input  logic  [3:0] vol_sfx,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic  [7:0] lat0,
    output logic  [7:0] lat1,
    output logic  [2:0] pit_q,

    output chip_pool_pkg::pit8253_i_t pit8253_i,
    input  chip_pool_pkg::pit8253_o_t pit8253_o
);

    localparam logic signed [31:0] V5       = 32'sd83886080;
    localparam logic signed [31:0] V12      = 32'sd201326592;
    localparam logic signed [31:0] VTH5     = 32'sd55924053;
    localparam logic signed [31:0] VTL5     = 32'sd27962027;
    localparam logic signed [31:0] VOH5     = 32'sd55364813;
    localparam logic signed [31:0] VOPCL    = 32'sd174483046;
    localparam logic signed [31:0] ZOFF     = 32'sd20937966;
    localparam logic signed [26:0] ZK       = 27'sd4654694;
    localparam logic signed [26:0] KMCLP    = 27'sd311405;
    localparam logic signed [31:0] VE5      = 32'sd83886080;
    localparam logic signed [31:0] K45      = 32'sd129;
    localparam logic signed [31:0] VT45     = 32'sd25853690;
    localparam logic signed [26:0] NC3      = -27'sd13773;
    localparam logic signed [26:0] NC2      = 27'sd47394;
    localparam logic signed [26:0] NC1      = -27'sd413549;
    localparam logic signed [31:0] NC0      = 32'sd930674;
    localparam logic signed [31:0] VN12     = 32'sd201326592;
    localparam logic signed [31:0] VN6      = 32'sd100663296;
    localparam logic signed [26:0] K29      = 27'sd18168;
    localparam logic signed [26:0] K29S     = 27'sd18585;
    localparam logic signed [26:0] GN       = -27'sd4326503;
    localparam logic signed [26:0] GNS      = -27'sd4425841;
    localparam logic signed [26:0] SVF_F    = 27'sd118886;
    localparam logic signed [26:0] SVF_QD   = 27'sd6710886;
    localparam logic signed [26:0] SVF_K    = 27'sd2726298;
    localparam logic signed [31:0] VSZ      = 32'sd63250104;
    localparam logic signed [26:0] K18C     = 27'sd189144;
    localparam logic signed [26:0] K18D     = 27'sd190;
    localparam logic signed [31:0] VSZT     = 32'sd33554432;
    localparam logic signed [26:0] KE1D_S   = 27'sd70303;
    localparam logic signed [26:0] KE1C_S   = 27'sd95;
    localparam logic signed [26:0] KE2D_S   = 27'sd70303;
    localparam logic signed [26:0] KE2C_S   = 27'sd202;
    localparam logic signed [31:0] CLE_S    = 32'sd102672770;
    localparam logic signed [31:0] CLB_F    = 32'sd95509554;
    localparam logic signed [31:0] CLH_S    = 32'sd12918376;
    localparam logic signed [31:0] K32S     = 32'sd1290;
    localparam logic signed [31:0] K32F     = 32'sd2994;
    localparam logic signed [31:0] VT32     = 32'sd25853690;
    localparam logic signed [31:0] KL0      = 32'sd6959380;
    localparam logic signed [26:0] KL8      = -27'sd3483581;
    localparam logic signed [31:0] TRI8     = 32'sd67108864;
    localparam logic signed [26:0] K7C      = 27'sd2023;
    localparam logic signed [26:0] K7D      = 27'sd4047;
    localparam logic signed [26:0] K12C     = 27'sd314053;
    localparam logic signed [26:0] K12D     = 27'sd622228;
    localparam logic signed [31:0] VCVH     = 32'sd62914560;
    localparam logic signed [31:0] VCVL     = 32'sd41943040;
    localparam logic signed [31:0] VCVH2    = 32'sd31457280;
    localparam logic signed [31:0] VCVL2    = 32'sd20971520;
    localparam logic signed [26:0] K15C     = 27'sd395964;
    localparam logic signed [26:0] K15D     = 27'sd399876;
    localparam logic signed [26:0] K13      = 27'sd33338;
    localparam logic signed [31:0] VS11     = 32'sd5033165;
    localparam logic signed [26:0] K9       = 27'sd101907;
    localparam logic signed [26:0] GT       = 27'sd97590;
    localparam logic signed [26:0] GL       = -27'sd29570;
    localparam logic signed [26:0] GS       = 27'sd289900;
    localparam logic signed [26:0] K51      = 27'sd118886;
    localparam logic signed [26:0] GE       = -27'sd515398;
    localparam logic signed [26:0] GC       = 27'sd16846;
    localparam logic signed [26:0] GH       = -27'sd409628;
    localparam logic signed [26:0] KHO_S    = 27'sd1893;
    localparam logic signed [26:0] OSF      = 27'sd2048000;
    localparam logic signed [31:0] NINC_F   = 32'sd190218;
    localparam logic signed [26:0] K45F     = 27'sd19011;
    localparam logic signed [26:0] GFI      = -27'sd4529848;
    localparam logic signed [26:0] KE1D_F   = 27'sd63286;
    localparam logic signed [26:0] KE1C_F   = 27'sd95;
    localparam logic signed [31:0] VLM      = 32'sd8388608;
    localparam logic signed [31:0] VCH      = 32'sd73819750;
    localparam logic signed [31:0] VOHI     = 32'sd181193933;
    localparam logic signed [26:0] KT7C     = 27'sd566628;
    localparam logic signed [26:0] KT7D     = 27'sd848;
    localparam logic signed [26:0] KT14C    = 27'sd86240;
    localparam logic signed [26:0] KT14D    = 27'sd127;
    localparam logic signed [26:0] K034     = 27'sd5704253;
    localparam logic signed [31:0] VIB      = 32'sd23428184;
    localparam logic signed [26:0] KINT     = 27'sd280;
    localparam logic signed [26:0] GTG      = 27'sd1850428;
    localparam logic signed [31:0] VGT_L    = -32'sd47325599;
    localparam logic signed [31:0] VGT_H    = -32'sd273959661;
    localparam logic signed [26:0] KH1      = 27'sd86240;
    localparam logic signed [26:0] KH2      = 27'sd239140;
    localparam logic signed [26:0] KP13C    = 27'sd40423;
    localparam logic signed [26:0] KP13D    = 27'sd60;
    localparam logic signed [31:0] VGP_L    = -32'sd73192909;
    localparam logic signed [31:0] VGP_H    = -32'sd405049929;
    localparam logic signed [26:0] KPL1     = 27'sd5857641;
    localparam logic signed [26:0] KPL2     = 27'sd473537;
    localparam logic signed [26:0] KC11C    = 27'sd86240;
    localparam logic signed [26:0] KC11D    = 27'sd393;
    localparam logic signed [26:0] GCG      = 27'sd3908329;
    localparam logic signed [31:0] VGC_L    = -32'sd41963855;
    localparam logic signed [31:0] VGC_H    = -32'sd246787435;
    localparam logic signed [26:0] KCL1     = 27'sd480717;
    localparam logic signed [26:0] KCL2     = 27'sd480717;
    localparam logic signed [31:0] VAC      = 32'sd63936095;
    localparam logic signed [31:0] VAD      = 32'sd25026786;
    localparam logic signed [26:0] KAC      = 27'sd36317;
    localparam logic signed [26:0] KAD      = 27'sd57862;
    localparam logic signed [26:0] KBC      = 27'sd126334;
    localparam logic signed [26:0] KBD      = 27'sd230377;
    localparam logic signed [26:0] KSL1     = 27'sd622228;
    localparam logic signed [26:0] KSL2     = 27'sd622228;
    localparam logic signed [31:0] V8I      = 32'sd194615706;
    localparam logic signed [31:0] V8M      = 32'sd135895450;
    localparam logic signed [31:0] KP8S     = 32'sd1519;
    localparam logic signed [26:0] KP8C     = 27'sd189144;
    localparam logic signed [31:0] VA38     = 32'sd941207;
    localparam logic signed [31:0] TA4      = 32'sd67108864;
    localparam logic signed [31:0] TA8      = 32'sd134217728;
    localparam logic signed [26:0] KAL      = 27'sd1798308;
    localparam logic signed [26:0] K72C     = 27'sd1801;
    localparam logic signed [26:0] K72D     = 27'sd1840;
    localparam logic signed [31:0] VT8      = 32'sd134217728;
    localparam logic signed [31:0] VT4      = 32'sd67108864;
    localparam logic signed [31:0] V100     = 32'sd21434010;
    localparam logic signed [26:0] K100     = 27'sd171907;
    localparam logic signed [26:0] F2       = 27'sd908221;
    localparam logic signed [26:0] QD2      = 27'sd1398101;
    localparam logic signed [26:0] NQD2     = -27'sd1398101;
    localparam logic signed [26:0] GN100    = 27'sd15157301;
    localparam logic signed [31:0] VD1      = 32'sd128273353;
    localparam logic signed [31:0] VD2      = 32'sd97087630;
    localparam logic signed [31:0] VD4      = 32'sd107437072;
    localparam logic signed [31:0] VD9      = 32'sd78389271;
    localparam logic signed [26:0] GTC      = 27'sd1467143;
    localparam logic signed [26:0] GSE      = 27'sd502135;
    localparam logic signed [26:0] GSON     = 27'sd264086;
    localparam logic signed [26:0] GAL      = 27'sd127327;
    localparam logic signed [26:0] GBM      = -27'sd2004019;
    localparam logic signed [26:0] GSH      = 27'sd409788;
    localparam logic signed [26:0] GTP      = 27'sd127327;
    localparam logic signed [26:0] GMU      = 27'sd10084305;
    localparam logic signed [26:0] KHIL     = 27'sd21663;
    localparam logic signed [26:0] KHIR     = 27'sd19130;
    localparam logic signed [31:0] VBF      = 32'sd108432438;
    localparam logic signed [31:0] VMX      = 32'sd194615706;
    localparam logic signed [26:0] KC121    = 27'sd2576556;
    localparam logic signed [26:0] KHO_F    = 27'sd18106;
    localparam logic signed [26:0] OFO      = 27'sd633379;
    function automatic logic signed [31:0] mant(input logic [4:0] i);
        case (i)
            5'd0: mant = 32'sd16777216;  5'd1: mant = 32'sd16417715;  5'd2: mant = 32'sd16065917;  5'd3: mant = 32'sd15721658;
            5'd4: mant = 32'sd15384775;  5'd5: mant = 32'sd15055111;  5'd6: mant = 32'sd14732511;  5'd7: mant = 32'sd14416824;
            5'd8: mant = 32'sd14107901;  5'd9: mant = 32'sd13805598;  5'd10: mant = 32'sd13509772;  5'd11: mant = 32'sd13220286;
            5'd12: mant = 32'sd12937002;  5'd13: mant = 32'sd12659789;  5'd14: mant = 32'sd12388516;  5'd15: mant = 32'sd12123055;
            5'd16: mant = 32'sd11863283;  5'd17: mant = 32'sd11609078;  5'd18: mant = 32'sd11360319;  5'd19: mant = 32'sd11116891;
            5'd20: mant = 32'sd10878679;  5'd21: mant = 32'sd10645571;  5'd22: mant = 32'sd10417458;  5'd23: mant = 32'sd10194234;
            5'd24: mant = 32'sd9975792;  5'd25: mant = 32'sd9762032;  5'd26: mant = 32'sd9552851;  5'd27: mant = 32'sd9348154;
            5'd28: mant = 32'sd9147842;  5'd29: mant = 32'sd8951823;  5'd30: mant = 32'sd8760003;  default: mant = 32'sd8572295;
        endcase
    endfunction
    function automatic logic signed [26:0] hlut(input logic [5:0] i);
        case (i)
            6'd0: hlut = 27'sd8388608;  6'd1: hlut = 27'sd8751790;  6'd2: hlut = 27'sd9113612;  6'd3: hlut = 27'sd9472737;
            6'd4: hlut = 27'sd9827866;  6'd5: hlut = 27'sd10177757;  6'd6: hlut = 27'sd10521246;  6'd7: hlut = 27'sd10857255;
            6'd8: hlut = 27'sd11184811;  6'd9: hlut = 27'sd11503046;  6'd10: hlut = 27'sd11811213;  6'd11: hlut = 27'sd12108681;
            6'd12: hlut = 27'sd12394942;  6'd13: hlut = 27'sd12669605;  6'd14: hlut = 27'sd12932393;  6'd15: hlut = 27'sd13183138;
            6'd16: hlut = 27'sd13421773;  6'd17: hlut = 27'sd13648324;  6'd18: hlut = 27'sd13862900;  6'd19: hlut = 27'sd14065685;
            6'd20: hlut = 27'sd14256924;  6'd21: hlut = 27'sd14436920;  6'd22: hlut = 27'sd14606018;  6'd23: hlut = 27'sd14764602;
            6'd24: hlut = 27'sd14913081;  6'd25: hlut = 27'sd15051886;  6'd26: hlut = 27'sd15181461;  6'd27: hlut = 27'sd15302259;
            6'd28: hlut = 27'sd15414733;  6'd29: hlut = 27'sd15519335;  6'd30: hlut = 27'sd15616512;  6'd31: hlut = 27'sd15706699;
            6'd32: hlut = 27'sd15790321;  6'd33: hlut = 27'sd15867789;  6'd34: hlut = 27'sd15939499;  6'd35: hlut = 27'sd16005830;
            6'd36: hlut = 27'sd16067142;  6'd37: hlut = 27'sd16123780;  6'd38: hlut = 27'sd16176069;  6'd39: hlut = 27'sd16224318;
            6'd40: hlut = 27'sd16268816;  6'd41: hlut = 27'sd16309835;  6'd42: hlut = 27'sd16347633;  6'd43: hlut = 27'sd16382447;
            6'd44: hlut = 27'sd16414503;  6'd45: hlut = 27'sd16444009;  6'd46: hlut = 27'sd16471159;  6'd47: hlut = 27'sd16496135;
            6'd48: hlut = 27'sd16519105;  6'd49: hlut = 27'sd16540225;  6'd50: hlut = 27'sd16559639;  6'd51: hlut = 27'sd16577482;
            6'd52: hlut = 27'sd16593878;  6'd53: hlut = 27'sd16608942;  6'd54: hlut = 27'sd16622779;  6'd55: hlut = 27'sd16635488;
            6'd56: hlut = 27'sd16647160;  6'd57: hlut = 27'sd16657877;  6'd58: hlut = 27'sd16667717;  6'd59: hlut = 27'sd16676751;
            6'd60: hlut = 27'sd16685043;  6'd61: hlut = 27'sd16692655;  6'd62: hlut = 27'sd16699640;  default: hlut = 27'sd16706052;
        endcase
    endfunction

    logic [7:0] sfl, l0, l1;
    always_ff @(posedge clk) begin
        if (reset) begin
            sfl <= 8'h00; l0 <= 8'h00; l1 <= 8'h00;
        end else if (snd_wr) begin
            if (!fireone)    sfl <= din;
            else if (snd_a0) l1  <= din;
            else             l0  <= din;
        end
    end
    assign player_sel = l0[3];
    assign lat0 = fireone ? l0 : sfl;
    assign lat1 = l1;

    wire fo       = fireone;
    wire s_size   = ~fo & sfl[0];
    wire s_explo  = ~fo & sfl[1];
    wire s_tie    = ~fo & sfl[2];
    wire s_laser  = ~fo & sfl[3];
    wire s_track  = ~fo & sfl[4];
    wire s_lock   = ~fo & sfl[5];
    wire s_scan   = ~fo & sfl[6];
    wire s_oheat  = ~fo & sfl[7];
    wire f_ltorp  = fo & l0[0];
    wire f_lshp   = fo & l0[1];
    wire f_lboom  = fo & l0[2];
    wire f_soff   = fo & l0[7];
    wire f_rtorp  = fo & l1[0];
    wire f_rshp   = fo & l1[1];
    wire f_rboom  = fo & l1[2];
    wire f_tcoll  = fo & l1[3];
    wire f_sub    = fo & l1[4];
    wire f_alert  = fo & l1[5];
    wire f_sync   = l1[6];
    wire f_sonen  = l1[7];

    logic [2:0] pit_out;
    assign pit8253_i.rst    = reset;
    assign pit8253_i.wr_en  = music_wr & fireone;
    assign pit8253_i.a      = music_a;
    assign pit8253_i.din    = din;
    assign pit8253_i.clk_ce = cpu_ce;
    assign pit8253_i.gate   = l0[6:4];
    assign pit_out = pit8253_o.out;
    assign pit_q = pit_out;

    logic [7:0] cdiv;
    logic [9:0] macc, msum;
    logic       tick;
    wire  [9:0] mnow = {9'd0, pit_out[0]} + {9'd0, pit_out[1]} + {9'd0, pit_out[2]};
    always_ff @(posedge clk) begin
        tick <= 1'b0;
        if (reset) begin
            cdiv <= 8'd0; macc <= 10'd0; msum <= 10'd0;
        end else begin
            cdiv <= cdiv + 8'd1;
            if (cdiv == 8'd255) begin
                msum <= macc + mnow;
                macc <= 10'd0;
                tick <= 1'b1;
            end else begin
                macc <= macc + mnow;
            end
        end
    end

    /* verilator lint_off UNUSED */
    function automatic logic signed [26:0] q(input logic signed [31:0] x);
        q = x[31:5];
    endfunction
    /* verilator lint_on UNUSED */
    function automatic logic signed [31:0] clamp(input logic signed [31:0] x, input logic signed [31:0] lo, input logic signed [31:0] hi);
        clamp = (x < lo) ? lo : (x > hi) ? hi : x;
    endfunction
    function automatic logic signed [31:0] pos(input logic signed [31:0] x);
        pos = x[31] ? 32'sd0 : x;
    endfunction

    logic [3:0]  sr1, sr3, sr4;
    logic [4:0]  sr2;
    logic [23:0] nph;
    logic signed [31:0] t1, c29, nsf, lp, hp, bp, rum;
    logic signed [31:0] e1, z1, m1, y1, o1, e2, z2, m2, y2, o2;
    logic signed [31:0] v45, c18, r2, v32, dl, ltri, c7, c15, c12, c13, c9, mx, hpo;
    logic        tie_q, tie_d, las_q, las_d, trdir, lockq, scanq, trq;
    logic signed [31:0] tc7l, tc14l, vol_, vgl, h1l, h2l, tc7r, tc14r, vor, vgr, h1r, h2r;
    logic signed [31:0] pc13l, pgl, pl1l, pl2l, pc13r, pgr, pl1r, pl2r;
    logic signed [31:0] cc11, cg, cl1, cl2, c85, c84, sl1, sl2, p8, tra, al, c72, c100, lp2, hp2, bp2, son;
    logic signed [31:0] t2, tl, tr, hinl, hinr, vml, vmr, hol, hor;
    logic        sa, sb, tadir, aq, s5, ffq;
    logic [3:0]  cnt;
    logic [12:0] wcnt;
    wire         warm = wcnt[12];

    localparam logic [7:0] SC_END = 8'd195;
    logic [7:0] sc;
    logic       run;
    wire  [6:0] op = sc[7:1];

    wire na  = sr3[3];
    wire d2i = sr2[4] ^ sr4[3];
    wire d3i = fo ? (sr1[3] ^ ~f_sync) : ~sr1[3];

    wire nhi    = lockq & scanq & s_scan;
    wire sizesw = (c18 > VSZT);
    wire signed [31:0] vth  = na ? (s_size ? VN6 : VN12) : 32'sd0;
    wire signed [31:0] vsrc = fo ? (na ? VN12 : 32'sd0) : vth;
    wire signed [31:0] vtrk = trq ? VOH5 : 32'sd0;
    wire signed [31:0] vloh = (scanq & s_scan) ? VS11 : 32'sd0;
    wire signed [31:0] cvh  = nhi ? VCVH  : VCVL;
    wire signed [31:0] cvl  = nhi ? VCVH2 : VCVL2;

    wire signed [31:0] az1 = z1[31] ? -z1 : z1;
    wire signed [31:0] az2 = z2[31] ? -z2 : z2;
    wire        [5:0]  hi1 = (az1[31:27] != 5'd0) ? 6'd63 : az1[26:21];
    wire        [5:0]  hi2 = (az2[31:27] != 5'd0) ? 6'd63 : az2[26:21];
    wire signed [31:0] mn1 = z1[31] ? 32'sd16777216 : mant(z1[23:19]);
    wire signed [31:0] mn2 = z2[31] ? 32'sd16777216 : mant(z2[23:19]);
    wire        [4:0]  sh1 = z1[31] ? 5'd0 : z1[28:24];
    wire        [4:0]  sh2 = z2[31] ? 5'd0 : z2[28:24];
    wire               mu1 = ~z1[31] & (z1[30:24] >= 7'd24);
    wire               mu2 = ~z2[31] & (z2[30:24] >= 7'd24);
    wire signed [31:0] cl1v = fo ? CLB_F : CLE_S;
    wire signed [31:0] cl2v = fo ? CLB_F : CLH_S;
    wire               trg1 = fo ? f_lboom : s_explo;
    wire               trg2 = fo ? f_rboom : s_oheat;
    wire signed [26:0] ke1d = fo ? KE1D_F : KE1D_S;
    wire signed [26:0] ke1c = fo ? KE1C_F : KE1C_S;
    wire signed [26:0] ke2d = fo ? KE1D_F : KE2D_S;
    wire signed [26:0] ke2c = fo ? KE1C_F : KE2C_S;
    wire signed [31:0] in2  = fo ? rum : (vloh - c9);

    wire signed [31:0] vgtn = na ? VGT_H : VGT_L;
    wire signed [31:0] vgpn = na ? VGP_H : VGP_L;
    wire signed [31:0] vgcn = na ? VGC_H : VGC_L;
    wire               cvalid = (cnt == 4'd1) | (cnt == 4'd2) | (cnt == 4'd4) | (cnt == 4'd9);
    wire signed [31:0] vdk  = (cnt == 4'd1) ? VD1 : (cnt == 4'd2) ? VD2 : (cnt == 4'd4) ? VD4 : VD9;
    wire signed [31:0] vdrv = (s5 & ffq & cvalid & ~bp2[31]) ? vdk : 32'sd0;
    wire signed [31:0] vsub = sb ? VOH5 : 32'sd0;
    wire signed [31:0] vfa  = aq ? V12 : 32'sd0;
    wire signed [31:0] vtgl = vgl - h1l - h2l;
    wire signed [31:0] vtgr = vgr - h1r - h2r;
    wire signed [31:0] vmlt = f_soff ? 32'sd0 : clamp(VBF - (tl - hinl), 32'sd0, VMX);
    wire signed [31:0] vmrt = f_soff ? 32'sd0 : clamp(VBF - (tr - hinr), 32'sd0, VMX);
    wire signed [31:0] vmus = {6'd0, msum, 16'd0};

    logic signed [26:0] a_n, b_n, ma, mb;
    always_comb begin
        a_n = 27'sd0; b_n = 27'sd0;
        case (op)
            7'd0:  begin a_n = q(v45);                         b_n = NC3;    end
            7'd1:  begin a_n = q(v45);                         b_n = t1[26:0]; end
            7'd2:  begin a_n = q(v45);                         b_n = t1[26:0]; end
            7'd3:  begin a_n = q(vsrc - c29);                  b_n = fo ? K45F : (s_size ? K29S : K29); end
            7'd4:  begin a_n = q(vsrc - c29);                  b_n = fo ? GFI  : (s_size ? GNS : GN);   end
            7'd5:  begin a_n = q(bp);                          b_n = SVF_F;  end
            7'd6:  begin a_n = q(bp);                          b_n = SVF_QD; end
            7'd7:  begin a_n = q(hp);                          b_n = SVF_F;  end
            7'd8:  begin a_n = q(lp);                          b_n = SVF_K;  end
            7'd9:  begin a_n = s_size ? q(VSZ - c18) : q(-c18); b_n = s_size ? K18C : K18D; end
            7'd10: begin a_n = trg1 ? q(-e1) : q(VE5 - e1);    b_n = trg1 ? ke1d : ke1c; end
            7'd11: begin a_n = q(e1 - ZOFF);                   b_n = ZK;     end
            7'd12: begin a_n = q(mn1);                         b_n = hlut(hi1); end
            7'd13: begin a_n = q(rum - y1);                    b_n = KMCLP;  end
            7'd14: begin a_n = q(y1);                          b_n = m1[26:0]; end
            7'd15: begin a_n = q(v32);                         b_n = KL8;    end
            7'd16: begin a_n = lockq ? q(V5 - c7) : q(-c7);    b_n = lockq ? K7C : K7D; end
            7'd17: begin a_n = nhi ? q(V5 - c15) : q(-c15);    b_n = nhi ? K15C : K15D; end
            7'd18: begin a_n = trq ? q(V5 - c12) : q(-c12);    b_n = trq ? K12C : K12D; end
            7'd19: begin a_n = q(vtrk - c13);                  b_n = K13;    end
            7'd20: begin a_n = q(vloh - c9);                   b_n = K9;     end
            7'd21: begin a_n = trg2 ? q(-e2) : q(VE5 - e2);    b_n = trg2 ? ke2d : ke2c; end
            7'd22: begin a_n = q(e2 - ZOFF);                   b_n = ZK;     end
            7'd23: begin a_n = q(mn2);                         b_n = hlut(hi2); end
            7'd24: begin a_n = q(in2 - y2);                    b_n = KMCLP;  end
            7'd25: begin a_n = q(y2);                          b_n = m2[26:0]; end
            7'd26: begin a_n = tie_q ? q(nsf) : 27'sd0;        b_n = GT;     end
            7'd27: begin a_n = las_q ? q(ltri) : 27'sd0;        b_n = GL;     end
            7'd28: begin a_n = sizesw ? q(r2) : 27'sd0;        b_n = GS;     end
            7'd29: begin a_n = q(o1);                          b_n = GE;     end
            7'd30: begin a_n = s_track ? q(vtrk - c13) : 27'sd0; b_n = GC;   end
            7'd31: begin a_n = q(o2);                          b_n = GH;     end
            7'd32: begin a_n = q(t1);                          b_n = $signed({6'd0, vol_sfx, 17'd0}); end
            7'd33: begin a_n = q(mx - hpo);                    b_n = KHO_S;  end
            7'd34: begin a_n = q(mx - hpo);                    b_n = OSF;    end
            7'd35: begin a_n = f_ltorp ? q(VCH - tc7l)  : q(VLM - tc7l);  b_n = f_ltorp ? KT7C  : KT7D;  end
            7'd36: begin a_n = f_ltorp ? q(VCH - tc14l) : q(VLM - tc14l); b_n = f_ltorp ? KT14C : KT14D; end
            7'd37: begin a_n = q(vol_ - VLM);                  b_n = K034;   end
            7'd38: begin a_n = q(pos(tc14l - VLM) - t2 - VIB); b_n = KINT;   end
            7'd39: begin a_n = q(pos(tc7l - VLM) + pos(vol_ - VLM)); b_n = GTG; end
            7'd40: begin a_n = q(vgl - h1l);                   b_n = KH1;    end
            7'd41: begin a_n = q(vgl - h1l - h2l);             b_n = KH2;    end
            7'd42: begin a_n = f_rtorp ? q(VCH - tc7r)  : q(VLM - tc7r);  b_n = f_rtorp ? KT7C  : KT7D;  end
            7'd43: begin a_n = f_rtorp ? q(VCH - tc14r) : q(VLM - tc14r); b_n = f_rtorp ? KT14C : KT14D; end
            7'd44: begin a_n = q(vor - VLM);                   b_n = K034;   end
            7'd45: begin a_n = q(pos(tc14r - VLM) - t2 - VIB); b_n = KINT;   end
            7'd46: begin a_n = q(pos(tc7r - VLM) + pos(vor - VLM)); b_n = GTG; end
            7'd47: begin a_n = q(vgr - h1r);                   b_n = KH1;    end
            7'd48: begin a_n = q(vgr - h1r - h2r);             b_n = KH2;    end
            7'd49: begin a_n = f_lshp ? q(VCH - pc13l) : q(VLM - pc13l); b_n = f_lshp ? KP13C : KP13D; end
            7'd50: begin a_n = q(pos(pc13l - VLM));            b_n = GTG;    end
            7'd51: begin a_n = q(pgl - pl1l);                  b_n = KPL1;   end
            7'd52: begin a_n = q(pl1l - pl2l);                 b_n = KPL2;   end
            7'd53: begin a_n = f_rshp ? q(VCH - pc13r) : q(VLM - pc13r); b_n = f_rshp ? KP13C : KP13D; end
            7'd54: begin a_n = q(pos(pc13r - VLM));            b_n = GTG;    end
            7'd55: begin a_n = q(pgr - pl1r);                  b_n = KPL1;   end
            7'd56: begin a_n = q(pl1r - pl2r);                 b_n = KPL2;   end
            7'd57: begin a_n = f_tcoll ? q(VCH - cc11) : q(VLM - cc11);  b_n = f_tcoll ? KC11C : KC11D; end
            7'd58: begin a_n = q(pos(cc11 - VLM));             b_n = GCG;    end
            7'd59: begin a_n = q(cg - cl1);                    b_n = KCL1;   end
            7'd60: begin a_n = q(cl1 - cl2);                   b_n = KCL2;   end
            7'd61: begin a_n = sa ? q(VAC - c85) : q(VAD - c85); b_n = sa ? KAC : KAD; end
            7'd62: begin a_n = sb ? q(V5 - c84) : q(-c84);     b_n = sb ? KBC : KBD; end
            7'd63: begin a_n = q(vsub - sl1);                  b_n = KSL1;   end
            7'd64: begin a_n = q(sl1 - sl2);                   b_n = KSL2;   end
            7'd65: begin a_n = q(V8I - p8);                    b_n = KP8C;   end
            7'd66: begin a_n = q(V12 - p8);                    b_n = VA38[26:0]; end
            7'd67: begin a_n = q(vfa - al);                    b_n = KAL;    end
            7'd68: begin a_n = s5 ? q(V12 - c72) : q(-c72);    b_n = s5 ? K72C : K72D; end
            7'd69: begin a_n = na ? q(V100 - c100) : q(-c100); b_n = K100;   end
            7'd70: begin a_n = q(c100);                        b_n = GN100;  end
            7'd71: begin a_n = q(bp2);                         b_n = F2;     end
            7'd72: begin a_n = q(bp2);                         b_n = QD2;    end
            7'd73: begin a_n = q(hp2);                         b_n = F2;     end
            7'd74: begin a_n = q(bp2);                         b_n = NQD2;   end
            7'd75: begin a_n = sizesw ? q(rum - (r2 + r2 - (r2 >>> 4))) : q(rum - r2); b_n = K51; end
            7'd76: begin a_n = q(cl2);                         b_n = GTC;    end
            7'd77: begin a_n = q(sl2);                         b_n = GSE;    end
            7'd78: begin a_n = q(son);                         b_n = GSON;   end
            7'd79: begin a_n = q(al);                          b_n = GAL;    end
            7'd80: begin a_n = q(o1);                          b_n = GBM;    end
            7'd81: begin a_n = q(pl2l + pl2r);                 b_n = GSH;    end
            7'd82: begin a_n = q(vtgl);                        b_n = GTP;    end
            7'd83: begin a_n = q(o2);                          b_n = GBM;    end
            7'd84: begin a_n = q(vtgr);                        b_n = GTP;    end
            7'd85: begin a_n = q(tl);                          b_n = $signed({6'd0, vol_sfx, 17'd0}); end
            7'd86: begin a_n = q(tr);                          b_n = $signed({6'd0, vol_sfx, 17'd0}); end
            7'd87: begin a_n = q(vmus);                        b_n = GMU;    end
            7'd88: begin a_n = q(t2);                          b_n = $signed({6'd0, vol_music, 17'd0}); end
            7'd90: begin a_n = q(tl - hinl);                   b_n = KHIL;   end
            7'd91: begin a_n = q(tr - hinr);                   b_n = KHIR;   end
            7'd92: begin a_n = q(vmlt - vml);                  b_n = KC121;  end
            7'd93: begin a_n = q(vmrt - vmr);                  b_n = KC121;  end
            7'd94: begin a_n = q(vml - hol);                   b_n = KHO_F;  end
            7'd95: begin a_n = q(vmr - hor);                   b_n = KHO_F;  end
            7'd96: begin a_n = q(vml - hol);                   b_n = OFO;    end
            7'd97: begin a_n = q(vmr - hor);                   b_n = OFO;    end
            default: ;
        endcase
    end

    wire signed [53:0] prod = ma * mb;
    wire signed [31:0] p24  = prod[50:19];
    wire signed [31:0] p20  = prod[46:15];
    wire signed [26:0] pq8  = prod[53:27];

    wire signed [31:0] atrn = tadir ? tra + p24 : tra - p24;
    wire signed [31:0] ninc = fo ? (f_sonen ? NINC_F : 32'sd0) : (NC0 + p24);
    wire        [24:0] nphn = {1'b0, nph} + {1'b0, ninc[23:0]};
    wire signed [31:0] mo1  = p24 >>> sh1;
    wire signed [31:0] mo2  = p24 >>> sh2;
    wire signed [26:0] pabs = pq8[26] ? -pq8 : pq8;
    wire signed [26:0] plim = (pabs > 27'sd52000) ? 27'sd28000 + ((pabs - 27'sd52000) >>> 4) :
                              (pabs > 27'sd20000) ? 27'sd20000 + ((pabs - 27'sd20000) >>> 2) : pabs;
    wire signed [26:0] psat = (plim > 27'sd32767) ? 27'sd32767 : plim;
    wire signed [26:0] pout = pq8[26] ? -psat : psat;
    wire signed [26:0] fsat = (pq8 > 27'sd32767) ? 27'sd32767 : (pq8 < -27'sd32768) ? -27'sd32768 : pq8;

    /* verilator lint_off UNUSED */
    wire unused_ok = &{1'b0, prod[53:51], prod[16:0], z1[31:29], z2[31:29], m1[31:27], m2[31:27], t1[31:27],
                       ninc[31:24], az1[20:0], az2[20:0], pout[26:16], fsat[26:16], VA38[31:27]};
    /* verilator lint_on UNUSED */

    always_ff @(posedge clk) begin
        if (reset) begin
            sc <= 8'd0; run <= 1'b0; ma <= 27'sd0; mb <= 27'sd0;
            sr1 <= 4'b0101; sr2 <= 5'b10110; sr3 <= 4'b1001; sr4 <= 4'b0011; nph <= 24'd0;
            t1 <= 32'sd0; c29 <= 32'sd0; nsf <= 32'sd0; lp <= 32'sd0; hp <= 32'sd0; bp <= 32'sd0; rum <= 32'sd0;
            e1 <= VE5; z1 <= 32'sd0; m1 <= 32'sd0; y1 <= 32'sd0; o1 <= 32'sd0;
            e2 <= VE5; z2 <= 32'sd0; m2 <= 32'sd0; y2 <= 32'sd0; o2 <= 32'sd0;
            v45 <= 32'sd0; c18 <= 32'sd0; r2 <= 32'sd0; v32 <= 32'sd0; dl <= 32'sd0; ltri <= 32'sd0;
            c7 <= 32'sd0; c15 <= 32'sd0; c12 <= 32'sd0; c13 <= 32'sd0; c9 <= 32'sd0; mx <= 32'sd0; hpo <= 32'sd0;
            tie_q <= 1'b0; tie_d <= 1'b0; las_q <= 1'b0; las_d <= 1'b0; trdir <= 1'b1;
            lockq <= 1'b0; scanq <= 1'b0; trq <= 1'b0;
            tc7l <= VLM; tc14l <= VLM; vol_ <= 32'sd0; vgl <= 32'sd0; h1l <= 32'sd0; h2l <= 32'sd0;
            tc7r <= VLM; tc14r <= VLM; vor <= 32'sd0; vgr <= 32'sd0; h1r <= 32'sd0; h2r <= 32'sd0;
            pc13l <= VLM; pgl <= 32'sd0; pl1l <= 32'sd0; pl2l <= 32'sd0;
            pc13r <= VLM; pgr <= 32'sd0; pl1r <= 32'sd0; pl2r <= 32'sd0;
            cc11 <= VLM; cg <= 32'sd0; cl1 <= 32'sd0; cl2 <= 32'sd0;
            c85 <= VTL5; c84 <= 32'sd0; sl1 <= 32'sd0; sl2 <= 32'sd0; sa <= 1'b1; sb <= 1'b0;
            p8 <= V8I; tra <= TA4; tadir <= 1'b1; aq <= 1'b0; al <= 32'sd0;
            c72 <= 32'sd0; s5 <= 1'b1; ffq <= 1'b0; cnt <= 4'd0;
            c100 <= 32'sd0; lp2 <= 32'sd0; hp2 <= 32'sd0; bp2 <= 32'sd0; son <= 32'sd0;
            t2 <= 32'sd0; tl <= 32'sd0; tr <= 32'sd0; hinl <= 32'sd0; hinr <= 32'sd0;
            vml <= VBF; vmr <= VBF; hol <= VBF; hor <= VBF;
            audio_l <= 16'sd0; audio_r <= 16'sd0; wcnt <= 13'd0;
        end else begin
            if (tick) begin
                sc <= 8'd0; run <= 1'b1;
            end else if (run) begin
                sc <= sc + 8'd1;
                if (sc == SC_END) run <= 1'b0;
            end

            if (run && !sc[0]) begin
                ma <= a_n; mb <= b_n;
            end

            if (run && sc[0]) begin
                case (op)
                    7'd0: begin
                              tie_d <= s_tie;
                              if (!s_tie || (tie_q && v45 >= VT45)) tie_q <= 1'b0;
                              else if (!tie_d)                      tie_q <= 1'b1;
                              v45 <= tie_q ? v45 + K45 : 32'sd0;
                              t1  <= {{5{NC2[26]}}, NC2} + p24;
                          end
                    7'd1:  t1 <= {{5{NC1[26]}}, NC1} + p24;
                    7'd2: begin
                              nph <= nphn[23:0];
                              if (nphn[24]) begin
                                  sr2 <= {sr2[3:0], d2i};
                                  sr1 <= {sr1[2:0], sr2[4]};
                                  sr3 <= {sr3[2:0], d3i};
                                  sr4 <= {sr4[2:0], sr3[3]};
                              end
                          end
                    7'd3:  c29 <= c29 + p24;
                    7'd4:  nsf <= p24;
                    7'd5:  lp <= lp + p24;
                    7'd6:  hp <= nsf - lp - p24;
                    7'd7:  bp <= bp + p24;
                    7'd8:  rum <= clamp(p20, -VOPCL, VOPCL);
                    7'd9:  c18 <= c18 + p24;
                    7'd10: e1 <= e1 + p24;
                    7'd11: z1 <= p20;
                    7'd12: m1 <= p24;
                    7'd13: y1 <= y1 + p24;
                    7'd14: o1 <= mu1 ? 32'sd0 : clamp(mo1, -cl1v, cl1v);
                    7'd15: begin
                              las_d <= s_laser;
                              if (!s_laser || (las_q && v32 >= VT32)) las_q <= 1'b0;
                              else if (!las_d)                        las_q <= 1'b1;
                              v32 <= las_q ? v32 + (s_size ? K32F : K32S) : 32'sd0;
                              dl  <= KL0 + p24;
                              if (trdir ? (ltri + dl > TRI8) : (ltri - dl < -TRI8)) begin
                                  ltri   <= trdir ? TRI8 + TRI8 - (ltri + dl) : -TRI8 - TRI8 - (ltri - dl);
                                  trdir <= ~trdir;
                              end else
                                  ltri <= trdir ? ltri + dl : ltri - dl;
                          end
                    7'd16: begin
                              c7 <= c7 + p24;
                              if (!s_lock)                              lockq <= 1'b0;
                              else if (lockq && c7 + p24 >= VTH5)       begin lockq <= 1'b0; c7 <= VTH5 + VTH5 - (c7 + p24); end
                              else if (!lockq && c7 + p24 <= VTL5)      begin lockq <= 1'b1; c7 <= VTL5 + VTL5 - (c7 + p24); end
                          end
                    7'd17: begin
                              c15 <= c15 + p24;
                              if (!s_scan)                              scanq <= 1'b0;
                              else if (scanq && c15 + p24 >= VTH5)      begin scanq <= 1'b0; c15 <= VTH5 + VTH5 - (c15 + p24); end
                              else if (!scanq && c15 + p24 <= VTL5)     begin scanq <= 1'b1; c15 <= VTL5 + VTL5 - (c15 + p24); end
                          end
                    7'd18: begin
                              c12 <= c12 + p24;
                              if (!s_track)                             trq <= 1'b0;
                              else if (trq && c12 + p24 >= cvh)         begin trq <= 1'b0; c12 <= cvh + cvh - (c12 + p24); end
                              else if (!trq && c12 + p24 <= cvl)        begin trq <= 1'b1; c12 <= cvl + cvl - (c12 + p24); end
                          end
                    7'd19: c13 <= c13 + p24;
                    7'd20: c9  <= c9 + p24;
                    7'd21: e2 <= e2 + p24;
                    7'd22: z2 <= p20;
                    7'd23: m2 <= p24;
                    7'd24: y2 <= y2 + p24;
                    7'd25: o2 <= mu2 ? 32'sd0 : clamp(mo2, -cl2v, cl2v);
                    7'd26: t1 <= p20;
                    7'd27: t1 <= t1 + p20;
                    7'd28: t1 <= t1 + p20;
                    7'd29: t1 <= t1 + p20;
                    7'd30: t1 <= t1 + p20;
                    7'd31: t1 <= t1 + p20;
                    7'd32: mx <= clamp(p20, -VOPCL, VOPCL);
                    7'd33: hpo <= warm ? hpo + p24 : mx;
                    7'd34: if (!fo) begin
                               audio_l <= warm ? pout[15:0] : 16'sd0;
                               audio_r <= warm ? pout[15:0] : 16'sd0;
                           end
                    7'd35: tc7l  <= tc7l + p24;
                    7'd36: tc14l <= tc14l + p24;
                    7'd37: t2    <= p24;
                    7'd38: vol_  <= clamp(vol_ + p24, 32'sd0, VOHI);
                    7'd39: vgl   <= clamp(vgtn + p20, 32'sd0, VOHI);
                    7'd40: h1l   <= h1l + p24;
                    7'd41: h2l   <= h2l + p24;
                    7'd42: tc7r  <= tc7r + p24;
                    7'd43: tc14r <= tc14r + p24;
                    7'd44: t2    <= p24;
                    7'd45: vor   <= clamp(vor + p24, 32'sd0, VOHI);
                    7'd46: vgr   <= clamp(vgtn + p20, 32'sd0, VOHI);
                    7'd47: h1r   <= h1r + p24;
                    7'd48: h2r   <= h2r + p24;
                    7'd49: pc13l <= pc13l + p24;
                    7'd50: pgl   <= clamp(vgpn + p20, 32'sd0, VOHI);
                    7'd51: pl1l  <= pl1l + p24;
                    7'd52: pl2l  <= pl2l + p24;
                    7'd53: pc13r <= pc13r + p24;
                    7'd54: pgr   <= clamp(vgpn + p20, 32'sd0, VOHI);
                    7'd55: pl1r  <= pl1r + p24;
                    7'd56: pl2r  <= pl2r + p24;
                    7'd57: cc11 <= cc11 + p24;
                    7'd58: cg   <= clamp(vgcn + p20, 32'sd0, VOHI);
                    7'd59: cl1  <= cl1 + p24;
                    7'd60: cl2  <= cl2 + p24;
                    7'd61: begin
                              c85 <= c85 + p24;
                              if (sa && c85 + p24 >= VTH5)              begin sa <= 1'b0; c85 <= VTH5 + VTH5 - (c85 + p24); end
                              else if (!sa && c85 + p24 <= VTL5)        begin sa <= 1'b1; c85 <= VTL5 + VTL5 - (c85 + p24); end
                          end
                    7'd62: begin
                              c84 <= c84 + p24;
                              if (!f_sub)                               sb <= 1'b0;
                              else if (sb && c84 + p24 >= c85)          begin sb <= 1'b0; c84 <= c85 + c85 - (c84 + p24); end
                              else if (!sb && c84 + p24 <= (c85 >>> 1)) begin sb <= 1'b1; c84 <= c85 - (c84 + p24); end
                          end
                    7'd63: sl1 <= sl1 + p24;
                    7'd64: sl2 <= sl2 + p24;
                    7'd65: p8 <= f_alert ? ((p8 - KP8S < V8M) ? V8M : p8 - KP8S) : p8 + p24;
                    7'd66: begin
                              if (tadir && atrn > TA8) begin
                                  tra <= TA8 + TA8 - atrn; tadir <= 1'b0;
                              end else if (!tadir && atrn < TA4) begin
                                  tra <= TA4 + TA4 - atrn; tadir <= 1'b1;
                                  aq  <= f_alert ? ~aq : 1'b0;
                              end else
                                  tra <= atrn;
                              if (!f_alert) aq <= 1'b0;
                          end
                    7'd67: al <= al + p24;
                    7'd68: begin
                              c72 <= c72 + p24;
                              if (s5 && c72 + p24 >= VT8) begin s5 <= 1'b0; c72 <= VT8 + VT8 - (c72 + p24); end
                              else if (!s5 && c72 + p24 <= VT4) begin
                                  s5  <= 1'b1; c72 <= VT4 + VT4 - (c72 + p24);
                                  ffq <= ~ffq;
                                  if (!ffq && f_sync) cnt <= (cnt == 4'd9) ? 4'd0 : cnt + 4'd1;
                              end
                              if (!f_sync) cnt <= 4'd0;
                          end
                    7'd69: c100 <= c100 + p24;
                    7'd70: t2   <= p20 + vdrv;
                    7'd71: lp2  <= lp2 + p24;
                    7'd72: hp2  <= t2 - lp2 - p24;
                    7'd73: bp2  <= bp2 + p24;
                    7'd74: son  <= clamp(p24, -VOPCL, VOPCL);
                    7'd75: r2 <= r2 + p24;
                    7'd76: t2 <= p20;
                    7'd77: t2 <= t2 + p20;
                    7'd78: t2 <= t2 + p20;
                    7'd79: t2 <= t2 + p20;
                    7'd80: tl <= t2 + p20;
                    7'd81: tl <= tl + p20;
                    7'd82: tl <= tl + p20;
                    7'd83: tr <= t2 + p20;
                    7'd84: tr <= tr + p20;
                    7'd85: tl <= p20;
                    7'd86: tr <= p20;
                    7'd87: t2 <= p24;
                    7'd88: begin tl <= tl + p20; tr <= tr + p20; end
                    7'd90: hinl <= hinl + p24;
                    7'd91: hinr <= hinr + p24;
                    7'd92: vml  <= vml + p24;
                    7'd93: vmr  <= vmr + p24;
                    7'd94: hol  <= warm ? hol + p24 : vml;
                    7'd95: hor  <= warm ? hor + p24 : vmr;
                    7'd96: if (fo) audio_l <= warm ? fsat[15:0] : 16'sd0;
                    7'd97: begin
                               if (fo) audio_r <= warm ? fsat[15:0] : 16'sd0;
                               if (!warm) wcnt <= wcnt + 13'd1;
                           end
                    default: ;
                endcase
            end
        end
    end

    assign tie_on_n   = ~tie_q;
    assign laser_on_n = ~las_q;

endmodule

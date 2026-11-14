module circus_snd
(
    input  logic        clk,
    input  logic        reset,
    input  logic  [2:0] game,
    input  logic        ce,
    input  logic  [7:0] latch,
    input  logic        latch_wr,
    input  logic  [3:0] vol_music,    // OSD, 8 = unity, 0 = off, 15 = loudest
    input  logic  [3:0] vol_sfx,
    output logic signed [15:0] audio
);

    localparam logic signed [31:0] VBE      = 32'sd10905190;
    localparam logic signed [31:0] VD       = 32'sd10066330;
    localparam logic signed [31:0] V15      = 32'sd251658240;
    localparam logic signed [31:0] VSAT     = 32'sd3355443;
    localparam logic signed [31:0] VONE     = 32'sd16777216;
    localparam logic signed [31:0] V5V      = 32'sd83886080;
    localparam logic signed [26:0] ONE24    = 27'sd16777216;
    localparam logic signed [26:0] ONE20    = 27'sd1048576;
    localparam logic signed [26:0] KN       = 27'sd929404;
    localparam logic signed [26:0] NGAIN    = 27'sd38797312;
    localparam logic signed [31:0] VN0      = 32'sd16777216;
    localparam logic signed [31:0] VNMIN    = 32'sd1677722;
    localparam logic signed [31:0] VNMAX    = 32'sd248302797;
    localparam logic signed [31:0] VCH      = 32'sd241591910;
    localparam logic signed [26:0] KCA_C    = 27'sd157768;
    localparam logic signed [26:0] KR24A_C  = 27'sd373;
    localparam logic signed [26:0] KR23A_C  = 27'sd1902;
    localparam logic signed [26:0] KCA_R    = 27'sd71898;
    localparam logic signed [26:0] KR24A_R  = 27'sd170;
    localparam logic signed [26:0] KR23A_R  = 27'sd865;
    localparam logic signed [26:0] VNG      = 27'sd14235214;
    localparam logic signed [26:0] KQ       = 27'sd3089554;
    localparam logic signed [26:0] KQ6      = 27'sd1153434;
    localparam logic signed [31:0] VOP      = 32'sd206277246;
    localparam logic signed [26:0] KCB_K    = 27'sd23295;
    localparam logic signed [26:0] KR24B_K  = 27'sd233;
    localparam logic signed [26:0] KR23B_K  = 27'sd280;
    localparam logic signed [26:0] KCB_R    = 27'sd15844;
    localparam logic signed [26:0] KR24B_R  = 27'sd37;
    localparam logic signed [26:0] KR23B_R  = 27'sd190;
    localparam logic signed [26:0] SVF_F    = 27'sd86235;
    localparam logic signed [26:0] SVF_QI   = 27'sd6200693;
    localparam logic signed [26:0] KDC      = 27'sd12676;
    localparam logic signed [26:0] G_LP     = 27'sd11212423;
    localparam logic signed [26:0] G_BP     = 27'sd5691671;
    localparam logic signed [26:0] G_DC     = 27'sd8276410;
    localparam logic signed [31:0] VBO      = 32'sd73819750;
    localparam logic signed [31:0] VOB      = 32'sd171196082;
    localparam logic signed [26:0] KB       = 27'sd3495253;
    localparam logic signed [31:0] VDMAX    = 32'sd248302797;
    localparam logic signed [31:0] VDIE     = 32'sd15099494;
    localparam logic signed [26:0] KG       = 27'sd1677722;
    localparam logic signed [31:0] VGX      = 32'sd41943040;
    localparam logic signed [26:0] KCH      = 27'sd566628;
    localparam logic signed [26:0] KR34     = 27'sd705;
    localparam logic signed [26:0] KRBH     = 27'sd288;
    localparam logic signed [26:0] KAEH     = 27'sd23760;
    localparam logic signed [31:0] FH0      = 32'sd67280;
    localparam logic signed [26:0] FH1      = 27'sd837;
    localparam logic signed [26:0] KCL      = 27'sd259973;
    localparam logic signed [26:0] KR53     = 27'sd184;
    localparam logic signed [26:0] KRBL     = 27'sd131;
    localparam logic signed [26:0] KAEL     = 27'sd7607;
    localparam logic signed [31:0] FL0      = 32'sd14685;
    localparam logic signed [26:0] FL1      = 27'sd318;
    localparam logic signed [31:0] VQ12     = 32'sd72980890;
    localparam logic signed [26:0] KMOT     = 27'sd9508;
    localparam logic signed [31:0] GXM      = 32'sd25165824;
    localparam logic signed [31:0] FQL      = 32'sd9511;
    localparam logic signed [31:0] FQH      = 32'sd11413;
    localparam logic signed [31:0] TA1I     = 32'sd149908649;
    localparam logic signed [26:0] KA1I     = 27'sd677;
    localparam logic signed [31:0] TA1A     = 32'sd119692412;
    localparam logic signed [26:0] KA1A     = 27'sd405;
    localparam logic signed [26:0] GB1I     = 27'sd13805774;
    localparam logic signed [31:0] OB1I     = 32'sd1931437;
    localparam logic signed [26:0] GB1A     = 27'sd9379237;
    localparam logic signed [31:0] OB1A     = 32'sd1312162;
    localparam logic signed [26:0] GBKI     = 27'sd10093066;
    localparam logic signed [31:0] OBKI     = 32'sd4344697;
    localparam logic signed [26:0] GBKA     = 27'sd4895659;
    localparam logic signed [31:0] OBKA     = 32'sd2107403;
    localparam logic signed [31:0] VESAT    = 32'sd99321119;
    localparam logic signed [31:0] VCE      = 32'sd3355443;
    localparam logic signed [26:0] KVE      = 27'sd376155;
    localparam logic signed [26:0] K15      = 27'sd1572864;
    localparam logic signed [26:0] KHN      = 27'sd4532665;
    localparam logic signed [26:0] CN1      = 27'sd41943040;
    localparam logic signed [31:0] TRI      = 32'sd20132659;
    localparam logic signed [26:0] KF1      = 27'sd71035;
    localparam logic signed [31:0] VX1      = 32'sd211728466;
    localparam logic signed [31:0] VK1      = 32'sd65766687;
    localparam logic signed [26:0] S1       = 27'sd4354118;
    localparam logic signed [31:0] VK2      = 32'sd71303168;
    localparam logic signed [26:0] S2       = 27'sd7837412;
    localparam logic signed [31:0] MCLIP    = 32'sd50331648;
    localparam logic signed [26:0] KMH      = 27'sd52755;
    localparam logic signed [26:0] CM       = 27'sd3355443;
    localparam logic signed [31:0] V5L      = 32'sd228780218;
    localparam logic signed [31:0] V5H      = 32'sd232172347;
    localparam logic signed [26:0] KF2      = 27'sd117736;
    localparam logic signed [26:0] KF2W     = 27'sd913046;
    localparam logic signed [31:0] W0W      = 32'sd214748365;
    localparam logic signed [26:0] W1W      = 27'sd21810381;
    localparam logic signed [26:0] KSW      = 27'sd317;
    localparam logic signed [26:0] KGAW     = 27'sd38000;
    localparam logic signed [26:0] KGRW     = 27'sd3170;
    localparam logic signed [31:0] W0R      = 32'sd239914189;
    localparam logic signed [26:0] W1R      = -27'sd15099494;
    localparam logic signed [26:0] KSR      = 27'sd1585;
    localparam logic signed [26:0] KGAR     = 27'sd38000;
    localparam logic signed [26:0] KGRR     = 27'sd2378;
    localparam logic signed [26:0] KMONO    = 27'sd18386;
    localparam logic signed [26:0] KAC      = 27'sd201144;
    localparam logic signed [26:0] KAD      = 27'sd399876;
    localparam logic signed [31:0] VTH      = 32'sd55924053;
    localparam logic signed [31:0] VTL      = 32'sd27962027;
    localparam logic signed [31:0] VBP      = 32'sd55364813;
    localparam logic signed [26:0] KMSTEP   = -27'sd5662310;
    localparam logic signed [26:0] KFSTEP   = 27'sd7130317;
    localparam logic signed [26:0] KML2     = 27'sd40423;
    localparam logic signed [26:0] GA       = 27'sd1048576;
    localparam logic signed [26:0] GB       = 27'sd1048576;
    localparam logic signed [26:0] GH       = 27'sd838861;
    localparam logic signed [26:0] GL       = 27'sd524288;
    localparam logic signed [26:0] GM       = 27'sd3774874;
    localparam logic signed [26:0] G2M      = 27'sd4194304;
    localparam logic signed [26:0] G2W      = 27'sd5242880;
    localparam logic signed [26:0] GBP      = 27'sd3145728;
    localparam logic signed [26:0] GMU      = 27'sd3774874;
    localparam logic signed [26:0] KHP      = 27'sd59652;
    localparam logic signed [26:0] KLP      = 27'sd5835373;
    localparam logic signed [26:0] KHPF     = 27'sd471323;
    localparam logic signed [26:0] OSCALE   = 27'sd409600;

    wire g_rb = (game == 3'd2);
    wire g_cr = (game == 3'd3);
    wire g_rc = (game == 3'd1);
    wire g_ci = ~g_rb & ~g_cr;

    wire [2:0] hc = {latch[4], latch[5], latch[6]};
    wire [2:0] kc = latch[6:4];
    wire       mute = latch[7];

    wire c_miss = g_ci & (hc == 3'd1);
    wire c_pop  = g_ci & (hc == 3'd2);
    wire c_bnc  = g_ci & (hc == 3'd3);
    wire c_mus  = g_ci & (hc == 3'd4);
    wire c_whs  = g_rc & (hc == 3'd7);
    wire k_mus  = g_cr & (kc == 3'd1);
    wire k_crash= g_cr & (kc == 3'd2);
    wire k_beep = g_cr & ((kc == 3'd3) | (kc == 3'd5));
    wire k_skid = g_cr & (kc == 3'd4);
    wire k_lmot = g_cr & (kc == 3'd6);
    wire k_hmot = g_cr & (kc == 3'd7);

    localparam logic [15:0] D_HIT  = 16'd1764;
    localparam logic [15:0] D_ROLL = 16'd2646;
    localparam logic [15:0] D_DROP = 16'd1764;
    localparam logic [15:0] D_DEM  = 16'd44100;
    localparam logic [15:0] D_REW  = 16'd30870;

    logic [7:0]  lprev;
    logic [15:0] t_hit, t_roll, t_drop, t_dem, t_rew;
    logic        skid_q, mot_hi;
    logic        tick;

    always_ff @(posedge clk) begin
        if (reset) begin
            lprev <= 8'h00;
            t_hit <= 16'd0; t_roll <= 16'd0; t_drop <= 16'd0; t_dem <= 16'd0; t_rew <= 16'd0;
            skid_q <= 1'b0; mot_hi <= 1'b0;
        end else begin
            lprev <= latch;
            if (g_rb & latch[6] & ~lprev[6]) t_hit  <= D_HIT;  else if (tick && t_hit  != 16'd0) t_hit  <= t_hit  - 16'd1;
            if (g_rb & latch[5] & ~lprev[5]) t_roll <= D_ROLL; else if (tick && t_roll != 16'd0) t_roll <= t_roll - 16'd1;
            if (g_rb & latch[4] & ~lprev[4]) t_drop <= D_DROP; else if (tick && t_drop != 16'd0) t_drop <= t_drop - 16'd1;
            if (g_rb & latch[1] & ~lprev[1]) t_dem  <= D_DEM;  else if (tick && t_dem  != 16'd0) t_dem  <= t_dem  - 16'd1;
            if (g_rb & latch[0] & ~lprev[0]) t_rew  <= D_REW;  else if (tick && t_rew  != 16'd0) t_rew  <= t_rew  - 16'd1;
            if (!g_cr || k_mus) skid_q <= 1'b0;
            else if (k_skid)    skid_q <= 1'b1;
            if (k_lmot) mot_hi <= 1'b0;
            else if (k_hmot) mot_hi <= 1'b1;
        end
    end

    wire trA  = c_pop  | (t_hit  != 16'd0);
    wire trB  = k_crash| (t_roll != 16'd0);
    wire trBo = c_bnc  | (t_drop != 16'd0);
    wire trMo = k_lmot | k_hmot;
    wire trM  = c_miss | skid_q | (t_dem != 16'd0);
    wire trW  = c_whs  | (t_rew != 16'd0);
    wire musl = c_mus  | k_mus | (g_rb & latch[3]);

    logic [2:0] cdiv;
    logic [3:0] macc, msum;
    always_ff @(posedge clk) begin
        tick <= 1'b0;
        if (reset) begin
            cdiv <= 3'd0; macc <= 4'd0; msum <= 4'd0;
        end else if (ce) begin
            cdiv <= cdiv + 3'd1;
            if (cdiv == 3'd7) begin
                msum <= macc + {3'b000, musl};
                macc <= 4'd0;
                tick <= 1'b1;
            end else begin
                macc <= macc + {3'b000, musl};
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
    function automatic logic signed [31:0] smin(input logic signed [31:0] x, input logic signed [31:0] y);
        smin = (x < y) ? x : y;
    endfunction
    function automatic logic signed [31:0] smax(input logic signed [31:0] x, input logic signed [31:0] y);
        smax = (x > y) ? x : y;
    endfunction
    function automatic logic signed [31:0] pos(input logic signed [31:0] x);
        pos = x[31] ? 32'sd0 : x;
    endfunction
    function automatic logic signed [26:0] lut(input logic [4:0] i);
        case (i)
            5'd0:  lut = 27'sd18748539;  5'd1:  lut = 27'sd18346796;  5'd2:  lut = 27'sd17953662;  5'd3:  lut = 27'sd17568952;
            5'd4:  lut = 27'sd17192486;  5'd5:  lut = 27'sd16824086;  5'd6:  lut = 27'sd16463581;  5'd7:  lut = 27'sd16110800;
            5'd8:  lut = 27'sd15765579;  5'd9:  lut = 27'sd15427755;  5'd10: lut = 27'sd15097170;  5'd11: lut = 27'sd14773669;
            5'd12: lut = 27'sd14457100;  5'd13: lut = 27'sd14147314;  5'd14: lut = 27'sd13844166;  5'd15: lut = 27'sd13547514;
            5'd16: lut = 27'sd13257219;  5'd17: lut = 27'sd12973144;  5'd18: lut = 27'sd12695156;  5'd19: lut = 27'sd12423125;
            5'd20: lut = 27'sd12156923;  5'd21: lut = 27'sd11896426;  5'd22: lut = 27'sd11641510;  5'd23: lut = 27'sd11392056;
            5'd24: lut = 27'sd11147948;  5'd25: lut = 27'sd10909070;  5'd26: lut = 27'sd10675311;  5'd27: lut = 27'sd10446562;
            5'd28: lut = 27'sd10222713;  5'd29: lut = 27'sd10003662;  5'd30: lut = 27'sd9789304;   default: lut = 27'sd9579539;
        endcase
    endfunction

    logic signed [31:0] nl, vn;
    logic signed [31:0] pa, xa, oa;
    logic signed [31:0] pb, xb, lp, bp, hp, dc, ob;
    logic signed [31:0] hh, dh, gh, ah, aeh, sh, oh;
    logic signed [31:0] hl, dl, gl, al, ael, sl, ol;
    logic        [23:0] phh, phl;
    logic signed [31:0] a1, vt1, ve1, vc1, hn, vcv, ph1, att1, mc1;
    logic               tdir1;
    logic signed [31:0] m2, v5, ph2, g2, o2;
    logic               tdir2, trw_d;
    logic signed [31:0] cm, ca;
    logic               mq, aq;
    logic signed [31:0] mlv, ml;
    logic signed [31:0] t1, mix, hpo, lpo;
    logic        [22:0] lfsr;
    logic        [13:0] wcnt;
    wire                warm = wcnt[13];

    localparam logic [7:0] SC_END = 8'd139;
    logic [7:0] sc;
    logic       run;
    wire  [6:0] op = sc[7:1];

    wire signed [26:0] kca  = g_rb ? KCA_R   : KCA_C;
    wire signed [26:0] kr24a= g_rb ? KR24A_R : KR24A_C;
    wire signed [26:0] kr23a= g_rb ? KR23A_R : KR23A_C;
    wire signed [26:0] kcb  = g_rb ? KCB_R   : KCB_K;
    wire signed [26:0] kr24b= g_rb ? KR24B_R : KR24B_K;
    wire signed [26:0] kr23b= g_rb ? KR23B_R : KR23B_K;

    logic signed [31:0] ta1, ob1, v5dc, w0, sel_t, sel_v;
    logic signed [26:0] ka1, gb1, w1, ks, kg2, sel_k;
    always_comb begin
        if (g_cr) begin
            ta1 = V15;  ka1 = ONE24;
            gb1 = trM ? GBKA : GBKI;  ob1 = trM ? OBKA : OBKI;
        end else begin
            ta1 = trM ? TA1A : TA1I;  ka1 = trM ? KA1A : KA1I;
            gb1 = trM ? GB1A : GB1I;  ob1 = trM ? OB1A : OB1I;
        end
        v5dc = k_lmot ? V5L : k_hmot ? V5H : V15;
        if (g_rb) begin w0 = W0R; w1 = W1R; ks = KSR; kg2 = trW ? KGAR : KGRR; end
        else      begin w0 = W0W; w1 = W1W; ks = KSW; kg2 = trW ? KGAW : KGRW; end
        if (g_cr) begin sel_t = trMo ? GXM : 32'sd0; sel_k = KMOT; end
        else      begin sel_t = VBO;                  sel_k = KCL;  end
        sel_v = g_cr ? 32'sd0 : VDIE;
    end

    wire signed [31:0] w_n   = lfsr[0] ? VONE : -VONE;
    wire signed [31:0] xvh   = {{7{phh[23]}}, phh, 1'b0};
    wire signed [31:0] xvl   = {{7{phl[23]}}, phl, 1'b0};
    wire signed [31:0] axh   = xvh[31] ? -xvh : xvh;
    wire signed [31:0] axl   = xvl[31] ? -xvl : xvl;
    wire signed [31:0] onemh = VONE - axh;
    wire signed [31:0] oneml = VONE - axl;
    wire signed [31:0] vbeep = (mq & aq) ? VBP : 32'sd0;
    wire signed [31:0] vlev  = {28'd0, msum} <<< 19;

    logic signed [26:0] a_n, b_n, ma, mb;
    always_comb begin
        a_n = 27'sd0; b_n = 27'sd0;
        case (op)
            7'd0:  begin a_n = q(w_n - nl);                       b_n = KN;      end
            7'd1:  begin a_n = q(nl);                             b_n = NGAIN;   end
            7'd2:  begin a_n = q(VCH - pa);                       b_n = kca;     end
            7'd3:  begin a_n = q(pa);                             b_n = kr24a;   end
            7'd4:  begin a_n = q(pos(pa - xa));                   b_n = kr23a;   end
            7'd5:  begin a_n = q(pa - VBE);                       b_n = VNG;     end
            7'd6:  begin a_n = q(xa - VBE);                       b_n = KQ6;     end
            7'd7:  begin a_n = q(VCH - pb);                       b_n = kcb;     end
            7'd8:  begin a_n = q(pb);                             b_n = kr24b;   end
            7'd9:  begin a_n = q(pos(pb - xb));                   b_n = kr23b;   end
            7'd10: begin a_n = q(pb - VBE);                       b_n = VNG;     end
            7'd11: begin a_n = q(bp);                             b_n = SVF_F;   end
            7'd12: begin a_n = q(bp);                             b_n = SVF_QI;  end
            7'd13: begin a_n = q(hp);                             b_n = SVF_F;   end
            7'd14: begin a_n = q(xb - VBE - dc);                  b_n = KDC;     end
            7'd15: begin a_n = q(lp);                             b_n = G_LP;    end
            7'd16: begin a_n = q(bp);                             b_n = G_BP;    end
            7'd17: begin a_n = q(dc);                             b_n = G_DC;    end
            7'd18: begin a_n = q(VBO - hh);                       b_n = KCH;     end
            7'd19: begin a_n = q(hh);                             b_n = KR34;    end
            7'd20: begin a_n = q(pos(hh - VBE));                  b_n = KRBH;    end
            7'd21: begin a_n = q(pos(hh - VBE));                  b_n = KB;      end
            7'd22: begin a_n = q(hh - VDIE);                      b_n = KG;      end
            7'd23: begin a_n = q(dh);                             b_n = gh[30:4];  end
            7'd24: begin a_n = q(ah - aeh);                       b_n = KAEH;    end
            7'd25: begin a_n = q(hh);                             b_n = FH1;     end
            7'd26: begin a_n = q(xvh);                            b_n = onemh[26:0]; end
            7'd27: begin a_n = q(sh);                             b_n = aeh[30:4]; end
            7'd28: begin a_n = q(sel_t - hl);                     b_n = sel_k;   end
            7'd29: begin a_n = q(hl);                             b_n = g_cr ? 27'sd0 : KR53; end
            7'd30: begin a_n = q(pos(hl - VBE));                  b_n = g_cr ? 27'sd0 : KRBL; end
            7'd31: begin a_n = g_cr ? q(VQ12) : q(pos(hl - VBE)); b_n = g_cr ? KQ : KB; end
            7'd32: begin a_n = q(hl - sel_v);                     b_n = g_cr ? ONE20 : KG; end
            7'd33: begin a_n = q(dl);                             b_n = gl[30:4];  end
            7'd34: begin a_n = q(al - ael);                       b_n = KAEL;    end
            7'd35: begin a_n = q(hl);                             b_n = g_cr ? 27'sd0 : FL1; end
            7'd36: begin a_n = q(xvl);                            b_n = oneml[26:0]; end
            7'd37: begin a_n = q(sl);                             b_n = ael[30:4]; end
            7'd38: begin a_n = q(ta1 - a1);                       b_n = ka1;     end
            7'd39: begin a_n = q(a1);                             b_n = gb1;     end
            7'd40: begin a_n = q(vt1 - ve1);                      b_n = KVE;     end
            7'd41: begin a_n = q(ve1);                            b_n = K15;     end
            7'd42: begin a_n = q(vn - hn);                        b_n = KHN;     end
            7'd43: begin a_n = q(vn - hn);                        b_n = g_cr ? CN1 : 27'sd0; end
            7'd44: begin a_n = q(pos(VX1 - vcv));                 b_n = KF1;     end
            7'd45: begin a_n = q(pos(ve1 - VK1));                 b_n = S1;      end
            7'd46: begin a_n = q(pos(ve1 - VK2));                 b_n = S2;      end
            7'd47: begin a_n = q(ph1);                            b_n = lut(att1[23:19]); end
            7'd48: begin a_n = g_cr ? q(ol - m2) : q(VONE - m2);  b_n = g_cr ? KMH : (trW ? ks : 27'sd0); end
            7'd49: begin a_n = g_cr ? q(ol - m2) : q(m2);         b_n = g_cr ? CM : w1; end
            7'd50: begin a_n = q(pos(V15 - v5));                  b_n = g_cr ? KF2 : KF2W; end
            7'd51: begin a_n = (g_cr | trW) ? q(VONE - g2) : q(-g2); b_n = g_cr ? ONE24 : kg2; end
            7'd52: begin a_n = q(ph2);                            b_n = g2[26:0];  end
            7'd53: begin a_n = q(V5V - cm);                       b_n = KMONO;   end
            7'd54: begin a_n = aq ? q(V5V - ca) : q(-ca);         b_n = aq ? KAC : KAD; end
            7'd55: begin a_n = vlev[26:0];                        b_n = g_rb ? KFSTEP : KMSTEP; end
            7'd56: begin a_n = q(mlv - ml);                       b_n = g_rb ? KML2 : ONE24; end
            7'd57: begin a_n = q(oa);                             b_n = GA;      end
            7'd58: begin a_n = q(ob);                             b_n = GB;      end
            7'd59: begin a_n = q(oh);                             b_n = GH;      end
            7'd60: begin a_n = q(ol);                             b_n = g_cr ? 27'sd0 : GL; end
            7'd61: begin a_n = q(mc1);                            b_n = GM;      end
            7'd62: begin a_n = q(o2);                             b_n = g_cr ? G2M : G2W; end
            7'd63: begin a_n = q(vbeep);                          b_n = GBP;     end
            7'd64: begin a_n = q(t1);                             b_n = $signed({6'd0, vol_sfx, 17'd0}); end
            7'd65: begin a_n = q(ml);                             b_n = GMU;     end
            7'd66: begin a_n = q(mix);                            b_n = $signed({6'd0, vol_music, 17'd0}); end
            7'd67: begin a_n = q(mix - hpo);                      b_n = warm ? KHP : KHPF; end
            7'd68: begin a_n = q(mix - hpo - lpo);                b_n = KLP;     end
            7'd69: begin a_n = q(lpo);                            b_n = OSCALE;  end
            default: ;
        endcase
    end

    wire signed [53:0] prod = ma * mb;
    wire signed [31:0] p24  = prod[50:19];
    wire signed [31:0] p22  = prod[48:17];
    wire signed [31:0] p20  = prod[46:15];
    wire signed [26:0] pq8  = prod[53:27];

    wire signed [31:0] vch  = V15 - clamp(dh + p20, 32'sd0, VDMAX);
    wire signed [31:0] vcl  = V15 - clamp(dl + p20, 32'sd0, VDMAX);
    wire signed [31:0] ph1n = tdir1 ? ph1 + p24 : ph1 - p24;
    wire signed [31:0] ph2n = tdir2 ? ph2 + p24 : ph2 - p24;
    wire               mc_mute = (att1[31:24] >= 8'd20);
    wire signed [31:0] mc_raw  = p22 >>> ({1'b0, att1[28:24]} + 6'd1);
    wire signed [31:0] yq   = t1 - p20;
    wire signed [26:0] pabs = pq8[26] ? -pq8 : pq8;
    wire signed [26:0] plim = (pabs > 27'sd52000) ? 27'sd28000 + ((pabs - 27'sd52000) >>> 4) :
                              (pabs > 27'sd20000) ? 27'sd20000 + ((pabs - 27'sd20000) >>> 2) : pabs;
    wire signed [26:0] psat = (plim > 27'sd32767) ? 27'sd32767 : plim;
    wire signed [26:0] pout = pq8[26] ? -psat : psat;

    /* verilator lint_off UNUSED */
    wire unused_ok = &{1'b0, latch_wr, latch[2:0], lprev[7], lprev[3:2], prod[53:51], prod[16:0], att1[18:0], att1[31:29], gh[31], gh[3:0],
                       gl[31], gl[3:0], aeh[31], aeh[3:0], ael[31], ael[3:0], g2[31:27], onemh[31:27], oneml[31:27],
                       vlev[31:27], pout[26:16]};
    /* verilator lint_on UNUSED */

    always_ff @(posedge clk) begin
        if (reset) begin
            sc <= 8'd0; run <= 1'b0; ma <= 27'sd0; mb <= 27'sd0;
            nl <= 32'sd0; vn <= VN0; lfsr <= 23'h1;
            pa <= 32'sd0; xa <= 32'sd0; oa <= 32'sd0;
            pb <= 32'sd0; xb <= 32'sd0; lp <= -VBE; bp <= 32'sd0; hp <= 32'sd0; dc <= -VBE; ob <= 32'sd0;
            hh <= 32'sd0; dh <= 32'sd0; gh <= 32'sd0; ah <= 32'sd0; aeh <= 32'sd0; sh <= 32'sd0; oh <= 32'sd0; phh <= 24'd0;
            hl <= 32'sd0; dl <= 32'sd0; gl <= 32'sd0; al <= 32'sd0; ael <= 32'sd0; sl <= 32'sd0; ol <= 32'sd0; phl <= 24'd0;
            a1 <= TA1I; vt1 <= VESAT; ve1 <= VESAT; vc1 <= VESAT + VCE; hn <= VN0; vcv <= VESAT + VCE;
            ph1 <= 32'sd0; tdir1 <= 1'b1; att1 <= 32'sd0; mc1 <= 32'sd0;
            m2 <= 32'sd0; trw_d <= 1'b0; v5 <= V15; ph2 <= 32'sd0; tdir2 <= 1'b1; g2 <= 32'sd0; o2 <= 32'sd0;
            cm <= 32'sd0; ca <= 32'sd0; mq <= 1'b0; aq <= 1'b1;
            mlv <= 32'sd0; ml <= 32'sd0;
            t1 <= 32'sd0; mix <= 32'sd0; hpo <= 32'sd0; lpo <= 32'sd0;
            audio <= 16'sd0; wcnt <= 14'd0;
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
                    7'd0:  begin nl <= nl + p24; lfsr <= {lfsr[21:0], lfsr[22] ^ lfsr[17]}; end
                    7'd1:  vn <= clamp(VN0 + p20, VNMIN, VNMAX);
                    7'd2:  if (trA) pa <= pa + p24;
                    7'd3:  t1 <= p24;
                    7'd4:  pa <= pos(pa - t1 - p24);
                    7'd5:  xa <= smin((pa > VBE) ? VBE + p24 : pa, vn + VD);
                    7'd6:  oa <= smin(VOP, clamp(V15 - p20, VSAT, V15) + VD) - VOP;
                    7'd7:  if (trB) pb <= pb + p24;
                    7'd8:  t1 <= p24;
                    7'd9:  pb <= pos(pb - t1 - p24);
                    7'd10: xb <= smin((pb > VBE) ? VBE + p24 : pb, vn + VD);
                    7'd11: lp <= lp + p24;
                    7'd12: hp <= (xb - VBE) - lp - p24;
                    7'd13: bp <= bp + p24;
                    7'd14: dc <= dc + p24;
                    7'd15: t1 <= p20;
                    7'd16: t1 <= t1 + p20;
                    7'd17: ob <= smin(VOP, clamp(V15 - yq, VSAT, V15) + VD) - VOP;
                    7'd18: if (trBo) hh <= hh + p24;
                    7'd19: t1 <= p24;
                    7'd20: hh <= pos(hh - t1 - p24);
                    7'd21: dh <= smin(p20, VDMAX);
                    7'd22: gh <= clamp(p20, 32'sd0, VGX);
                    7'd23: ah <= p20;
                    7'd24: aeh <= aeh + p24;
                    7'd25: phh <= phh + FH0[23:0] + p24[23:0];
                    7'd26: sh <= p22;
                    7'd27: oh <= smin(VOB, vch + VD) - VOB;
                    7'd28: if (g_cr || trBo) hl <= hl + p24;
                    7'd29: t1 <= p24;
                    7'd30: hl <= pos(hl - t1 - p24);
                    7'd31: dl <= smin(p20, VDMAX);
                    7'd32: gl <= clamp(p20, 32'sd0, VGX);
                    7'd33: al <= p20;
                    7'd34: ael <= ael + p24;
                    7'd35: phl <= phl + (g_cr ? (mot_hi ? FQH[23:0] : FQL[23:0]) : FL0[23:0]) + p24[23:0];
                    7'd36: sl <= p22;
                    7'd37: ol <= smin(VOB, vcl + VD) - VOB;
                    7'd38: a1 <= a1 + p24;
                    7'd39: vt1 <= smin(p24 + ob1 - VBE, VESAT);
                    7'd40: ve1 <= ve1 + p24;
                    7'd41: vc1 <= smax(V15 - p20, ve1 + VCE);
                    7'd42: hn <= hn + p24;
                    7'd43: vcv <= smin(vc1 + p24, V15);
                    7'd44: begin
                               if (ph1n > TRI)       begin ph1 <= TRI + TRI - ph1n;  tdir1 <= 1'b0; end
                               else if (ph1n < -TRI) begin ph1 <= -TRI - TRI - ph1n; tdir1 <= 1'b1; end
                               else                  ph1 <= ph1n;
                           end
                    7'd45: att1 <= p20;
                    7'd46: att1 <= att1 + p20;
                    7'd47: mc1 <= mc_mute ? 32'sd0 : clamp(mc_raw, -MCLIP, MCLIP);
                    7'd48: begin
                               trw_d <= trW;
                               if (!g_cr && trW && !trw_d) m2 <= 32'sd0;
                               else                        m2 <= m2 + p24;
                           end
                    7'd49: v5 <= g_cr ? v5dc + p24 : w0 + p24;
                    7'd50: begin
                               if (ph2n > TRI)       begin ph2 <= TRI + TRI - ph2n;  tdir2 <= 1'b0; end
                               else if (ph2n < -TRI) begin ph2 <= -TRI - TRI - ph2n; tdir2 <= 1'b1; end
                               else                  ph2 <= ph2n;
                           end
                    7'd51: g2 <= g2 + p24;
                    7'd52: o2 <= p24;
                    7'd53: begin
                               if (k_beep)             mq <= 1'b1;
                               else if (cm + p24 >= VTH) mq <= 1'b0;
                               if (mq || k_beep)       cm <= cm + p24;
                               else                    cm <= 32'sd0;
                           end
                    7'd54: begin
                               if (!mq) begin
                                   ca <= 32'sd0; aq <= 1'b1;
                               end else begin
                                   ca <= ca + p24;
                                   if (aq && ca + p24 >= VTH)       aq <= 1'b0;
                                   else if (!aq && ca + p24 <= VTL) aq <= 1'b1;
                               end
                           end
                    7'd55: mlv <= p24;
                    7'd56: ml <= ml + p24;
                    7'd57: t1 <= p20;
                    7'd58: t1 <= t1 + p20;
                    7'd59: t1 <= t1 + p20;
                    7'd60: t1 <= t1 + p20;
                    7'd61: t1 <= t1 + p20;
                    7'd62: t1 <= t1 + p20;
                    7'd63: t1 <= t1 + p20;
                    7'd64: t1 <= p20;
                    7'd65: mix <= p20;
                    7'd66: mix <= mute ? 32'sd0 : t1 + p20;
                    7'd67: hpo <= hpo + p24;
                    7'd68: lpo <= lpo + p24;
                    7'd69: begin
                               audio <= warm ? pout[15:0] : 16'sd0;
                               if (!warm) wcnt <= wcnt + 14'd1;
                           end
                    default: ;
                endcase
            end
        end
    end

endmodule

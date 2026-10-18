// ============================================================================
// exidy_gen1snd.sv - Exidy gen-1 audio boards, synthesized (no samples)
//   spectar = 0: TARG AUDIO PCB 77-3371-11 (targ1.1.pdf p26-27)
//   spectar = 1: SPECTAR AUDIO PCB 77-3376-11 (spectar.pdf p23, p25); also
//                Side Trak / Rallys / Panzer / Phantomas
// Digital part (latches, tone prescaler/divider, NOTE step counter, tone PROM)
// is cycle-exact at the phi2 enable. The analog part is a small circuit model
// (volts, Q28 fixed point) stepped at fs = phi2/4 = 176.4 kHz by a sequencer
// with ONE shared 27x27 multiplier (30 ops x 2 clocks per sample).
// Component values from the schematics; modelling choices marked #unverified.
// ============================================================================
module exidy_gen1snd
(
    input  logic        clk,          // 22.578 MHz system clock
    input  logic        reset,
    input  logic        spectar,      // 0 = Targ audio board, 1 = Spectar-type board (Spectar, Side Trak, Rallys, Panzer, Phantomas)
    input  logic        cpu_ce,       // main 6502 cycle enable = phi2 rate, 705.6 kHz (one clk pulse every 32 clks)
    input  logic        wr,           // main CPU write to the audio board (already qualified with cpu_ce and the 52xx page)
    input  logic        a0,           // only A0 is decoded on the board: even = 5200 latch, odd = 5201 latch
    input  logic  [7:0] din,
    input  logic [24:0] ioctl_addr,   // ROM download (index 0); Targ tone PROM HRA2B-1 (32 bytes) at 0x14A00-0x14A1F
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,
    input  logic  [3:0] vol_music,    // OSD pots, 8 = default/unity, 0 = off, 15 = loudest (tone generator + CPU music)
    input  logic  [3:0] vol_sfx,      // shoot, crash, Spectar sound
    output logic signed [15:0] audio,
    output logic  [7:0] lat0,         // 5200 / 5201 latches, tone flip-flop and MUSIC bit (discrete sound engine sources)
    output logic  [7:0] lat1,
    output logic        tone,
    output logic        mus
);

    // ======================================================================
    // Latches (LS139 1D decodes A0 only; LS374 2C = 5200, 2D = 5201)
    // 5200 Targ:    D0 MUSIC, D1 SHOOT, D3 5WARN, D4 5SPEC, D5 CRASH, D6 LONG, D7 GAME
    // 5200 Spectar: D0 MUSIC, D1 SHOOT, D5 CRASH, D7 TONE (D2/3/4/6 n.c.)
    // 5201 Targ: D0 NOTE, D1 UPPER.  Spectar: D7-D0 = tone divider preload N
    // ======================================================================
    logic [7:0] l0, l1;
    always_ff @(posedge clk) begin
        if (reset) begin
            l0 <= 8'h10;                // power-up content is random on HW; /SPEC=1 keeps the 556 quiet  #unverified
            l1 <= 8'h00;
        end else if (wr) begin
            if (a0) l1 <= din;
            else    l0 <= din;
        end
    end

    wire music = l0[0];
    assign lat0 = l0;
    assign lat1 = l1;
    assign mus  = music;
    wire shoot = l0[1];
    wire warn  = l0[3];                 // 5WARN high -> LS04 -> 7407 grounds C28 -> C28 parallel to C5 (slow sweep)
    wire spec  = ~l0[4];                // 5SPEC low  -> 556 5A runs
    wire crash = l0[5];
    wire lng   = l0[6];
    wire game  = l0[7];                 // Targ GAME / Spectar TONE
    wire note  = l1[0];
    wire upper = l1[1];

    // Targ tone PROM 2B (6331, 32x8), loaded from the ROM download
    logic [7:0] prom [0:31];
    always_ff @(posedge clk) begin
        if (ioctl_wr0 && ioctl_addr[24:5] == 20'hA50)
            prom[ioctl_addr[4:0]] <= ioctl_dout;
    end

    // ======================================================================
    // Tone generator, clocked by phi2
    //  prescaler 1A/1B: preload B9 (Targ, /71) or EB (Spectar, /21), TC = TC10
    //  divider 3A/3B: counts on TC10, reloads P at FF -> /(256-P); 3D-b toggles
    //  Targ:    P = PROM[{UPPER, step}], step = 2A counting NINC rises, cleared by GAME
    //           FF /PRE = GAME, /CLR = NINC (sounds only while NOTE = 1)
    //  Spectar: P = 5201, FF /PRE = TONE
    // ======================================================================
    logic [7:0] pre, div;
    logic [3:0] step;
    logic       ninc, tq;
    assign tone = tq;
    wire        tc     = (pre == 8'hFF);
    wire  [7:0] reload = spectar ? l1 : prom[{upper, step}];

    always_ff @(posedge clk) begin
        if (reset) begin
            pre <= 8'd0; div <= 8'd0; step <= 4'd0; ninc <= 1'b0; tq <= 1'b1;
        end else if (cpu_ce) begin
            pre  <= tc ? (spectar ? 8'hEB : 8'hB9) : pre + 8'd1;
            if (tc) div <= (div == 8'hFF) ? reload : div + 8'd1;
            ninc <= game & note;                                   // 3D-a (J = NOTE, /CLR = GAME)
            if (!game)                    step <= 4'd0;            // 2A /CLR = GAME
            else if (note && !ninc)       step <= step + 4'd1;     // 2A clocked by NINC rising
            if (!game)                    tq <= 1'b1;              // /PRE (Targ: /PRE and /CLR both low -> Q high)
            else if (!spectar && !ninc)   tq <= 1'b0;              // Targ /CLR = NINC
            else if (tc && div == 8'hFF)  tq <= ~tq;               // J = K = 3B CO
        end
    end

    // box average of the 1-bit sources over the 4 phi2 cycles of one sample
    logic [1:0] cdiv;
    logic [2:0] tacc, macc, tsum, msum;
    logic       tick;
    always_ff @(posedge clk) begin
        tick <= 1'b0;
        if (reset) begin
            cdiv <= 2'd0; tacc <= 3'd0; macc <= 3'd0; tsum <= 3'd4; msum <= 3'd0;
        end else if (cpu_ce) begin
            cdiv <= cdiv + 2'd1;
            if (cdiv == 2'd3) begin
                tsum <= tacc + {2'b00, tq};
                msum <= macc + {2'b00, music};
                tacc <= 3'd0; macc <= 3'd0;
                tick <= 1'b1;
            end else begin
                tacc <= tacc + {2'b00, tq};
                macc <= macc + {2'b00, music};
            end
        end
    end

    // ======================================================================
    // Analog model constants. B operands: Q24 unless noted; voltages Q28 (40-bit).
    // Generated from the component values (fs = 176400 Hz).
    // ======================================================================
    localparam logic signed [26:0] KN       = 27'sd1429382;    // noise LPF 2.5 kHz #unverified (72748 bandwidth)
    localparam logic signed [26:0] NGAIN    = 27'sd31457280;   // 30 Q20, noise -> Q5 collector swing #unverified
    localparam logic signed [26:0] KS_B     = 27'sd8336735;    // Targ Q1 base: R3 share
    localparam logic signed [26:0] KS_N     = 27'sd566898;     // Targ Q1 base: R50 (noise) share
    localparam logic signed [26:0] K14T     = 27'sd206;        // R3 x C14 6.8u
    localparam logic signed [26:0] KQ       = 27'sd1135;       // C29 33u x (Rpot 2.24K + 0.3K)
    localparam logic signed [26:0] RRATIO   = 27'sd14795655;   // 2.24K / 2.54K
    localparam logic signed [26:0] KF       = 27'sd223786;     // 566 triangle step per volt (R11 6.8K, C26 .05u)
    localparam logic signed [26:0] K14S     = 27'sd140;        // Spectar R3 x C14 10u
    localparam logic signed [26:0] KB14     = 27'sd2976;       // Spectar dt/(R3 C60)
    localparam logic signed [26:0] KBG      = 27'sd5786;       // Spectar dt*G/C60
    localparam logic signed [26:0] KATT     = 27'sd7837412;    // MC3340 45 dB/V = 7.47 oct/V, Q20 #unverified
    localparam logic signed [26:0] KC1_10   = 27'sd4231;       // 556 osc1 charge, C5 10u
    localparam logic signed [26:0] KD1_10   = 27'sd7175;       // 556 osc1 discharge, C5 10u
    localparam logic signed [26:0] KC1_33   = 27'sd1282;       // C5 33u
    localparam logic signed [26:0] KD1_33   = 27'sd2175;
    localparam logic signed [26:0] KC1_66   = 27'sd641;        // C5 + C28 66u
    localparam logic signed [26:0] KD1_66   = 27'sd1087;
    localparam logic signed [26:0] K2C      = 27'sd46994;      // 556 osc2 charge (R14+R13) C15
    localparam logic signed [26:0] K2D      = 27'sd201144;     // 556 osc2 discharge R13 C15
    localparam logic signed [26:0] KCC_S    = 27'sd167788;     // crash charge R25 x C35 .47u
    // discharge rates fitted to the MAME targ samples (recordings of the board): sexpl ~0.76 s, expl ~2.3 s;
    // the schematic values gave 0.24 s / 1.3 s. Schematic values: S 1686 / 2024, L 109 / 131, P 117 / 140
    localparam logic signed [26:0] KR24_S   = 27'sd300;
    localparam logic signed [26:0] KR28_S   = 27'sd360;
    localparam logic signed [26:0] KCC_L    = 27'sd10898;      // C35 + C36 7.27u
    localparam logic signed [26:0] KR24_L   = 27'sd60;
    localparam logic signed [26:0] KR28_L   = 27'sd72;
    localparam logic signed [26:0] KCC_P    = 27'sd11651;      // Spectar C35 6.8u
    localparam logic signed [26:0] KR24_P   = 27'sd64;
    localparam logic signed [26:0] KR28_P   = 27'sd77;
    localparam logic signed [26:0] VNG      = 27'sd14235214;   // R27 / (R28 + R27)
    localparam logic signed [26:0] SVF_F    = 27'sd43118;      // Q3 stage fit: f0 72.15 Hz
    localparam logic signed [26:0] SVF_QI   = 27'sd6200693;    //               Q 2.706
    localparam logic signed [26:0] KDC      = 27'sd6339;       // R26 x C37 (DC gain correction)
    localparam logic signed [26:0] G_LP     = 27'sd11212423;   // 10.693 Q20
    localparam logic signed [26:0] G_BP     = 27'sd5691671;    // 5.428 Q20
    localparam logic signed [26:0] G_DC     = 27'sd8276410;    // 7.893 Q20
    localparam logic signed [26:0] KT       = 27'sd189370;     // tone/music: 2.27K x .22u (pot at mid) #unverified
    localparam logic signed [26:0] KHP      = 27'sd35817;      // 22K + .1u coupling -> 60 Hz HPF
    localparam logic signed [26:0] KLP      = 27'sd5835373;    // 12 kHz amp/speaker roll-off #unverified
    localparam logic signed [26:0] OSCALE   = 27'sd716800;     // 2800 counts per volt (branch volts after the pots), Q8

    localparam logic signed [39:0] NOFS     = 40'sd1315333734; // 4.9 V Q5 collector rest
    localparam logic signed [39:0] NMIN     = 40'sd26843546;   // 0.1 V
    localparam logic signed [39:0] NMAX     = 40'sd2952790016; // 11 V
    localparam logic signed [39:0] VONE     = 40'sd268435456;  // 1 V
    localparam logic signed [39:0] VB0      = 40'sd939790872;  // 3.501 V
    localparam logic signed [39:0] VBE      = 40'sd174483046;  // 0.65 V
    localparam logic signed [39:0] VW       = 40'sd2126008812; // 7.92 V: R10 wiper for 2 kHz (PRT 500 us) #unverified
    localparam logic signed [39:0] V5MIN    = 40'sd805306368;  // 3 V
    localparam logic signed [39:0] V12      = 40'sd3221225472; // 12 V
    localparam logic signed [39:0] TRI      = 40'sd322122547;  // 1.2 V (566 triangle 2.4 Vpp)
    localparam logic signed [39:0] KB0      = 40'sd335467;     // 0.00125 V
    localparam logic signed [39:0] V3       = 40'sd805306368;  // 3 V MC3340 knee #unverified
    localparam logic signed [39:0] MCLIP    = 40'sd805306368;  // 3 V MC3340 output clip #unverified
    localparam logic signed [39:0] SQIN     = 40'sd442918502;  // 1.65 V
    localparam logic signed [39:0] TC1      = 40'sd1040515285; // 3.876 V osc1 charge target (loaded by osc2 CV)
    localparam logic signed [39:0] TD1      = 40'sd355757833;  // 1.325 V osc1 discharge target
    localparam logic signed [39:0] VTH1     = 40'sd894784853;  // 3.333 V
    localparam logic signed [39:0] VTL1     = 40'sd447392427;  // 1.667 V
    localparam logic signed [39:0] V5V      = 40'sd1342177280; // 5 V
    localparam logic signed [39:0] V556     = 40'sd885837005;  // 3.3 V 556 output high
    localparam logic signed [39:0] VCH      = 40'sd3060164198; // 11.4 V
    localparam logic signed [39:0] VD       = 40'sd161061274;  // 0.6 V
    localparam logic signed [39:0] VCMIN    = 40'sd53687091;   // 0.2 V
    localparam logic signed [39:0] VCOMAX   = 40'sd2636036178; // 9.82 V (R32/R35 rest level)
    localparam logic signed [39:0] TSTEP    = 40'sd114085069;  // 0.425 V per phi2 high (3.4 V x pot 0.5 / 4)
    localparam logic signed [39:0] TIDLE    = 40'sd456340275;  // 1.7 V

    /* verilator lint_off UNUSED */
    function automatic logic signed [26:0] q16(input logic signed [39:0] x);   // Q28 -> Q16 operand (|x| < 1024 V)
        q16 = x[38:12];
    endfunction
    /* verilator lint_on UNUSED */
    function automatic logic signed [39:0] clamp(input logic signed [39:0] x, input logic signed [39:0] lo, input logic signed [39:0] hi);
        clamp = (x < lo) ? lo : (x > hi) ? hi : x;
    endfunction
    function automatic logic signed [39:0] smin(input logic signed [39:0] x, input logic signed [39:0] y);
        smin = (x < y) ? x : y;
    endfunction
    function automatic logic signed [39:0] pos(input logic signed [39:0] x);
        pos = x[39] ? 40'sd0 : x;
    endfunction
    function automatic logic signed [39:0] tvolt(input logic [2:0] n);   // n of 4 phi2 cycles high -> volts at the pot wiper
        case (n)
            3'd0:    tvolt = 40'sd0;
            3'd1:    tvolt = TSTEP;
            3'd2:    tvolt = TSTEP + TSTEP;
            3'd3:    tvolt = TSTEP + TSTEP + TSTEP;
            default: tvolt = TIDLE;
        endcase
    endfunction
    function automatic logic signed [26:0] lut(input logic [4:0] i);   // MC3340 4.47*2^(-i/32), Q22
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

    // ======================================================================
    // State (volts, Q28)
    // ======================================================================
    logic signed [39:0] nl, vn;                         // noise LPF, WHITE NOISE node
    logic signed [39:0] c14, vb, ve, q, v5, ph;         // shoot envelope / 566 CV / triangle
    logic               tdir;
    logic signed [39:0] att, mc;                        // MC3340
    logic signed [39:0] v1, v28, v2;                    // 556 (Targ Spectar sound, Spectar shoot)
    logic               c1, c2, warn_d;
    logic signed [39:0] env, vnn, lp, bp, hp, dc, co;   // crash
    logic signed [39:0] tl, ml, mix, hl, ol;            // mixer
    logic signed [39:0] t1, t2;                         // temporaries
    logic        [22:0] lfsr;

    // sequencer: op = sc[6:1]; sc[0] = 0 load operands, 1 write back
    logic [6:0] sc;
    logic       run;
    wire  [5:0] op = sc[6:1];

    // board / mode dependent selections
    logic signed [26:0] k1, kcc, kr24, kr28;
    always_comb begin
        if (spectar)   k1 = c1 ? KC1_10 : KD1_10;
        else if (warn) k1 = c1 ? KC1_66 : KD1_66;
        else           k1 = c1 ? KC1_33 : KD1_33;
        if (spectar)   begin kcc = KCC_P; kr24 = KR24_P; kr28 = KR28_P; end
        else if (lng)  begin kcc = KCC_L; kr24 = KR24_L; kr28 = KR28_L; end
        else           begin kcc = KCC_S; kr24 = KR24_S; kr28 = KR28_S; end
    end

    wire               rst556  = ~spectar & ~spec;      // Targ: /SPEC high -> Q2 on -> 556 reset
    wire signed [39:0] vin_sq  = c2 ? SQIN : -SQIN;     // 556 out, AC coupled into MC3340 (Spectar)
    wire signed [39:0] xq3     = vnn - VBE;             // Q3 base drive
    wire signed [39:0] spc     = (!spectar && c2) ? V556 : 40'sd0;
    wire signed [39:0] sfx_in  = (mc + spc + (co - VCOMAX)) >>> 1;   // pots at mid (x0.5) #unverified
    wire signed [39:0] w_n     = lfsr[0] ? VONE : -VONE;

    logic signed [26:0] a_n, b_n, ma, mb;
    always_comb begin
        a_n = 27'sd0; b_n = 27'sd0;
        case (op)
            6'd0:  begin a_n = q16(w_n - nl);                       b_n = KN;     end
            6'd1:  begin a_n = q16(nl);                             b_n = NGAIN;  end
            6'd2:  begin a_n = q16(c14);                            b_n = spectar ? KB14 : KS_B; end
            6'd3:  begin a_n = spectar ? q16(vb) : q16(vn);         b_n = spectar ? KBG : KS_N;  end
            6'd4:  begin a_n = q16(vb - c14);                       b_n = spectar ? K14S : K14T; end
            6'd5:  begin a_n = q16(VW - ve - q);                    b_n = KQ;     end
            6'd6:  begin a_n = q16(VW - ve - q);                    b_n = RRATIO; end
            6'd7:  begin a_n = q16(V12 - v5);                       b_n = KF;     end
            6'd8:  begin a_n = q16(ve - V3);                        b_n = KATT;   end
            6'd9:  begin a_n = spectar ? q16(vin_sq) : q16(ph);     b_n = lut(att[27:23]); end
            6'd10: begin a_n = q16((c1 ? TC1 : TD1) - v1);          b_n = k1;     end
            6'd11: begin a_n = q16((c2 ? V5V : 40'sd0) - v2);       b_n = c2 ? K2C : K2D; end
            6'd12: begin a_n = q16(VCH - env);                      b_n = kcc;    end
            6'd13: begin a_n = q16(env);                            b_n = kr24;   end
            6'd14: begin a_n = q16(pos(env - vnn));                 b_n = kr28;   end
            6'd15: begin a_n = q16(env - VBE);                      b_n = VNG;    end
            6'd16: begin a_n = q16(bp);                             b_n = SVF_F;  end
            6'd17: begin a_n = q16(bp);                             b_n = SVF_QI; end
            6'd18: begin a_n = q16(hp);                             b_n = SVF_F;  end
            6'd19: begin a_n = q16(xq3 - dc);                       b_n = KDC;    end
            6'd20: begin a_n = q16(lp);                             b_n = G_LP;   end
            6'd21: begin a_n = q16(bp);                             b_n = G_BP;   end
            6'd22: begin a_n = q16(dc);                             b_n = G_DC;   end
            6'd23: begin a_n = q16(tvolt(tsum) - tl);              b_n = KT;     end
            6'd24: begin a_n = q16(tvolt(msum) - ml);              b_n = KT;     end
            6'd25: begin a_n = q16(tl + ml);                        b_n = $signed({2'b00, vol_music, 21'd0}); end
            6'd26: begin a_n = q16(sfx_in);                         b_n = $signed({2'b00, vol_sfx, 21'd0});   end
            6'd27: begin a_n = q16(mix - hl);                       b_n = KHP;    end
            6'd28: begin a_n = q16(mix - hl - ol);                  b_n = KLP;    end
            6'd29: begin a_n = q16(ol);                             b_n = OSCALE; end
            default: ;
        endcase
    end

    wire signed [53:0] prod = ma * mb;
    wire signed [39:0] p24  = prod[51:12];      // B Q24 -> Q28
    wire signed [39:0] p22  = prod[49:10];      // B Q22 -> Q28
    wire signed [39:0] p20  = prod[47:8];       // B Q20 -> Q28

    // MC3340 output: gain mantissa product, shifted by whole octaves of attenuation
    wire               mc_mute = (att[39:28] >= 12'd20);
    wire signed [39:0] mc_raw  = p22 >>> att[32:28];
    // 566 triangle phase step with reflection at +-1.2 V
    wire signed [39:0] ph_n    = tdir ? ph + p24 : ph - p24;
    // crash: Q3 collector and output node (CR3, R32 / R35)
    wire signed [39:0] yq3     = t1 - p20;
    wire signed [39:0] vc3     = clamp(V12 - yq3, VCMIN, V12);
    // output
    wire signed [39:0] osum    = prod[47:8];   // A Q16 * B Q8 -> counts Q16

    /* verilator lint_off UNUSED */
    wire unused_ok = &{1'b0, l0[2], att[22:0], prod[53:52], prod[7:0]};   // n.c. latch bit, LUT index truncation, product guard bits
    /* verilator lint_on UNUSED */

    always_ff @(posedge clk) begin
        if (reset) begin
            sc <= 7'd0; run <= 1'b0; ma <= 27'sd0; mb <= 27'sd0;
            nl <= 40'sd0; vn <= NOFS; lfsr <= 23'h1;
            c14 <= 40'sd1956892000; vb <= 40'sd1956892000; ve <= 40'sd1782000000;   // ~7.3 V rest (shoot silent)
            q <= VW - 40'sd1782000000; v5 <= VW; ph <= 40'sd0; tdir <= 1'b1;
            att <= 40'sd0; mc <= 40'sd0;
            v1 <= TD1; v28 <= TD1; v2 <= 40'sd0; c1 <= 1'b0; c2 <= 1'b0; warn_d <= 1'b0;
            env <= 40'sd0; vnn <= 40'sd0; lp <= -VBE; bp <= 40'sd0; hp <= 40'sd0; dc <= -VBE; co <= VCOMAX;
            tl <= TIDLE; ml <= 40'sd0; mix <= TIDLE; hl <= TIDLE; ol <= 40'sd0;
            t1 <= 40'sd0; t2 <= 40'sd0;
            audio <= 16'sd0;
        end else begin
            if (tick) begin
                sc <= 7'd0; run <= 1'b1;
            end else if (run) begin
                sc <= sc + 7'd1;
                if (sc == 7'd59) run <= 1'b0;           // 30 ops x 2 clocks
            end

            if (run && !sc[0]) begin
                ma <= a_n; mb <= b_n;
            end

            if (run && sc[0]) begin
                case (op)
                    // ---------------- white noise (Q4 zener + 72748 + Q5), LFSR stand-in
                    6'd0:  begin nl <= nl + p24; lfsr <= {lfsr[21:0], lfsr[22] ^ lfsr[17]}; end
                    6'd1:  vn <= clamp(NOFS + p20, NMIN, NMAX);
                    // ---------------- shoot envelope (Q1 base / C14 / C60)
                    6'd2:  t1 <= p24;
                    6'd3:  vb <= spectar ? vb + t1 + KB0 - p24 : VB0 + t1 + p24;
                    6'd4:  begin
                               c14 <= shoot ? 40'sd0 : c14 + p24;          // 7407 sinks C14 while SHOOT = 1
                               ve  <= pos(vb - VBE);
                           end
                    // ---------------- Targ 566 VCO, CV = R10 wiper + C29 to Q1 emitter
                    6'd5:  q  <= q + p24;
                    6'd6:  v5 <= clamp(VW - p24, V5MIN, V12);
                    6'd7:  begin
                               if (ph_n > TRI)       begin ph <= TRI + TRI - ph_n;   tdir <= 1'b0; end
                               else if (ph_n < -TRI) begin ph <= -TRI - TRI - ph_n;  tdir <= 1'b1; end
                               else                  ph <= ph_n;
                           end
                    // ---------------- MC3340 (control = Q1 emitter)
                    6'd8:  att <= pos(p20);
                    6'd9:  mc  <= mc_mute ? 40'sd0 : clamp(mc_raw, -MCLIP, MCLIP);
                    // ---------------- 556: osc1 (R6/R7/C5[+C28]) ramp = osc2 CV, osc2 (R14/R13/C15)
                    6'd10: begin
                               warn_d <= warn;
                               if (!spectar && warn && !warn_d) v1 <= (v1 + v28) >>> 1;   // C28 reconnects: charge sharing (C5 = C28)
                               else                             v1 <= v1 + p24;
                               if (spectar || warn) v28 <= v1;                            // C28 bottom grounded: tracks
                               if (rst556)                   c1 <= 1'b0;
                               else if (c1 && v1 >= VTH1)    c1 <= 1'b0;
                               else if (!c1 && v1 <= VTL1)   c1 <= 1'b1;
                           end
                    6'd11: begin
                               v2 <= v2 + p24;
                               if (rst556)                       c2 <= 1'b0;
                               else if (c2 && v2 >= v1)          c2 <= 1'b0;
                               else if (!c2 && v2 <= (v1 >>> 1)) c2 <= 1'b1;
                           end
                    // ---------------- crash envelope (R25/CR1 charge, R24 + R28 discharge)
                    6'd12: if (crash) env <= env + p24;
                    6'd13: t1  <= p24;
                    6'd14: env <= env - t1 - p24;
                    6'd15: vnn <= smin((env > VBE) ? VBE + p24 : env, vn + VD);   // CR2 clamps to the noise
                    // ---------------- Q3 stage: SVF fit of the bridged-T response + DC correction
                    6'd16: lp <= lp + p24;
                    6'd17: hp <= xq3 - lp - p24;
                    6'd18: bp <= bp + p24;
                    6'd19: dc <= dc + p24;
                    6'd20: t1 <= p20;
                    6'd21: t1 <= t1 + p20;
                    6'd22: co <= smin(VCOMAX, vc3 + VD);
                    // ---------------- mixer
                    6'd23: tl  <= tl + p24;
                    6'd24: ml  <= ml + p24;
                    6'd25: t2  <= p24;
                    6'd26: mix <= t2 + p24;
                    6'd27: hl  <= hl + p24;
                    6'd28: ol  <= ol + p24;
                    6'd29: audio <= (osum > 40'sd2147418112) ? 16'sd32767 :
                                    (osum < -40'sd2147483648) ? -16'sd32768 : osum[31:16];
                    default: ;
                endcase
            end
        end
    end

endmodule

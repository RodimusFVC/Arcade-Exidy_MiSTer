// ============================================================================
// exidy_snd_mixer.sv — analog section of the Exidy Venture-type sound board
// (Venture / Pepper II 77-3387 / 77-0007, Mouse Trap 177-3392 incl. CVSD).
// All arithmetic runs at the E rate (ce, 894.886 kHz); the speech filter runs
// at E/8. Internal unit "U" = 8192 = one channel's full-scale contribution at
// the top of its volume pot (5 V tap, gate on). Per board that is 0.385 V
// (Venture: 100K feeds into a 10K pot) or 1.25 V (Mouse Trap: 10K feeds),
// identical for music and effects, so one scale serves both.
//
// Effects channel: CD4051 ladder tap (2.7K/1.3K/680/330/160/82/39/39 from +5 V)
//   -> 4.7 uF smoothing (~2.3 ms, #unverified source impedance) -> 4053 gate
//   (6840 output) -> 10K + switchable cap 1-pole LPF -> 100K/10K -> EFFECTS pot.
//   Venture/Pepper caps per latch 2000: ch1 EN0 .01/EN1 .1, ch2 EN2 .01/EN3 .1,
//   ch3 EN4 .1/EN5 .01 (EN=1 grounds the cap). Mouse Trap: fixed .01 uF.
// Music: 8253 OUT0-2 summed; Venture: 3x100K + C100 .01 uF (fc ~2.07 kHz);
//   Mouse Trap: 3x10K, no cap.
// Speech (Mouse Trap): MC3417 integrator (scale #unverified, see sp_u) -> C18/R20 HPF (159 Hz) -> two MFB
//   LPF stages (10K/3.9K/18K/20n/2.2n: f0 2864 Hz, Q 0.874, gain 1.8 each).
// Speech (Victory, Victory.pdf p58): TMS5220 -> R10 10K / C6 4300p pole loaded by the R12 10K / C7 .01u /
//   R13 20K / R14 10K / C4 820p MFB LPF (3rd order: +2.0 dB at 2.9 kHz, -3 dB at 4.74 kHz, -15 dB at 8 kHz).
// Mixer: (music*vm + sfx*vs + speech*vsp)/8, DC block (~8.7 Hz), 15.6 kHz 1-pole,
//   /4 -> signed 16 (all three pots at 15 with all six channels high = 29k peak).
// ============================================================================

// ---------------------------------------------------------------- 1-pole LPF, runtime coefficient
module exidy_lp1 #(parameter int DW = 18)
(
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 ce,
    input  logic                 bypass,
    input  logic          [17:0] coef,      // Q24
    input  logic signed [DW-1:0] x,
    output logic signed [DW-1:0] y
);
    logic signed [DW+23:0] acc;
    wire  signed [DW:0]    diff = {x[DW-1], x} - {y[DW-1], y};
    wire  signed [DW+19:0] prod = diff * $signed({1'b0, coef});
    assign y = acc[DW+23:24];
    always_ff @(posedge clk) begin
        if (rst)
            acc <= '0;
        else if (ce) begin
            if (bypass)
                acc <= {x, 24'd0};
            else
                acc <= acc + {{4{prod[DW+19]}}, prod};
        end
    end
endmodule

// ---------------------------------------------------------------- biquad, one multiplier, 5 clocks
// y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2, coefficients Q24 (27-bit signed)
module exidy_biquad #(
    parameter int DW = 26,
    parameter logic signed [26:0] B0 = 0, B1 = 0, B2 = 0, A1 = 0, A2 = 0
)
(
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 start,
    input  logic signed [DW-1:0] x,
    output logic signed [DW-1:0] y,
    output logic                 done
);
    logic signed [DW-1:0] x1, x2, y1, y2, xin;
    logic [2:0]           step;
    logic                 busy;
    logic signed [26:0]   c;
    logic signed [DW-1:0] d;
    logic signed [DW+31:0] acc;

    always_comb begin
        case (step)
            3'd0: begin c = B0;  d = xin; end
            3'd1: begin c = B1;  d = x1;  end
            3'd2: begin c = B2;  d = x2;  end
            3'd3: begin c = -A1; d = y1;  end
            default: begin c = -A2; d = y2; end
        endcase
    end
    wire signed [DW+26:0] prod = c * d;
    wire signed [DW+31:0] acc_n = acc + {{5{prod[DW+26]}}, prod};
    wire signed [DW+7:0]  ysh   = acc_n[DW+31:24];
    localparam logic signed [DW+7:0] YMAX = (1 <<< (DW-1)) - 1;
    localparam logic signed [DW+7:0] YMIN = -(1 <<< (DW-1));
    wire signed [DW-1:0]  ysat  = (ysh > YMAX) ? YMAX[DW-1:0] : (ysh < YMIN) ? YMIN[DW-1:0] : ysh[DW-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            x1 <= '0; x2 <= '0; y1 <= '0; y2 <= '0; xin <= '0; y <= '0;
            step <= 3'd0; busy <= 1'b0; acc <= '0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1; step <= 3'd0; acc <= '0; xin <= x;
            end else if (busy) begin
                acc <= acc_n;
                if (step == 3'd4) begin
                    busy <= 1'b0;
                    y  <= ysat;
                    y1 <= ysat; y2 <= y1;
                    x1 <= xin;  x2 <= x1;
                    done <= 1'b1;
                end else
                    step <= step + 3'd1;
            end
        end
    end
endmodule

// ---------------------------------------------------------------- the mixer
module exidy_snd_mixer #(
    parameter int SPEECH_NUM = 25           // speech pre-filter scale: Q16 integrator * NUM / 8 -> U<<8 (0.4 V per MAME unit)
)
(
    input  logic               clk,
    input  logic               rst,
    input  logic               ce,          // E enable
    input  logic               mtrap,       // Mouse Trap board variant
    input  logic         [2:0] gate,        // channel gates (gated O1, O2, O3)
    input  logic         [2:0] lvl1, lvl2, lvl3,
    input  logic         [7:0] filt,        // latch 2000 (EN7..EN0)
    input  logic         [2:0] music,       // 8253 OUT2..OUT0
    input  logic               speech_on,
    input  logic signed [23:0] speech,      // MC3417 integrator, Q16
    input  logic               tms_on,      // Victory: TMS5220 replaces the CVSD chain on the speech pot
    input  logic signed [15:0] tms,         // TMS5220 sample (MAME stream units * 32768)
    input  logic         [3:0] vol_music,
    input  logic         [3:0] vol_sfx,
    input  logic         [3:0] vol_speech,
    output logic signed [15:0] audio
);
    // ---------------- ladder taps (unloaded), U = 8192 at X7
    function automatic [13:0] tap(input [2:0] v);
        case (v)
            3'd7: tap = 14'd8192;
            3'd6: tap = 14'd4042;
            3'd5: tap = 14'd2044;
            3'd4: tap = 14'd999;
            3'd3: tap = 14'd492;
            3'd2: tap = 14'd246;
            3'd1: tap = 14'd120;
            default: tap = 14'd60;
        endcase
    endfunction

    // ---------------- filter coefficients (Q24 at E rate)
    localparam logic [17:0] K_C01  = 18'd186435;   // 10K x 0.01 uF
    localparam logic [17:0] K_C1   = 18'd18737;    // 10K x 0.1 uF
    localparam logic [17:0] K_C011 = 18'd17035;    // 10K x 0.11 uF
    localparam logic [17:0] K_MUS  = 18'd241961;   // (33.3K || 10K) x 0.01 uF

    function automatic [18:0] fsel(input c01, input c1);   // {bypass, coef}
        case ({c01, c1})
            2'b10:   fsel = {1'b0, K_C01};
            2'b01:   fsel = {1'b0, K_C1};
            2'b11:   fsel = {1'b0, K_C011};
            default: fsel = {1'b1, 18'd0};
        endcase
    endfunction

    wire [18:0] f1 = mtrap ? {1'b0, K_C01} : fsel(filt[0], filt[1]);
    wire [18:0] f2 = mtrap ? {1'b0, K_C01} : fsel(filt[2], filt[3]);
    wire [18:0] f3 = mtrap ? {1'b0, K_C01} : fsel(filt[5], filt[4]);

    // ---------------- 4.7 uF level smoothing (shift 11 = 2.29 ms) and gating
    logic [24:0] ls [0:2];
    wire  [13:0] tgt [0:2];
    assign tgt[0] = tap(lvl1);
    assign tgt[1] = tap(lvl2);
    assign tgt[2] = tap(lvl3);

    logic signed [17:0] chx [0:2];
    always_comb begin
        for (int i = 0; i < 3; i++)
            chx[i] = gate[i] ? $signed({4'b0000, ls[i][24:11]}) : 18'sd0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 3; i++) ls[i] <= {14'd60, 11'd0};
        end else if (ce) begin
            for (int i = 0; i < 3; i++)
                ls[i] <= ls[i] + {{11{1'b0}}, tgt[i]} - {{11{1'b0}}, ls[i][24:11]};
        end
    end

    logic signed [17:0] chy [0:2];
    exidy_lp1 #(.DW(18)) lpc1 (.clk(clk), .rst(rst), .ce(ce), .bypass(f1[18]), .coef(f1[17:0]), .x(chx[0]), .y(chy[0]));
    exidy_lp1 #(.DW(18)) lpc2 (.clk(clk), .rst(rst), .ce(ce), .bypass(f2[18]), .coef(f2[17:0]), .x(chx[1]), .y(chy[1]));
    exidy_lp1 #(.DW(18)) lpc3 (.clk(clk), .rst(rst), .ce(ce), .bypass(f3[18]), .coef(f3[17:0]), .x(chx[2]), .y(chy[2]));

    // ---------------- music
    wire [1:0] mus_n = {1'b0, music[0]} + {1'b0, music[1]} + {1'b0, music[2]};
    wire signed [17:0] mus_x = $signed({1'b0, mus_n, 15'd0}) >>> 2;   // n * 8192
    logic signed [17:0] mus_y;
    // Victory: no music cap (Victory.pdf p57-58: 3x10K straight into the MUSIC pot, no filter latch)
    exidy_lp1 #(.DW(18)) lpm (.clk(clk), .rst(rst), .ce(ce), .bypass(mtrap | tms_on), .coef(K_MUS), .x(mus_x), .y(mus_y));

    // ---------------- speech chain at E/8
    logic [2:0] sdiv;
    always_ff @(posedge clk) begin
        if (rst) sdiv <= 3'd0;
        else if (ce) sdiv <= sdiv + 3'd1;
    end
    wire sp_start = ce & (sdiv == 3'd0);

    localparam logic signed [6:0] SPN = SPEECH_NUM[6:0];
    wire signed [30:0] sp_mul = speech * SPN;
    wire signed [25:0] sp_x   = speech_on ? sp_mul[28:3] : 26'sd0;
    logic signed [25:0] sp_h, sp_f1, sp_f2;
    logic sp_d0, sp_d1, sp_d2;

    exidy_biquad #(.DW(26), .B0(27'sd16702558), .B1(-27'sd16702558), .B2(27'sd0), .A1(-27'sd16627899), .A2(27'sd0))
        bq_hp (.clk(clk), .rst(rst), .start(sp_start), .x(sp_x),  .y(sp_h),  .done(sp_d0));
    exidy_biquad #(.DW(26), .B0(27'sd178549), .B1(27'sd357098), .B2(27'sd178549), .A1(-27'sd30339886), .A2(27'sd13959445))
        bq_l1 (.clk(clk), .rst(rst), .start(sp_d0),    .x(sp_h),  .y(sp_f1), .done(sp_d1));
    exidy_biquad #(.DW(26), .B0(27'sd178549), .B1(27'sd357098), .B2(27'sd178549), .A1(-27'sd30339886), .A2(27'sd13959445))
        bq_l2 (.clk(clk), .rst(rst), .start(sp_d1),    .x(sp_f1), .y(sp_f2), .done(sp_d2));

    // filter output is U<<8; take U<<2 (x4 vs the 0.4 V/unit pre-scale -> ~1.6 V per MAME unit at the MC3417 output),
    // chosen so speech vs effects loudness is in the region of MAME's (#unverified, DOG VOLUME pot covers the rest)
    // Victory: MAME routes the board at 0.5 (one channel = 5461/32768) and the TMS at 1.0, so one TMS unit
    // = 12 channel full-scales; channel full-scale is U = 8192 here -> sp_u = 3 * tms
    wire signed [19:0] sp_tms = {{4{tms[15]}}, tms} + {{3{tms[15]}}, tms, 1'b0};

    // Victory speech filter at E/8: bilinear of the p58 network, split 1-pole (8.35 kHz) + biquad (f0 3.70 kHz,
    // Q 1.22), unity DC gain per section so the level stays the MAME calibration above (step overshoot 1.22x)
    logic signed [25:0] vf_1, vf_2;
    logic vf_d1, vf_d2;
    exidy_biquad #(.DW(26), .B0(27'sd3186876), .B1(27'sd3186876), .B2(27'sd0), .A1(-27'sd10403463), .A2(27'sd0))
        bq_v1 (.clk(clk), .rst(rst), .start(sp_start), .x({sp_tms, 6'd0}), .y(vf_1), .done(vf_d1));
    exidy_biquad #(.DW(26), .B0(27'sd165344), .B1(27'sd330688), .B2(27'sd165344), .A1(-27'sd30286043), .A2(27'sd14170203))
        bq_v2 (.clk(clk), .rst(rst), .start(vf_d1),    .x(vf_1),            .y(vf_2), .done(vf_d2));

    wire signed [19:0] sp_u   = tms_on ? vf_2[25:6] : sp_f2[25:6];
    wire unused_mix = &{1'b0, filt[7:6], sp_mul[30:29], sp_mul[2:0], sp_f2[5:0], sp_d2, vf_2[5:0], vf_d2};

    // ---------------- mix
    wire signed [19:0] sfx_u = {{2{chy[0][17]}}, chy[0]} + {{2{chy[1][17]}}, chy[1]} + {{2{chy[2][17]}}, chy[2]};
    wire signed [23:0] m_mus = mus_y * $signed({1'b0, vol_music});
    wire signed [24:0] m_sfx = sfx_u * $signed({1'b0, vol_sfx});
    wire signed [24:0] m_sp  = sp_u  * $signed({1'b0, vol_speech});
    wire signed [25:0] mix   = {{2{m_mus[23]}}, m_mus} + {m_sfx[24], m_sfx} + {m_sp[24], m_sp};   // x8 of pot-scaled sum

    // DC block (1-pole HPF, coefficient 2^-14 -> ~8.7 Hz) and 15.6 kHz 1-pole (7/64)
    logic signed [45:0] dc_acc;          // Q20 of mix
    wire  signed [25:0] dc   = dc_acc[45:20];
    wire  signed [26:0] hp   = {mix[25], mix} - {dc[25], dc};
    logic signed [34:0] lp_acc;          // Q8
    wire  signed [26:0] lpv  = lp_acc[34:8];
    wire  signed [27:0] lpd  = {hp[26], hp} - {lpv[26], lpv};
    wire  signed [26:0] o32  = lpv >>> 5;

    always_ff @(posedge clk) begin
        if (rst) begin
            dc_acc <= '0;
            lp_acc <= '0;
            audio  <= 16'sd0;
        end else if (ce) begin
            dc_acc <= dc_acc + {{14{hp[26]}}, hp, 5'd0} + {{14{hp[26]}}, hp, 5'd0};   // (mix-dc) << 6
            lp_acc <= lp_acc + {{5{lpd[27]}}, lpd, 2'b00} + {{4{lpd[27]}}, lpd, 3'b000} + {{3{lpd[27]}}, lpd, 4'b0000}; // *28 = 7/64 in Q8
            audio  <= (o32 > 27'sd32767) ? 16'sd32767 : (o32 < -27'sd32768) ? -16'sd32768 : o32[15:0];
        end
    end
endmodule

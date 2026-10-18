//============================================================================
//
//  Exidy Car Polo main board (MAME carpolo.cpp / carpolo_m.cpp / carpolo_v.cpp), on the pooled 6502.
//  Copyright (C) 2026 Rodimus
//
//  Video: score-area / field fill, border, four cars + ball + special char (16x16, 1 bpp, sprite ROM =
//  the pooled rom_spr, code remap PROM), two 2x-zoomed goals, eight alpha rows; MAME's draw order and
//  colour-PROM pens. Same 336 x 280 raster at 5.6448 MHz, 240 pixels wide.
//  Collisions: at vblank a sequential checker repeats MAME screen_vblank() in MAME's order (car-car,
//  car-ball, car-goal, ball-screen, car-border) with MAME's hit selection (last sprite column with a hit,
//  first row in it) and coordinate formula, then raises the 74148 lines together.
//  Inputs: 74148 priority encoder, coin / steering 7474s and the pedal 74153 sampled once per frame
//  (MAME timer_tick). No sound: MAME has none for this board.
//
//============================================================================

module carpolo_main
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,
    input  logic        ce_pix,         // 5.6448 MHz (board ph == 3)
    input  logic        cpu_ce,         // 940.75 kHz (11.289 MHz / 12), paused by the board

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic [15:0] cpu_a,
    input  logic  [7:0] cpu_do,
    input  logic        cpu_rw,
    output logic  [7:0] cpu_di,
    output logic        cpu_irq_n,
    input  logic  [7:0] rom_d,          // F000-FFFF from rom_main

    output logic [10:0] spr_a,          // pooled sprite ROM (gfx1 at 0x14000)
    input  logic  [7:0] spr_d,

    input  logic  [7:0] in0,            // IN0 coins 1-4 (active high)
    input  logic  [7:0] dsw,            // IN1 game-time DIP
    input  logic  [7:0] in2,            // IN2 forward / reverse (bits 7-4 = P1-P4, active low)
    input  logic  [7:0] pedals,         // PEDALS: {P4 B2, P4 B1, ... P1 B2, P1 B1}
    input  logic  [7:0] dial1,
    input  logic  [7:0] dial2,
    input  logic  [7:0] dial3,
    input  logic  [7:0] dial4,

    output logic  [8:0] pix_x,
    output logic  [8:0] pix_y,
    output logic  [4:0] pix_idx,        // colour PROM index (CRT Flip frame buffer)
    output logic [23:0] pix_rgb,
    input  logic  [4:0] pal_ri,         // second colour read port (CRT Flip readout)
    output logic [23:0] pal_rq,
    output logic        vbl_raw,
    output logic [31:0] snd             // sound board inputs (dsnd sources 0-3, tools/dsnd_boards.py "carpolo")
);

/////////////////////////////  Raster  /////////////////////////////

localparam [8:0] H_TOTAL = 9'd336, V_TOTAL = 9'd280;
logic [8:0] hcnt = 9'd0, vcnt = 9'd0;
always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (hcnt == H_TOTAL - 9'd1) begin
            hcnt <= 9'd0;
            vcnt <= (vcnt == V_TOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
        end
        else hcnt <= hcnt + 9'd1;
    end
end
assign vbl_raw = vcnt[8];
wire vbl_tick = ce_pix && hcnt == 9'd0 && vcnt == 9'd256;    // MAME screen_vblank(1)

/////////////////////////////  Small ROMs / PROMs (ioctl)  /////////////////////////////

// gfx2 goal 0x15800 (256), gfx3 alpha 0x16000 (512), user1 remap 0x16800 (32), colour PROM 0x14800 (32)
logic [7:0] remap [0:31];
logic [7:0] cprom [0:31];
always_ff @(posedge clk) begin
    if (ioctl_wr0 && ioctl_addr[24:5] == 20'h00B40) remap[ioctl_addr[4:0]] <= ioctl_dout;   // 0x16800
    if (ioctl_wr0 && ioctl_addr[24:5] == 20'h00A40) cprom[ioctl_addr[4:0]] <= ioctl_dout;   // 0x14800
end

logic [7:0] goal_sa, goal_ca, goal_sq, goal_cq, ach_q;
logic [8:0] ach_a;
dpram_dc #(.widthad_a(8)) goal_rom
(
    .clock_a(clk), .address_a(ioctl_wr0 ? ioctl_addr[7:0] : goal_sa), .data_a(ioctl_dout),
    .wren_a(ioctl_wr0 && ioctl_addr[24:8] == 17'h00158), .q_a(goal_sq),
    .clock_b(clk), .address_b(goal_ca), .data_b(8'h00), .wren_b(1'b0), .q_b(goal_cq)
);
dpram_dc #(.widthad_a(9)) alpha_rom
(
    .clock_a(clk), .address_a(ioctl_wr0 ? ioctl_addr[8:0] : ach_a), .data_a(ioctl_dout),
    .wren_a(ioctl_wr0 && ioctl_addr[24:9] == 16'h00B0), .q_a(ach_q),
    .clock_b(clk), .address_b(9'd0), .data_b(8'h00), .wren_b(1'b0), .q_b()
);

// colour PROM -> MAME carpolo_palette() levels (R / G 3 bits, B 2 bits through resistor ladders)
function automatic [7:0] lvl3(input [2:0] v);
    case (v)
        3'd0: lvl3 = 8'h00; 3'd1: lvl3 = 8'h1C; 3'd2: lvl3 = 8'h38; 3'd3: lvl3 = 8'h58;
        3'd4: lvl3 = 8'h75; 3'd5: lvl3 = 8'h9C; 3'd6: lvl3 = 8'hCA; default: lvl3 = 8'hF8;
    endcase
endfunction
function automatic [7:0] lvl2(input [1:0] v);
    case (v)
        2'd0: lvl2 = 8'h0B; 2'd1: lvl2 = 8'h4C; 2'd2: lvl2 = 8'h96; default: lvl2 = 8'hFF;
    endcase
endfunction
function automatic [23:0] crgb(input [7:0] p);
    crgb = {lvl3(p[7:5]), lvl3(p[4:2]), lvl2(p[1:0])};
endfunction
assign pal_rq = crgb(cprom[pal_ri]);

// goal PROM byte -> pen (ROMREGION_INVERT; planes = the low nibble)
function automatic [3:0] goal_pen(input [7:0] b);
    goal_pen = ~b[3:0];
endfunction
// goal row r (0-31) -> PROM row base (MAME goallayout: rows 0-7 at 192, 8-23 at 0, 24-31 at 128; 8 bytes per row)
function automatic [7:0] goal_base(input [4:0] r);
    if      (r < 5'd8)  goal_base = 8'd192 + {2'd0, r[2:0], 3'd0};
    else if (r < 5'd24) goal_base = {r - 5'd8, 3'd0};
    else                goal_base = 8'd128 + {2'd0, r[2:0], 3'd0};
endfunction

/////////////////////////////  CPU bus  /////////////////////////////

wire wr = cpu_ce & ~cpu_rw;
wire s_ram   = cpu_a[15:9] == 7'd0;                     // 0000-01FF
wire s_alpha = cpu_a[15:8] == 8'h30;                    // 3000-30FF (write only)
wire s_spr   = cpu_a[15:4] == 12'h400;                  // 4000-400F (write only)
wire s_pia0  = cpu_a[15:10] == 6'b010101;               // 5400-5403
wire s_pia1  = cpu_a[15:10] == 6'b010110;               // 5800-5803
wire s_coll  = cpu_a[15:3] == 13'h1400;                 // A000-A007
wire s_clr   = cpu_a[15:3] == 13'h1600;                 // B000-B006
wire s_cause = cpu_a == 16'hC000;
wire s_rom   = cpu_a[15:12] == 4'hF;

logic [7:0] ram_q, alpha_q;
logic [7:0] alpha_sa;
dpram_dc #(.widthad_a(9)) work_ram
(
    .clock_a(clk), .address_a(cpu_a[8:0]), .data_a(cpu_do), .wren_a(wr & s_ram), .q_a(ram_q),
    .clock_b(clk), .address_b(9'd0), .data_b(8'h00), .wren_b(1'b0), .q_b()
);
dpram_dc #(.widthad_a(8)) alpha_ram
(
    .clock_a(clk), .address_a(cpu_a[7:0]), .data_a(cpu_do), .wren_a(wr & s_alpha), .q_a(),
    .clock_b(clk), .address_b(alpha_sa), .data_b(8'h00), .wren_b(1'b0), .q_b(alpha_q)
);

logic [7:0] sr [0:15];                                  // sprite RAM
always_ff @(posedge clk) if (wr && s_spr) sr[cpu_a[3:0]] <= cpu_do;

// ---- PIAs ----
logic [7:0] pia0_q, pia1_q, p0_pa_o, p0_pa_oe, p0_pb_o, p0_pb_oe;
logic       p0_ca2, p0_ca2_oe, p0_cb2, p0_cb2_oe, p1_ca2, p1_ca2_oe, p1_cb2, p1_cb2_oe;
logic       za, zb;
logic [3:0] dir_q = 4'd0, mov_q = 4'd0;                 // index 0 = P1 .. 3 = P4
logic [7:0] p1_pb_o, p1_pb_oe;

pia6821 pia0
(
    .clk(clk), .rst(reset), .ce(cpu_ce), .cs(s_pia0), .rw(cpu_rw), .rs(cpu_a[1:0]), .din(cpu_do), .dout(pia0_q),
    .irqa(), .irqb(),
    .pa_i(8'h00), .pa_o(p0_pa_o), .pa_oe(p0_pa_oe), .ca1(1'b0), .ca2_i(1'b1), .ca2_o(p0_ca2), .ca2_oe(p0_ca2_oe),
    .pb_i({2'b00, za, zb, 4'h0}), .pb_o(p0_pb_o), .pb_oe(p0_pb_oe), .cb1(1'b0), .cb2_i(1'b1), .cb2_o(p0_cb2), .cb2_oe(p0_cb2_oe)
);
pia6821 pia1
(
    .clk(clk), .rst(reset), .ce(cpu_ce), .cs(s_pia1), .rw(cpu_rw), .rs(cpu_a[1:0]), .din(cpu_do), .dout(pia1_q),
    .irqa(), .irqb(),
    .pa_i({in2[7:4], dir_q[0], dir_q[1], dir_q[2], dir_q[3]}), .pa_o(), .pa_oe(),
    .ca1(1'b0), .ca2_i(1'b1), .ca2_o(p1_ca2), .ca2_oe(p1_ca2_oe),
    .pb_i({mov_q[0], mov_q[1], mov_q[2], mov_q[3], 4'h0}), .pb_o(p1_pb_o), .pb_oe(p1_pb_oe),
    .cb1(1'b0), .cb2_i(1'b1), .cb2_o(p1_cb2), .cb2_oe(p1_cb2_oe)
);

// 7474 clears (active low), from PIA outputs (inactive while the pin is an input)
wire [3:0] coin_clr_n  = {p1_cb2_oe ? p1_cb2 : 1'b1, p1_ca2_oe ? p1_ca2 : 1'b1,
                          p0_cb2_oe ? p0_cb2 : 1'b1, p0_ca2_oe ? p0_ca2 : 1'b1};   // coin 4..1
wire       steer_clr_n = p0_pa_oe[3] ? p0_pa_o[3] : 1'b1;

/////////////////////////////  Per-frame inputs (MAME timer_tick)  /////////////////////////////

logic [3:0]  coin_q = 4'd0, coin_last = 4'd0;
logic [31:0] dial_last = 32'd0;                          // {P4, P3, P2, P1}
logic [3:0]  dir_d = 4'd0, bit0_last = 4'd0;
logic [7:0]  ped = 8'd0;
wire  [31:0] dial_v = {dial4, dial3, dial2, dial1};
logic [3:0]  d_new;
always_comb begin
    for (int p = 0; p < 4; p++) begin
        d_new[p] = dir_d[p];
        if (dial_v[p*8 +: 8] != dial_last[p*8 +: 8]) d_new[p] = (dial_v[p*8 +: 8] - dial_last[p*8 +: 8]) >= 8'h80;
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        coin_q <= 4'd0; mov_q <= 4'd0; dir_q <= 4'd0; coin_last <= in0[3:0];
        dial_last <= dial_v; bit0_last <= {dial4[0], dial3[0], dial2[0], dial1[0]};
    end
    else begin
        if (vbl_tick) begin
            coin_last <= in0[3:0];
            ped       <= pedals;
            dir_d     <= d_new;
            dial_last <= dial_v;
            bit0_last <= {dial4[0], dial3[0], dial2[0], dial1[0]};
            for (int p = 0; p < 4; p++)
                if (dial_v[p*8] && !bit0_last[p]) begin dir_q[p] <= d_new[p]; mov_q[p] <= 1'b1; end
            for (int c = 0; c < 4; c++) if (in0[c] && !coin_last[c]) coin_q[c] <= 1'b1;
        end
        for (int c = 0; c < 4; c++) if (!coin_clr_n[c]) coin_q[c] <= 1'b0;
        if (!steer_clr_n) mov_q <= 4'd0;
    end
end

// 74153: I0..I3 a = B1 | B2 of P1..P4, b = B2; select = PIA0 PB7:PB6
wire [1:0] psel = {p0_pb_oe[7] ? p0_pb_o[7] : 1'b0, p0_pb_oe[6] ? p0_pb_o[6] : 1'b0};
assign za = ped[{psel, 1'b0}] | ped[{psel, 1'b1}];
assign zb = ped[{psel, 1'b1}];

/////////////////////////////  Sound board inputs (sheets M, N)  /////////////////////////////

// PIA pins read high while they are inputs
wire [7:0] p0_pa = p0_pa_o | ~p0_pa_oe, p0_pb = p0_pb_o | ~p0_pb_oe, p1_pb = p1_pb_o | ~p1_pb_oe;

// speed out: 74173 1J/1M/1L/1N, D = PIA1 PB3-PB1, clocked by the PB0 strobe rising, enabled by the decode of the
// pedal select lines PB7/PB6 (player = pedal mux index #unverified)
logic [2:0] spd [4] = '{3'd7, 3'd7, 3'd7, 3'd7};
logic       strobe_q = 1'b1;
always_ff @(posedge clk) begin
    strobe_q <= p0_pb[0];
    if (p0_pb[0] && !strobe_q) spd[psel] <= p0_pb[3:1];
end

// crash pulse extenders: 74161 2M/2N/.. /CLR = PIA1 PA6/PA4/PA2/PA1, clocked by TLCA (vertical count bits 0-3
// carry, one tick per 16 lines); CRASH = ~RCO: high while the bit is low and for 15 TLCA ticks after
logic [3:0] crash_cnt [4] = '{4'hF, 4'hF, 4'hF, 4'hF};
wire  [3:0] crash_n = {p0_pa[1], p0_pa[2], p0_pa[4], p0_pa[6]};                   // P4..P1
wire        tlca    = ce_pix && hcnt == 9'd0 && vcnt[3:0] == 4'hF;
always_ff @(posedge clk)
    for (int p = 0; p < 4; p++)
        if (!crash_n[p])                          crash_cnt[p] <= 4'd0;
        else if (tlca && crash_cnt[p] != 4'hF)    crash_cnt[p] <= crash_cnt[p] + 4'd1;

// 0: {PA7 ball hit, PA5 score (both idle high, pulsed low), 0, 0, CRASH P4..P1}; 1: {0, speed P2, speed P1};
// 2: {0, speed P4, speed P3}; 3: {0, ACTIVE P4..P1} (PIA2 PB0..PB3 = P4..P1)
assign snd = {4'd0, p1_pb[0], p1_pb[1], p1_pb[2], p1_pb[3],
              2'd0, spd[3], spd[2], 2'd0, spd[1], spd[0],
              p0_pa[7], p0_pa[5], 2'd0,
              crash_cnt[3] != 4'hF, crash_cnt[2] != 4'hF, crash_cnt[1] != 4'hF, crash_cnt[0] != 4'hF};

/////////////////////////////  Interrupt system (74148)  /////////////////////////////

logic       ln3 = 1'b0, ln2 = 1'b0, ln1 = 1'b0, ln0 = 1'b0;
logic [7:0] ext = 8'h00;
logic [7:0] c_ball_screen = 8'd0, c_car_ball_x = 8'd0, c_car_ball_y = 8'd0, c_car_car = 8'd0;
logic [7:0] c_car_goal = 8'd0, c_car_ball = 8'd0, c_car_border = 8'd0;

wire [7:0] lines = {coin_q[0], coin_q[1], coin_q[2], coin_q[3], ln3, ln2, ln1, ln0};   // 74148 inputs 7..0
logic [2:0] enc;
always_comb begin
    enc = 3'd7;                                          // outputs (active low) of the highest active input
    for (int i = 0; i < 8; i++) if (lines[i]) enc = 3'd7 - 3'(i);
end
assign cpu_irq_n = ~|lines;
wire [7:0] cause = {4'd0, enc, 1'b0} | ext;

/////////////////////////////  Collision checker (MAME screen_vblank)  /////////////////////////////

// jobs: 0-5 car-car pairs, 6-9 car-ball, 10-17 car-goal (car1 L, car1 R, ...), 18 ball-left goal,
// 19 ball-right goal, 20 ball-border, 21-24 car-border; car-car / car-ball / car-goal / car-border stop at
// the first hit, the ball checks all run (later causes overwrite earlier ones, as in MAME)
logic [7:0]  sv [0:15];                                  // sprite RAM latched at vblank
typedef enum logic [2:0] {K_IDLE, K_JOB, K_ROW, K_FETCH, K_GFETCH, K_EVAL, K_NEXT, K_APPLY} kstate_t;
kstate_t     ks = K_IDLE;
logic [4:0]  job;
logic [2:0]  ja, jb;
logic [1:0]  jkind;                                      // 0 sprite-sprite, 1 sprite-goal, 2 border
logic        jright, jpost;
logic [4:0]  row;
logic [3:0]  fstep;
logic        fsel;
logic [3:0]  fcode, frow;
logic [15:0] frow_q, r1, r2;                             // MSB = column 0
logic [7:0]  gb [0:7];
logic signed [5:0] bk;                                   // best column (-1 = none)
logic [4:0]  bj;
logic [1:0]  btype;
logic        done_cc, done_cb, done_cg, done_cbd;
logic        r_cc, r_cb, r_cg, r_bs, r_bd;
logic [7:0]  r_cc_v, r_cb_v, r_cbx, r_cby, r_cg_v, r_bs_v, r_bd_v;
logic [10:0] k_spr_a;
wire         k_busy = (ks != K_IDLE);

function automatic [2:0] job_a(input [4:0] j);           // sprite 1: 0-3 cars, 4 ball
    case (j)
        5'd0, 5'd1, 5'd2:                    job_a = 3'd0;
        5'd3, 5'd4:                          job_a = 3'd1;
        5'd5:                                job_a = 3'd2;
        5'd6, 5'd10, 5'd11, 5'd21:           job_a = 3'd0;
        5'd7, 5'd12, 5'd13, 5'd22:           job_a = 3'd1;
        5'd8, 5'd14, 5'd15, 5'd23:           job_a = 3'd2;
        5'd9, 5'd16, 5'd17, 5'd24:           job_a = 3'd3;
        default:                             job_a = 3'd4;  // 18-20 ball
    endcase
endfunction
function automatic [2:0] job_b(input [4:0] j);
    case (j)
        5'd0:             job_b = 3'd1;
        5'd1, 5'd3:       job_b = 3'd2;
        5'd2, 5'd4, 5'd5: job_b = 3'd3;
        default:          job_b = 3'd4;
    endcase
endfunction
function automatic [3:0] code_of(input [2:0] s, input [7:0] c, input [7:0] d, input [7:0] e);
    case (s)
        3'd0: code_of = c[3:0]; 3'd1: code_of = c[7:4];
        3'd2: code_of = d[3:0]; 3'd3: code_of = d[7:4];
        default: code_of = e[3:0];
    endcase
endfunction

// job geometry (MAME int coordinates: 240 - position)
wire [7:0] rm_a = remap[{(ja == 3'd4), code_of(ja, sv[12], sv[13], sv[14])}];
wire [7:0] rm_b = remap[{(jb == 3'd4), code_of(jb, sv[12], sv[13], sv[14])}];
wire signed [9:0] x1 = 10'sd240 - $signed({2'b00, sv[{ja, 1'b0}]});
wire signed [9:0] y1 = 10'sd240 - $signed({2'b00, sv[{ja, 1'b1}]});
wire signed [9:0] x2 = (jkind == 2'd0) ? 10'sd240 - $signed({2'b00, sv[{jb, 1'b0}]}) : jright ? 10'sd200 : 10'sd24;
wire signed [9:0] y2 = (jkind == 2'd0) ? 10'sd240 - $signed({2'b00, sv[{jb, 1'b1}]}) : 10'sd112;
wire in_range = (jkind == 2'd0) ? ((x1 - x2 < 10'sd16) && (x2 - x1 < 10'sd16) && (y1 - y2 < 10'sd16) && (y2 - y1 < 10'sd16)) :
                (jkind == 2'd1) ? ((y1 + 10'sd16 > 10'sd112) && (y1 < 10'sd176) && (x1 + 10'sd16 > x2) && (x1 < x2 + 10'sd16)) :
                1'b1;
// normalized bitmap offsets (MAME normalize_coordinates)
wire signed [9:0] nx1 = (x1 > x2) ? x1 - x2 : 10'sd0;
wire signed [9:0] nx2 = (x2 > x1) ? x2 - x1 : 10'sd0;
wire signed [9:0] ny1 = (y1 > y2) ? y1 - y2 : 10'sd0;
wire signed [9:0] ny2 = (y2 > y1) ? y2 - y1 : 10'sd0;
wire signed [9:0] by  = ny1 + $signed({5'd0, row}) - ny2;   // row in sprite 2 / goal bitmap
wire       [4:0]  grow = by[5:1];                           // goal row (zoom 2x)

// evaluate one sprite-1 row: last column with a hit
logic signed [5:0] ev_k;
logic [1:0]        ev_t;
logic [15:0]       ev_h;
logic [31:0]       ev_tt;
logic signed [9:0] c2x [0:15];                           // column k of sprite 1 in sprite 2 / goal bitmap x
logic [2:0]        gcol [0:15];
logic [7:0]        bxx [0:15];
wire  [7:0]        byy = y1[7:0] + {3'd0, row};          // border check: MAME uint8 coordinates
always_comb begin
    for (int k = 0; k < 16; k++) begin
        c2x[k]  = nx1 + 10'(k) - nx2;
        gcol[k] = jright ? 3'd7 - c2x[k][3:1] : c2x[k][3:1];
        bxx[k]  = x1[7:0] + 8'(k);
        ev_h[k] = 1'b0;
        ev_tt[k*2 +: 2] = 2'd0;
        if (r1[4'd15 - 4'(k)]) begin
            if (jkind == 2'd0) begin
                if (c2x[k] >= 0 && c2x[k] < 16) ev_h[k] = r2[4'd15 - c2x[k][3:0]];
            end
            else if (jkind == 2'd1) begin
                if (c2x[k] >= 0 && c2x[k] < 16 && by >= 0 && by < 64) begin
                    if (goal_pen(gb[gcol[k]]) == 4'd8) begin
                        ev_h[k] = 1'b1; ev_tt[k*2 +: 2] = 2'd1;
                    end
                    else if (!jpost && goal_pen(gb[gcol[k]]) == 4'd6) begin
                        ev_h[k] = 1'b1; ev_tt[k*2 +: 2] = 2'd2;
                    end
                end
            end
            else begin
                if (bxx[k] == 8'd0 || bxx[k] == 8'd239) begin
                    ev_h[k] = 1'b1; ev_tt[k*2 +: 2] = 2'd1;
                end
                else if (byy == 8'd16 || byy == 8'd255) begin
                    ev_h[k] = 1'b1; ev_tt[k*2 +: 2] = 2'd2;
                end
            end
        end
    end
    ev_k = -6'sd1; ev_t = 2'd0;
    for (int k = 0; k < 16; k++) if (ev_h[k]) begin ev_k = 6'(k); ev_t = ev_tt[k*2 +: 2]; end
end

wire [9:0] cb_x = 10'(nx1 + nx1) + 10'(bk);              // MAME col_x = (x1 + x) & 15
wire [9:0] cb_y = 10'(ny1 + ny1) + {5'd0, bj};

always_ff @(posedge clk) begin
    if (reset) begin
        ks <= K_IDLE; ln3 <= 1'b0; ln2 <= 1'b0; ln1 <= 1'b0; ln0 <= 1'b0; ext <= 8'h00;
    end
    else begin
        // CPU clears (B000-B006)
        if (wr && s_clr) case (cpu_a[2:0])
            3'd0:             ln3 <= 1'b0;
            3'd1, 3'd4, 3'd5: ln0 <= 1'b0;
            3'd3:             ln2 <= 1'b0;
            3'd6:             ln1 <= 1'b0;
            default: ;
        endcase

        case (ks)
            K_IDLE: if (vbl_tick) begin
                for (int i = 0; i < 16; i++) sv[i] <= sr[i];
                job <= 5'd0; done_cc <= 1'b0; done_cb <= 1'b0; done_cg <= 1'b0; done_cbd <= 1'b0;
                r_cc <= 1'b0; r_cb <= 1'b0; r_cg <= 1'b0; r_bs <= 1'b0; r_bd <= 1'b0;
                ks <= K_JOB;
            end

            K_JOB: begin
                if (job == 5'd25) ks <= K_APPLY;
                else if ((job <= 5'd5 && done_cc) || (job >= 5'd6 && job <= 5'd9 && done_cb) ||
                         (job >= 5'd10 && job <= 5'd17 && done_cg) || (job >= 5'd21 && done_cbd))
                    job <= job + 5'd1;
                else begin
                    ja     <= job_a(job);
                    jb     <= job_b(job);
                    jkind  <= (job <= 5'd9) ? 2'd0 : (job <= 5'd19) ? 2'd1 : 2'd2;
                    jright <= (job >= 5'd10 && job <= 5'd17) ? job[0] : (job == 5'd19);
                    jpost  <= (job <= 5'd17);
                    bk <= -6'sd1; bj <= 5'd0; btype <= 2'd0;
                    row <= 5'd0;
                    ks  <= K_ROW;
                end
            end

            K_ROW: begin
                if (!in_range || row == 5'd16) ks <= K_NEXT;
                else begin
                    fsel <= 1'b0; fstep <= 4'd0; fcode <= rm_a[3:0];
                    frow <= rm_a[4] ? 4'd15 - row[3:0] : row[3:0];
                    ks <= K_FETCH;
                end
            end

            K_FETCH: begin                               // 4 reads (2-clock latency) -> sprite row
                fstep <= fstep + 4'd1;
                case (fstep)
                    4'd0: k_spr_a <= {1'b0, 2'd3, fcode, frow};
                    4'd1: k_spr_a <= {1'b0, 2'd2, fcode, frow};
                    4'd2: begin k_spr_a <= {1'b0, 2'd1, fcode, frow}; frow_q[15:12] <= spr_d[3:0]; end
                    4'd3: begin k_spr_a <= {1'b0, 2'd0, fcode, frow}; frow_q[11:8]  <= spr_d[3:0]; end
                    4'd4: frow_q[7:4] <= spr_d[3:0];
                    4'd5: frow_q[3:0] <= spr_d[3:0];
                    default: begin
                        if (fsel) begin r2 <= frow_q; ks <= K_EVAL; end
                        else begin
                            r1 <= frow_q;
                            if (jkind == 2'd0) begin
                                if (by >= 0 && by < 16) begin
                                    fsel <= 1'b1; fstep <= 4'd0; fcode <= rm_b[3:0];
                                    frow <= rm_b[4] ? 4'd15 - by[3:0] : by[3:0];
                                end
                                else begin r2 <= 16'd0; ks <= K_EVAL; end
                            end
                            else if (jkind == 2'd1) begin fstep <= 4'd0; ks <= K_GFETCH; end
                            else ks <= K_EVAL;
                        end
                    end
                endcase
            end

            K_GFETCH: begin                              // the 8 goal bytes of goal row `grow`
                fstep <= fstep + 4'd1;
                if (fstep < 4'd8) goal_ca <= goal_base(grow) + {5'd0, fstep[2:0]};
                if (fstep >= 4'd2) gb[3'(fstep - 4'd2)] <= goal_cq;
                if (fstep == 4'd9) ks <= K_EVAL;
            end

            K_EVAL: begin
                if (ev_k > bk) begin bk <= ev_k; bj <= row; btype <= ev_t; end
                row <= row + 5'd1;
                ks  <= K_ROW;
            end

            K_NEXT: begin
                if (bk >= 0) begin
                    if (job <= 5'd5) begin
                        done_cc <= 1'b1; r_cc <= 1'b1;
                        r_cc_v  <= ~((8'd1 << (3'd3 - ja)) | (8'd1 << (3'd3 - jb)));
                    end
                    else if (job <= 5'd9) begin
                        done_cb <= 1'b1; r_cb <= 1'b1; r_cb_v <= {5'd0, ja};
                        r_cbx <= {4'd0, cb_x[3:0]}; r_cby <= {4'd0, cb_y[3:0]};
                    end
                    else if (job <= 5'd17) begin
                        done_cg <= 1'b1; r_cg <= 1'b1; r_cg_v <= {4'd0, jright, ja};
                    end
                    else if (job <= 5'd19) begin
                        r_bs <= 1'b1; r_bs_v <= ((btype == 2'd1) ? 8'h05 : 8'h03) | (jright ? 8'h08 : 8'h00);
                    end
                    else if (job == 5'd20) begin
                        r_bs <= 1'b1; r_bs_v <= 8'h06;
                    end
                    else begin
                        done_cbd <= 1'b1; r_bd <= 1'b1; r_bd_v <= {5'd0, (btype == 2'd2), ja[1:0]};
                    end
                end
                job <= job + 5'd1;
                ks  <= K_JOB;
            end

            K_APPLY: begin                               // raise all lines at once, in MAME's write order
                ln0 <= 1'b1; ext <= 8'h00;               // timer
                if (r_cc) begin ln2 <= 1'b1; c_car_car <= r_cc_v; end
                if (r_cb) begin ln0 <= 1'b1; ext <= 8'h40; c_car_ball <= r_cb_v; c_car_ball_x <= r_cbx; c_car_ball_y <= r_cby; end
                if (r_cg) begin ln1 <= 1'b1; c_car_goal <= r_cg_v; end
                if (r_bs) begin ln3 <= 1'b1; c_ball_screen <= r_bs_v; end
                if (r_bd) begin ln0 <= 1'b1; ext <= 8'h50; c_car_border <= r_bd_v; end
                ks <= K_IDLE;
            end

            default: ks <= K_IDLE;
        endcase
    end
end

/////////////////////////////  Scan-out  /////////////////////////////

// sprites 0-3 cars 1-4, 4 ball, 5 special char: rows for the next line fetched in hblank (from H 240)
logic [15:0] srow [0:5], srow_n [0:5];
logic [7:0]  sxp [0:5], sxp_n [0:5];
logic [2:0]  ls, lstep;
logic        lact = 1'b0;
logic [8:0]  nline;
logic [10:0] l_spr_a;
logic [11:0] lrow;
logic [7:0]  goal_row [0:7];
logic [3:0]  gstep = 4'd15;

function automatic [3:0] sl_code(input [2:0] s, input [7:0] c, input [7:0] d, input [7:0] e);
    case (s)
        3'd0: sl_code = c[3:0]; 3'd1: sl_code = c[7:4];
        3'd2: sl_code = d[3:0]; 3'd3: sl_code = d[7:4];
        3'd4: sl_code = e[3:0]; default: sl_code = e[7:4];
    endcase
endfunction
// sprite RAM index of a sprite's x byte: cars 0, 2, 4, 6 (car 1 .. car 4), ball 8, special 10
wire [3:0] lpos = (ls == 3'd0) ? 4'd0 : (ls == 3'd1) ? 4'd2 : (ls == 3'd2) ? 4'd4 : (ls == 3'd3) ? 4'd6 :
                  (ls == 3'd4) ? 4'd8 : 4'd10;
wire [7:0] lrm    = remap[{(ls >= 3'd4), sl_code(ls, sr[12], sr[13], sr[14])}];
wire [7:0] lsy    = 8'd240 - sr[lpos + 4'd1];
wire [8:0] lr9    = nline - {1'b0, lsy};
wire       lin    = (lr9 < 9'd16) && (ls != 3'd5 || sr[15][0]);
wire [3:0] lrow_i = lrm[4] ? 4'd15 - lr9[3:0] : lr9[3:0];
wire signed [9:0] sgy  = $signed({1'b0, nline}) - 10'sd112;
wire       [4:0]  sgrow = sgy[5:1];

always_ff @(posedge clk) begin
    if (ce_pix && hcnt == 9'd240) begin
        lact  <= 1'b1; ls <= 3'd0; lstep <= 3'd0; gstep <= 4'd0;
        nline <= (vcnt == V_TOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
    end
    else begin
        if (lact && !k_busy) begin
            lstep <= lstep + 3'd1;
            case (lstep)
                3'd0: l_spr_a <= {1'b0, 2'd3, lrm[3:0], lrow_i};
                3'd1: l_spr_a <= {1'b0, 2'd2, lrm[3:0], lrow_i};
                3'd2: begin l_spr_a <= {1'b0, 2'd1, lrm[3:0], lrow_i}; lrow[11:8] <= spr_d[3:0]; end
                3'd3: begin l_spr_a <= {1'b0, 2'd0, lrm[3:0], lrow_i}; lrow[7:4]  <= spr_d[3:0]; end
                3'd4: lrow[3:0] <= spr_d[3:0];
                default: begin
                    srow_n[ls] <= lin ? {lrow, spr_d[3:0]} : 16'd0;
                    sxp_n[ls]  <= 8'd240 - sr[lpos];
                    lstep      <= 3'd0;
                    if (ls == 3'd5) lact <= 1'b0;
                    ls <= ls + 3'd1;
                end
            endcase
        end
        // goal row for the next line (both goals use the same bytes; the right one is mirrored)
        if (gstep != 4'd15) begin
            gstep <= gstep + 4'd1;
            if (gstep < 4'd8) goal_sa <= goal_base(sgrow) + {5'd0, gstep[2:0]};
            if (gstep >= 4'd2) goal_row[3'(gstep - 4'd2)] <= (sgy >= 0 && sgy < 64) ? goal_sq : 8'hFF;
            if (gstep == 4'd9) gstep <= 4'd15;
        end
    end
    if (ce_pix && hcnt == H_TOTAL - 9'd1)
        for (int s = 0; s < 6; s++) begin srow[s] <= srow_n[s]; sxp[s] <= sxp_n[s]; end
end
assign spr_a = k_busy ? k_spr_a : l_spr_a;

// alpha: 8 text lines shown at character rows 0, 1, 26, 27, 12, 13, 6, 7 (MAME draw_alpha_line)
function automatic [3:0] alpha_line(input [4:0] r);      // {valid, line}
    case (r)
        5'd0:  alpha_line = 4'b1000; 5'd1:  alpha_line = 4'b1001;
        5'd26: alpha_line = 4'b1010; 5'd27: alpha_line = 4'b1011;
        5'd12: alpha_line = 4'b1100; 5'd13: alpha_line = 4'b1101;
        5'd6:  alpha_line = 4'b1110; 5'd7:  alpha_line = 4'b1111;
        default: alpha_line = 4'b0000;
    endcase
endfunction
wire [8:0] t_h   = hcnt + 9'd9;                          // next 8-pixel group (see victory_main)
wire       t_nxt = t_h >= 9'd320;
wire [8:0] v_nxt = (vcnt == V_TOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
wire [7:0] t_y   = t_nxt ? v_nxt[7:0] : vcnt[7:0];
wire [7:0] t_x   = t_h[7:0] - (t_nxt ? 8'd80 : 8'd0);
wire       a_bd  = ce_pix && hcnt[2:0] == 3'd7;
logic [3:0] af = 4'd15;
logic [3:0] a_ln;
logic [2:0] a_row;
logic [4:0] a_col;
logic [7:0] a_nx = 8'd0, a_sr = 8'd0;
logic [1:0] a_cnx = 2'd0, a_c = 2'd0, a_cq;
always_ff @(posedge clk) begin
    if (a_bd) begin a_ln <= alpha_line(t_y[7:3]); a_row <= t_y[2:0]; a_col <= t_x[7:3]; af <= 4'd0; end
    else if (af != 4'd15) af <= af + 4'd1;
    case (af)
        4'd0: alpha_sa <= {a_ln[2:0], a_col};
        4'd2: begin ach_a <= {alpha_q[7:2], a_row}; a_cq <= alpha_q[1:0]; end
        4'd4: begin a_nx <= a_ln[3] ? ach_q : 8'd0; a_cnx <= a_cq; af <= 4'd15; end
        default: ;
    endcase
end

// pixel: MAME draw order, later layers win
wire [7:0] px = hcnt[7:0], py = vcnt[7:0];
logic [5:0] sp;                                          // sprite hits: 0-3 cars 1-4, 4 ball, 5 special
always_comb for (int s = 0; s < 6; s++) sp[s] = ((8'(px - sxp[s])) < 8'd16) && srow[s][4'd15 - 4'(px - sxp[s])];
wire [3:0] gpl = (px >= 8'd24  && px < 8'd40)  ? goal_pen(goal_row[3'((px - 8'd24) >> 1)]) : 4'd0;
wire [3:0] gpr = (px >= 8'd200 && px < 8'd216) ? goal_pen(goal_row[3'd7 - 3'((px - 8'd200) >> 1)]) : 4'd0;
logic [4:0] cidx;
always_comb begin
    cidx = (py < 8'd16) ? 5'd0 : 5'd1;                                                    // score area / field
    if (sp[0]) cidx = 5'd2;                                                               // car 1
    if (py == 8'd16 || py == 8'd255 || ((px == 8'd0 || px == 8'd239) && py >= 8'd16)) cidx = 5'd3;   // border
    if (sp[3]) cidx = 5'd4;                                                               // car 4
    if (sp[2]) cidx = 5'd5;                                                               // car 3
    if (sp[1]) cidx = 5'd6;                                                               // car 2
    if (sp[4]) cidx = 5'd7;                                                               // ball
    if (gpl != 4'd0) cidx = (gpl == 4'd8) ? 5'd9  : (gpl == 4'd2 || gpl == 4'd6) ? 5'd8 : 5'd0;   // left goal
    if (gpr != 4'd0) cidx = (gpr == 4'd8) ? 5'd10 : (gpr == 4'd2 || gpr == 4'd6) ? 5'd8 : 5'd0;   // right goal
    if (sp[5]) cidx = 5'd11;                                                              // special char
    if (a_sr[7]) cidx = 5'd12 + {3'd0, a_c};                                              // alpha
end

wire vis = (hcnt < 9'd240) && (vcnt < 9'd256);
always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (a_bd) begin a_sr <= a_nx; a_c <= a_cnx; end
        else a_sr <= a_sr << 1;
        pix_x   <= hcnt;
        pix_y   <= vcnt;
        pix_idx <= vis ? cidx : 5'd0;
        pix_rgb <= vis ? crgb(cprom[cidx]) : 24'd0;
    end
end

/////////////////////////////  CPU read mux  /////////////////////////////

always_comb begin
    cpu_di = 8'hFF;
    if      (s_ram)  cpu_di = ram_q;
    else if (s_pia0) cpu_di = pia0_q;
    else if (s_pia1) cpu_di = pia1_q;
    else if (s_coll) case (cpu_a[2:0])
        3'd0: cpu_di = c_ball_screen;
        3'd1: cpu_di = c_car_ball_x;
        3'd2: cpu_di = c_car_ball_y;
        3'd3: cpu_di = c_car_car;
        3'd4: cpu_di = c_car_border;
        3'd5: cpu_di = c_car_ball;
        3'd6: cpu_di = c_car_goal;
        default: cpu_di = {dsw[7:2], 2'b00};             // IN1: bits 1-0 = counter low bits (0)
    endcase
    else if (s_cause) cpu_di = cause;
    else if (s_rom)   cpu_di = rom_d;
end

endmodule

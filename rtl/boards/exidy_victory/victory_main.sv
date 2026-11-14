//  Based on MAME victory.cpp, victory_v.cpp (Aaron Giles, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module victory_main
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic        ce_pix,
    output logic        cen_p,
    output logic        cen_n,

    input  logic [15:0] z_a,
    input  logic  [7:0] z_do,
    input  logic        z_mreq_n,
    input  logic        z_iorq_n,
    input  logic        z_rd_n,
    input  logic        z_wr_n,
    input  logic        z_m1_n,
    output logic  [7:0] z_di,
    output logic        z_int_n,
    output logic        z_wait_n,

    input  logic  [7:0] rom_d,

    output logic [16:0] fg_a_addr,
    output logic  [7:0] fg_a_d,
    output logic        fg_a_we,
    input  logic  [7:0] fg_a_q,
    output logic [16:0] fg_b_addr,
    input  logic  [7:0] fg_b_q,

    input  logic  [7:0] dsw,
    input  logic  [7:0] buttons,
    input  logic  [7:0] coin,
    input  logic  [7:0] dial,

    output logic        snd_wr,
    output logic        snd_rd,
    input  logic  [7:0] snd_resp,
    input  logic  [1:0] snd_status,

    output logic  [8:0] pix_x,
    output logic  [8:0] pix_y,
    output logic  [8:0] pix_rgb,        // {R3, G3, B3}
    output logic  [5:0] pix_pen,
    input  logic  [5:0] pal_ri,
    output logic  [8:0] pal_rq,
    output logic        vbl_raw,

    input  logic        nv_wr,
    input  logic [10:0] nv_addr,
    input  logic  [7:0] nv_din,
    output logic  [7:0] nv_dout,
    input  logic        nv_saved,
    output logic        nv_dirty,

    output ram_pool_pkg::pram_i_t [5:0] pr_i,
    input  ram_pool_pkg::pram_o_t [5:0] pr_o
);

logic [14:0] acc = 15'd0;
logic        cpu_ph = 1'b0;
wire  [15:0] acc_n = {1'b0, acc} + 16'd8000;
always_ff @(posedge clk) begin
    cen_p <= 1'b0;
    cen_n <= 1'b0;
    if (acc_n >= 16'd22578) begin
        acc <= acc_n[14:0] - 15'd22578;
        if (!pause) begin
            cpu_ph <= ~cpu_ph;
            cen_p  <=  cpu_ph;
            cen_n  <= ~cpu_ph;
        end
    end
    else acc <= acc_n[14:0];
end

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

wire mreq_rd = ~z_mreq_n & ~z_rd_n;
wire mreq_wr = ~z_mreq_n & ~z_wr_n;
wire io_rd   = ~z_iorq_n & ~z_rd_n & z_m1_n;
wire int_ack = ~z_iorq_n & ~z_m1_n & ~z_int_n;
logic wr_d = 1'b0, rd_d = 1'b0;
always_ff @(posedge clk) begin wr_d <= mreq_wr; rd_d <= mreq_rd; end
wire wr_go  = mreq_wr & ~wr_d;
wire rd_end = ~mreq_rd & rd_d;
logic [15:0] rd_a;
always_ff @(posedge clk) if (mreq_rd) rd_a <= z_a;

wire r_rom   = z_a[15:14] != 2'b11;
wire r_vrd   = z_a[15:8] == 8'hC0;
wire r_vwr   = z_a[15:8] == 8'hC1;
wire r_pal   = z_a[15:9] == 7'b1100_001;
wire r_tile  = z_a[15:10] == 6'b1100_01;
wire r_char  = (z_a[15:11] >= 5'b11001) && (z_a[15:11] <= 5'b11011);
wire r_ram   = (z_a[15:12] == 4'hE) || (z_a[15:11] == 5'b11110);
wire r_snd   = (z_a[15:11] == 5'b11111) && !z_a[1];

logic [7:0]  tile_q, char_q, ram_q, tile_sq, char_sq;
logic [9:0]  tile_sa;
logic [12:0] char_sa;
wire  [12:0] char_ca = z_a[12:0] - 13'h0800;

assign pr_i[0] = '0;
assign pr_i[1] = '0;
assign pr_i[5] = '0;
assign pr_i[2].a_addr = {3'd0, char_ca};
assign pr_i[2].a_d    = z_do;
assign pr_i[2].a_we   = wr_go & r_char;
assign pr_i[2].b_addr = {3'd0, char_sa};
assign pr_i[2].b_d    = 8'h00;
assign pr_i[2].b_we   = 1'b0;
assign pr_i[3].a_addr = {3'd0, z_a[12:0]};
assign pr_i[3].a_d    = z_do;
assign pr_i[3].a_we   = wr_go & r_ram;
assign pr_i[3].b_addr = {5'b00010, nv_addr};
assign pr_i[3].b_d    = nv_din;
assign pr_i[3].b_we   = nv_wr;
assign pr_i[4].a_addr = {6'd0, z_a[9:0]};
assign pr_i[4].a_d    = z_do;
assign pr_i[4].a_we   = wr_go & r_tile;
assign pr_i[4].b_addr = {6'd0, tile_sa};
assign pr_i[4].b_d    = 8'h00;
assign pr_i[4].b_we   = 1'b0;
assign {char_q, char_sq} = {pr_o[2].a_q, pr_o[2].b_q};
assign {ram_q, nv_dout}  = {pr_o[3].a_q, pr_o[3].b_q};
assign {tile_q, tile_sq} = {pr_o[4].a_q, pr_o[4].b_q};

always_ff @(posedge clk) begin
    if (nv_saved)                                                   nv_dirty <= 1'b0;
    else if (wr_go && z_a[15:11] == 5'b11110 && z_do != ram_q)      nv_dirty <= 1'b1;
end

logic [8:0] pal [0:63];
always_ff @(posedge clk) if (wr_go && r_pal) pal[z_a[5:0]] <= {z_a[7], z_do};
function automatic [8:0] pen_rgb(input [8:0] p);
    pen_rgb = {p[8:6], p[2:0], p[5:3]};
endfunction
assign pal_rq = pen_rgb(pal[pal_ri]);

logic [7:0]  scrollx = 8'd0, scrolly = 8'd0, vctrl = 8'd0;
logic        vblank_irq = 1'b0, fgcoll = 1'b0, bgcoll = 1'b0;
logic [7:0]  fgcollx = 8'd0, fgcolly = 8'd0, bgcollx = 8'd0, bgcolly = 8'd0;
logic [7:0]  bgcoll_cnt = 8'd0;
logic [23:0] busy_cnt = 24'd0;

assign z_int_n = ~(vblank_irq | fgcoll | (bgcoll & vctrl[5]));

logic [15:0] mi = 16'd0;
logic  [8:0] mpc = 9'd0;
logic  [7:0] mr = 8'd0, mg = 8'd0, mb = 8'd0, mxp = 8'd0, myp = 8'd0, mcmd = 8'd0;
wire   [2:0] cmdlo = mcmd[2:0];

typedef enum logic [3:0] {
    E_IDLE, E_DISPATCH, E_C2, E_C3_COL, E_C3_ROW, E_C4_FETCH, E_C5_PT, E_C6_BYTE, E_C7, E_PLOT, E_COPY, E_NEXT
} estate_t;

estate_t     est = E_IDLE, ret_st = E_IDLE;
logic        prog = 1'b0;
logic        keep_going = 1'b0;
wire         eng_run = (est != E_IDLE);

logic  [2:0] pl_en;
logic  [1:0] pl_cur;
logic        pl_src;
logic [13:0] pl_sa, pl_da;
logic  [2:0] pl_sh;
logic        pl_coll, pl_hit;
logic  [3:0] pt;
logic  [7:0] pv, d0, d1;

logic  [3:0] c3_x;
logic  [6:0] c3_y, c3_yn;
logic  [7:0] c3_sy;
logic        c5_coll;
logic  [7:0] lx, ly, lacc, lpx, lpy;
logic  [8:0] lcnt;
logic  [6:0] c6_n;
logic  [7:0] f_cmd, f_ib, f_ir, f_r, f_x;

function automatic [7:0] linc(input [2:0] oct, input carry, input isy);
    case ({oct, carry, isy})
        5'b000_0_0: linc = 8'd1;   5'b000_0_1: linc = 8'd0;   5'b000_1_0: linc = 8'd1;   5'b000_1_1: linc = 8'hFF;
        5'b001_0_0: linc = 8'd0;   5'b001_0_1: linc = 8'hFF;  5'b001_1_0: linc = 8'd1;   5'b001_1_1: linc = 8'hFF;
        5'b010_0_0: linc = 8'd0;   5'b010_0_1: linc = 8'hFF;  5'b010_1_0: linc = 8'hFF;  5'b010_1_1: linc = 8'hFF;
        5'b011_0_0: linc = 8'hFF;  5'b011_0_1: linc = 8'd0;   5'b011_1_0: linc = 8'hFF;  5'b011_1_1: linc = 8'hFF;
        5'b100_0_0: linc = 8'hFF;  5'b100_0_1: linc = 8'd0;   5'b100_1_0: linc = 8'hFF;  5'b100_1_1: linc = 8'd1;
        5'b101_0_0: linc = 8'd0;   5'b101_0_1: linc = 8'd1;   5'b101_1_0: linc = 8'hFF;  5'b101_1_1: linc = 8'd1;
        5'b110_0_0: linc = 8'd0;   5'b110_0_1: linc = 8'd1;   5'b110_1_0: linc = 8'd1;   5'b110_1_1: linc = 8'd1;
        default:    linc = isy ? (carry ? 8'd1 : 8'd0) : 8'd1;
    endcase
endfunction

function automatic [1:0] first_plane(input [2:0] en);
    first_plane = en[0] ? 2'd1 : en[1] ? 2'd2 : 2'd0;
endfunction
function automatic [2:0] plane_bit(input [1:0] p);
    plane_bit = (p == 2'd1) ? 3'b001 : (p == 2'd2) ? 3'b010 : 3'b100;
endfunction
function automatic [7:0] plane_val(input [1:0] p, input [7:0] r, input [7:0] g, input [7:0] b);
    plane_val = (p == 2'd1) ? g : (p == 2'd2) ? b : r;
endfunction

wire [2:0]  cmd_en = {mcmd[6], mcmd[5], mcmd[4]};
wire [7:0]  sh_r   = pv >> pl_sh;
wire [15:0] sh_lw  = {8'd0, pv} << (4'd8 - {1'b0, pl_sh});
wire [7:0]  sh_l   = sh_lw[7:0];

wire [8:0]  c5_s    = {1'b0, lacc} + {1'b0, mi[15:8]};

wire [6:0]  c3_rows = 7'd64 - {1'b0, mr[4:0], 1'b0};
wire [3:0]  c3_cols = 4'd8 - {1'b0, mr[7:5]};
wire [11:0] st_c3   = 12'd3 + (12'd2 + {4'd0, c3_rows, 1'b0}) * {8'd0, c3_cols};
wire [11:0] st_c5   = 12'd3 + {2'd0, 9'd256 - {1'b0, mi[7:0]}, 1'b0};
wire [11:0] st_c6   = 12'd3 + {4'd0, c3_rows, 1'b0};

wire v_acc = ~z_mreq_n & (r_vwr | (r_vrd & (z_a[7:0] != 8'h04)));
assign z_wait_n = ~(v_acc & eng_run);

logic vw_done = 1'b0;
always_ff @(posedge clk) vw_done <= mreq_wr & (vw_done | (r_vwr & ~eng_run));
wire  vw_go = mreq_wr & r_vwr & ~eng_run & ~vw_done;

logic        busy_add_en = 1'b0;
logic [11:0] busy_add = 12'd0;

always_ff @(posedge clk) begin
    fg_a_we     <= 1'b0;
    busy_add_en <= 1'b0;
    if (busy_add_en)                  busy_cnt <= busy_cnt + {8'd0, busy_add, 4'd0};
    else if (busy_cnt != 0 && !pause) busy_cnt <= busy_cnt - 24'd1;

    if (reset) begin
        est <= E_IDLE; prog <= 1'b0; keep_going <= 1'b0;
        mi <= 16'd0; mpc <= 9'd0; mr <= 8'd0; mg <= 8'd0; mb <= 8'd0; mxp <= 8'd0; myp <= 8'd0; mcmd <= 8'd0;
        scrollx <= 8'd0; scrolly <= 8'd0; vctrl <= 8'd0; vblank_irq <= 1'b0; fgcoll <= 1'b0;
        fgcollx <= 8'd0; fgcolly <= 8'd0; busy_cnt <= 24'd0;
    end
    else begin
        if (vw_go) begin
            case (z_a[7:0])
                8'h00: mi[7:0] <= z_do;
                8'h01: begin mi[15:8] <= z_do; if (cmdlo == 3'd5) est <= E_DISPATCH; end
                8'h02: begin mcmd <= z_do; if (z_do[2:0] == 3'd6) est <= E_DISPATCH; end
                8'h03: mg <= z_do;
                8'h04: begin mxp <= z_do; if (cmdlo == 3'd3) est <= E_DISPATCH; end
                8'h05: begin myp <= z_do; if (cmdlo == 3'd4) est <= E_DISPATCH; end
                8'h06: mr <= z_do;
                8'h07: begin mb <= z_do; if (cmdlo == 3'd2 || cmdlo == 3'd7) est <= E_DISPATCH; end
                8'h08: scrollx <= z_do;
                8'h09: scrolly <= z_do;
                8'h0A: vctrl <= z_do;
                8'h0B: vblank_irq <= 1'b0;
                default: ;
            endcase
            prog <= 1'b0;
        end
        if (rd_end && rd_a[15:8] == 8'hC0 && rd_a[7:0] == 8'h01) fgcoll <= 1'b0;
        if (ce_pix && hcnt == 9'd0 && vcnt == 9'd256) vblank_irq <= 1'b1;

        case (est)
            E_IDLE: ;

            E_DISPATCH: begin
                pt <= 4'd0;
                case (cmdlo)
                    3'd2: begin busy_add <= 12'd3; busy_add_en <= 1'b1; pl_en <= cmd_en; est <= E_C2; end
                    3'd3: begin
                        busy_add <= st_c3; busy_add_en <= 1'b1;
                        c3_x <= c3_cols; c3_yn <= c3_rows; est <= E_C3_COL;
                    end
                    3'd4: begin
                        busy_add <= 12'd4; busy_add_en <= 1'b1;
                        mpc <= {myp, 1'b0}; prog <= 1'b1; keep_going <= 1'b0; est <= E_C4_FETCH;
                    end
                    3'd5: begin
                        busy_add <= st_c5; busy_add_en <= 1'b1;
                        lx <= mxp; ly <= myp; lacc <= 8'h80; lcnt <= 9'd256 - {1'b0, mi[7:0]};
                        c5_coll <= mcmd[3] & ~fgcoll;
                        est <= E_C5_PT;
                    end
                    3'd6: begin
                        busy_add <= st_c6; busy_add_en <= 1'b1;
                        mpc <= {myp, 1'b0}; c6_n <= c3_rows; est <= E_C6_BYTE;
                    end
                    3'd7: begin busy_add <= 12'd4; busy_add_en <= 1'b1; est <= E_C7; end
                    default: est <= E_NEXT;
                endcase
            end

            E_C2: begin
                if (pl_en == 3'b000) begin
                    mi <= mi + 16'd1; keep_going <= mcmd[7]; est <= E_NEXT;
                end
                else begin
                    fg_a_addr <= {1'b0, first_plane(pl_en), mi[13:0]};
                    fg_a_d    <= plane_val(first_plane(pl_en), mr, mg, mb);
                    fg_a_we   <= 1'b1;
                    pl_en     <= pl_en & ~plane_bit(first_plane(pl_en));
                end
            end

            E_C3_COL: begin
                if (c3_x == 4'd0) begin
                    keep_going <= mcmd[7]; est <= E_NEXT;
                end
                else begin
                    c3_y <= c3_yn; c3_sy <= myp; est <= E_C3_ROW;
                end
            end
            E_C3_ROW: begin
                if (c3_y == 7'd0) begin
                    c3_x <= c3_x - 4'd1; mxp <= mxp + 8'd8; est <= E_C3_COL;
                end
                else begin
                    pl_en   <= cmd_en;
                    pl_src  <= 1'b1;
                    pl_sa   <= mi[13:0];
                    pl_da   <= {1'b0, c3_sy, mxp[7:3]};
                    pl_sh   <= mxp[2:0];
                    pl_coll <= mcmd[3] & ~fgcoll;
                    pl_hit  <= 1'b0;
                    mi      <= mi + 16'd1;
                    c3_sy   <= c3_sy + 8'd1;
                    c3_y    <= c3_y - 7'd1;
                    pt      <= 4'd0;
                    ret_st  <= E_C3_ROW;
                    est     <= E_PLOT;
                end
            end

            E_C4_FETCH: begin
                pt <= pt + 4'd1;
                case (pt)
                    4'd0: fg_a_addr <= {3'b001, 14'h2000 | {5'd0, mpc}};
                    4'd1: fg_a_addr <= {3'b010, 14'h2000 | {5'd0, mpc}};
                    4'd2: begin fg_a_addr <= {3'b000, 14'h2000 | {5'd0, mpc}};
                                f_cmd <= fg_a_q; end
                    4'd3: begin fg_a_addr <= {3'b001, 14'h2001 + {5'd0, mpc}};
                                f_ib <= fg_a_q; end
                    4'd4: begin fg_a_addr <= {3'b000, 14'h2001 + {5'd0, mpc}};
                                f_ir <= fg_a_q; end
                    4'd5: begin fg_a_addr <= {3'b010, 14'h2001 + {5'd0, mpc}};
                                f_r <= fg_a_q; end
                    4'd6: f_x <= fg_a_q;
                    default: begin
                        mcmd <= f_cmd; mi <= {f_ib, f_ir}; mr <= f_r; mxp <= f_x; myp <= fg_a_q;
                        pt   <= 4'd0;
                        if (f_cmd[2:0] == 3'd4) begin mpc <= {fg_a_q, 1'b0}; keep_going <= 1'b1; end
                        else begin mpc <= mpc + 9'd2; est <= E_DISPATCH; end
                    end
                endcase
            end

            E_C5_PT: begin
                if (lcnt == 9'd0) begin
                    mxp <= lx; keep_going <= mcmd[7]; est <= E_NEXT;
                end
                else begin
                    pl_en   <= 3'b111;
                    pl_src  <= 1'b0;
                    pl_da   <= {1'b0, ly, lx[7:3]};
                    pl_sh   <= lx[2:0];
                    pl_coll <= c5_coll;
                    pl_hit  <= 1'b0;
                    lpx     <= lx;
                    lpy     <= ly;
                    lx      <= lx + linc(mcmd[6:4], c5_s[8], 1'b0);
                    ly      <= ly + linc(mcmd[6:4], c5_s[8], 1'b1);
                    lacc    <= c5_s[7:0];
                    lcnt    <= lcnt - 9'd1;
                    pt      <= 4'd0;
                    ret_st  <= E_C5_PT;
                    est     <= E_PLOT;
                end
            end

            E_C6_BYTE: begin
                if (c6_n == 7'd0) begin
                    keep_going <= mcmd[7]; est <= E_NEXT;
                end
                else begin
                    pl_en <= cmd_en;
                    pl_sa <= mi[13:0];
                    pl_da <= 14'h2000 | {5'd0, mpc};
                    mi    <= mi + 16'd1;
                    mpc   <= mpc + 9'd1;
                    c6_n  <= c6_n - 7'd1;
                    pt    <= 4'd0;
                    est   <= E_COPY;
                end
            end

            E_C7: begin
                pl_en      <= cmd_en;
                pl_src     <= 1'b0;
                pl_da      <= {1'b0, myp, mxp[7:3]};
                pl_sh      <= mxp[2:0];
                pl_coll    <= mcmd[3] & ~fgcoll;
                pl_hit     <= 1'b0;
                pt         <= 4'd0;
                ret_st     <= E_NEXT;
                keep_going <= mcmd[7];
                est        <= E_PLOT;
            end

            E_PLOT: begin
                if (pl_en == 3'b000) begin
                    if (pl_hit) begin
                        fgcoll <= 1'b1;
                        case (ret_st)
                            E_C3_ROW: begin fgcollx <= mxp;        fgcolly <= c3_sy - 8'd1; end
                            E_C5_PT:  begin fgcollx <= lpx;        fgcolly <= lpy; end
                            default:  begin fgcollx <= mxp + 8'd8; fgcolly <= myp; end
                        endcase
                    end
                    est <= ret_st;
                end
                else begin
                    pt <= pt + 4'd1;
                    case (pt)
                        4'd0: begin pl_cur <= first_plane(pl_en); fg_a_addr <= {1'b0, first_plane(pl_en), pl_sa}; end
                        4'd1: fg_a_addr <= {1'b0, pl_cur, pl_da};
                        4'd2: begin
                            fg_a_addr <= {1'b0, pl_cur, pl_da + 14'd1};
                            pv <= pl_src ? fg_a_q : plane_val(pl_cur, mr, mg, mb);
                        end
                        4'd3: d0 <= fg_a_q;
                        4'd4: d1 <= fg_a_q;
                        4'd5: begin
                            fg_a_addr <= {1'b0, pl_cur, pl_da}; fg_a_d <= d0 ^ sh_r; fg_a_we <= 1'b1;
                            if (pl_coll && ((d0 & sh_r) != 8'd0 || (d1 & sh_l) != 8'd0)) pl_hit <= 1'b1;
                        end
                        4'd6: begin fg_a_addr <= {1'b0, pl_cur, pl_da + 14'd1}; fg_a_d <= d1 ^ sh_l; fg_a_we <= 1'b1; end
                        default: begin pl_en <= pl_en & ~plane_bit(pl_cur); pt <= 4'd0; end
                    endcase
                end
            end

            E_COPY: begin
                if (pl_en == 3'b000) est <= E_C6_BYTE;
                else begin
                    pt <= pt + 4'd1;
                    case (pt)
                        4'd0: begin pl_cur <= first_plane(pl_en); fg_a_addr <= {1'b0, first_plane(pl_en), pl_sa}; end
                        4'd1: ;
                        4'd2: begin fg_a_addr <= {1'b0, pl_cur, pl_da}; fg_a_d <= fg_a_q; fg_a_we <= 1'b1; end
                        default: begin pl_en <= pl_en & ~plane_bit(pl_cur); pt <= 4'd0; end
                    endcase
                end
            end

            E_NEXT: begin
                pt <= 4'd0;
                if (prog && keep_going) est <= E_C4_FETCH;
                else begin prog <= 1'b0; est <= E_IDLE; end
            end

            default: est <= E_IDLE;
        endcase
    end
end

wire [8:0] t_h   = hcnt + 9'd9;
wire       t_nxt = t_h >= 9'd320;
wire [8:0] v_nxt = (vcnt == V_TOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
wire [7:0] t_y   = t_nxt ? v_nxt[7:0] : vcnt[7:0];
wire [7:0] t_bx  = t_h[7:0] + scrollx - (t_nxt ? 8'd80 : 8'd0);
wire [7:0] t_by  = t_y + scrolly;
wire [7:0] t_fx  = t_h[7:0] - (t_nxt ? 8'd80 : 8'd0);
wire       fg_bd = ce_pix && hcnt[2:0] == 3'd7;
wire [7:0] hsx   = hcnt[7:0] + scrollx;
wire       bg_bd = ce_pix && hsx[2:0] == 3'd7;

logic [7:0] fr_sr, fg_sr, fb_sr, fr_nx, fg_nx, fb_nx;
logic [7:0] c2_sr, c1_sr, c0_sr, c2_nx, c1_nx, c0_nx;
logic [3:0] ff = 4'd15, bf = 4'd15;
logic [7:0] f_line, b_code;
logic [4:0] f_grp;
logic [2:0] b_row;

always_ff @(posedge clk) begin
    if (fg_bd) begin f_line <= t_y; f_grp <= t_fx[7:3]; ff <= 4'd0; end
    else if (ff != 4'd15) ff <= ff + 4'd1;
    case (ff)
        4'd0: fg_b_addr <= {3'b000, 1'b0, f_line, f_grp};
        4'd1: fg_b_addr <= {3'b001, 1'b0, f_line, f_grp};
        4'd2: begin fg_b_addr <= {3'b010, 1'b0, f_line, f_grp}; fr_nx <= fg_b_q; end
        4'd3: fg_nx <= fg_b_q;
        4'd4: begin fb_nx <= fg_b_q; ff <= 4'd15; end
        default: ;
    endcase

    if (bg_bd) begin tile_sa <= {t_by[7:3], t_bx[7:3]}; b_row <= t_by[2:0]; bf <= 4'd0; end
    else if (bf != 4'd15) bf <= bf + 4'd1;
    case (bf)
        4'd1: begin b_code <= tile_sq; char_sa <= {2'd0, tile_sq, b_row}; end
        4'd2: char_sa <= {2'd1, b_code, b_row};
        4'd3: begin char_sa <= {2'd2, b_code, b_row}; c2_nx <= char_sq; end
        4'd4: c1_nx <= char_sq;
        4'd5: begin c0_nx <= char_sq; bf <= 4'd15; end
        default: ;
    endcase
end

wire [2:0] fpix = {fr_sr[7], fb_sr[7], fg_sr[7]};
wire [2:0] bpix = {c2_sr[7], c1_sr[7], c0_sr[7]};
wire [2:0] bmask = vctrl[2] ? 3'b100 : 3'b111;
wire       vis  = (hcnt < 9'd256) && (vcnt < 9'd256);

always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (fg_bd) begin fr_sr <= fr_nx; fg_sr <= fg_nx; fb_sr <= fb_nx; end
        else       begin fr_sr <= fr_sr << 1; fg_sr <= fg_sr << 1; fb_sr <= fb_sr << 1; end
        if (bg_bd) begin c2_sr <= c2_nx; c1_sr <= c1_nx; c0_sr <= c0_nx; end
        else       begin c2_sr <= c2_sr << 1; c1_sr <= c1_sr << 1; c0_sr <= c0_sr << 1; end

        pix_x   <= hcnt;
        pix_y   <= vcnt;
        pix_pen <= vis ? {fpix, bpix} : 6'd0;
        pix_rgb <= vis ? pen_rgb(pal[{fpix, bpix}]) : 9'd0;
    end
end

always_ff @(posedge clk) begin
    if (reset) begin bgcoll <= 1'b0; bgcoll_cnt <= 8'd0; end
    else begin
        if (ce_pix && hcnt == 9'd0 && vcnt == 9'd256) bgcoll_cnt <= 8'd0;
        else if (ce_pix && vis && fpix != 3'd0 && (bpix & bmask) != 3'd0 && !bgcoll_cnt[7]) begin
            bgcoll <= 1'b1; bgcollx <= hcnt[7:0]; bgcolly <= vcnt[7:0]; bgcoll_cnt <= bgcoll_cnt + 8'd1;
        end
        if (rd_end && rd_a[15:8] == 8'hC0 && rd_a[7:0] == 8'h03) bgcoll <= 1'b0;
    end
end

logic [7:0] vstat, io_q;
always_comb begin
    case (z_a[7:0])
        8'h00:   vstat = fgcollx;
        8'h01:   vstat = fgcolly;
        8'h02:   vstat = bgcollx & 8'hFC;
        8'h03:   vstat = bgcolly;
        8'h04:   vstat = {busy_cnt != 24'd0, ~fgcoll, ~vblank_irq, ~bgcoll, vcnt[8], 3'b000};
        default: vstat = 8'h00;
    endcase
    io_q = 8'hFF;
    if      (z_a[7:2] == 6'd0) io_q = dsw;
    else if (z_a[7:2] == 6'd1) io_q = 8'hFF;
    else if (z_a[7:3] == 5'd1) io_q = z_a[0] ? 8'h00 :
                                      z_a[2] ? (z_a[1] ? 8'hFF : buttons) : (z_a[1] ? coin : dial);
end

always_comb begin
    z_di = 8'hFF;
    if      (int_ack) z_di = 8'hFF;
    else if (io_rd)   z_di = io_q;
    else if (r_rom)   z_di = rom_d;
    else if (r_vrd)   z_di = vstat;
    else if (r_tile)  z_di = tile_q;
    else if (r_char)  z_di = char_q;
    else if (r_ram)   z_di = ram_q;
    else if (r_snd)   z_di = z_a[0] ? {snd_status, 6'd0} : snd_resp;
end

assign snd_wr = wr_go & r_snd & ~z_a[0];
assign snd_rd = rd_end & (rd_a[15:11] == 5'b11111) & ~rd_a[1] & ~rd_a[0];

endmodule

//============================================================================
//
//  Exidy Star Fire / Fire One logic board
//  Copyright (C) 2026 Rodimus
//
//  From MAME starfire.cpp / starfire_v.cpp (schematic facts: Claude/exidy_schematic_facts.md, Star Fire section):
//    20 MHz master: Z80 = / 8 (2.5 MHz), pixel = / 4 (5 MHz). Here both come from the 22.578 MHz system clock
//    through a fractional enable (exact average, pixels 4 or 5 clocks long).
//    Bitmap: 32 columns x 256 lines of 8-pixel bytes (video RAM offset = column * 256 + line), a colour RAM of the
//    same shape (5-bit colour per byte) and a 64-entry 3-3-3 palette loaded through colour RAM lines 0-31.
//    CPU writes to C000-FFFF go through mirror / shifter / 16-function ALU into two adjacent columns at once;
//    8000-9FFF is scratch RAM mapped into video RAM lines 0-31, with the control registers and inputs at 9xxx.
//    The two-column read-modify-write is two parallel BRAM accesses: video and colour RAM are split into
//    even-column and odd-column banks.
//
//  ioctl: program ROM through exidy_board's rom_main (Z80 0000-7FFF).
//
//============================================================================

module starfire_main
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,
    input  logic        pause,          // OSD pause: no NMIs pile up while the Z80 is frozen
    input  logic        fireone,

    output logic        ce_pix,         // 5 MHz average
    output logic        cen_p,          // Z80 2.5 MHz, rising / falling half
    output logic        cen_n,

    // Z80 (exidy_board's pooled T80pa)
    input  logic [15:0] z_a,
    input  logic  [7:0] z_do,
    input  logic        z_mreq_n,
    input  logic        z_rd_n,
    input  logic        z_wr_n,
    output logic  [7:0] z_di,
    output logic        z_nmi_n,

    input  logic  [7:0] rom_d,          // rom_main, addressed by z_a[14:0] in exidy_board

    // inputs (9800-9807)
    input  logic  [7:0] dsw,
    input  logic  [7:0] sys_in,         // SYSTEM
    input  logic  [7:0] p1_in,          // Fire One P1 / P2 buttons (bits 7:6)
    input  logic  [7:0] p2_in,
    input  logic  [7:0] stick_x,        // Star Fire A/D
    input  logic  [7:0] stick_y,
    input  logic  [7:0] throttle,
    input  logic  [5:0] pad1,           // Fire One paddles 0-63
    input  logic  [5:0] pad2,
    input  logic        tie_on_n,       // Star Fire audio status (input port 1 bits 3 / 4)
    input  logic        laser_on_n,
    input  logic        player_sel,     // Fire One control multiplexer

    // sound board strobes (data = z_do)
    output logic        snd_wr,
    output logic        snd_a0,
    output logic        music_wr,
    output logic  [1:0] music_a,

    output logic  [8:0] pix_x,
    output logic  [8:0] pix_y,
    output logic  [8:0] pix_rgb,        // {R3, G3, B3}
    output logic  [5:0] pix_pen,        // palette index (CRT Flip frame buffer)
    input  logic  [5:0] pal_ri,         // second palette read port (CRT Flip readout)
    output logic  [8:0] pal_rq,
    output logic        vbl_raw,

    // hiscore.v access to scratch RAM 8000-9FFF (only while it holds the CPU paused)
    input  logic [15:0] hs_a,
    input  logic  [7:0] hs_din,
    output logic  [7:0] hs_dout,
    input  logic        hs_we
);

localparam [8:0] H_TOTAL = 9'd320;      // schematic: 256 + 64 (HR) = 0x140 (MAME 0x13F)
localparam [8:0] V_TOTAL = 9'd262;      // MAME; the schematic carry logic derives 260 #unverified
localparam [8:0] V_START = 9'd32;       // visible lines 32-255

/////////////////////////////  Clock enables  /////////////////////////////

logic [14:0] acc = 15'd0;               // 5000 / 22578 of the clocks
logic  [1:0] pause_dl = 2'd0;            // CPU resumes 2 clocks after pause: port A is back on its address
always_ff @(posedge clk) pause_dl <= {pause_dl[0], pause};
wire         pause_d = |pause_dl;
wire  [15:0] acc_n = {1'b0, acc} + 16'd5000;
logic        cpu_ph = 1'b0;
always_ff @(posedge clk) begin
    ce_pix <= 1'b0;
    cen_p  <= 1'b0;
    cen_n  <= 1'b0;
    if (acc_n >= 16'd22578) begin
        acc    <= acc_n[14:0] - 15'd22578;
        ce_pix <= 1'b1;
        // pause holds the phase too: the T80pa must always see CEN_p / CEN_n alternate, or it crashes on resume
        if (!pause && !pause_d) begin
            cpu_ph <= ~cpu_ph;
            cen_p  <=  cpu_ph;
            cen_n  <= ~cpu_ph;
        end
    end
    else acc <= acc_n[14:0];
end

/////////////////////////////  Raster  /////////////////////////////

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
wire vis = (hcnt < 9'd256) && (vcnt >= V_START) && (vcnt < 9'd256);

// NMI once per frame at the start of vblank (MAME vblank_int; Star Fire's J6 jumper fitted)
logic [5:0] nmi_cnt = 6'd0;
always_ff @(posedge clk) begin
    if (ce_pix && hcnt == 9'd0 && vcnt == 9'd256 && !pause) nmi_cnt <= 6'd63;
    else if (cen_p && nmi_cnt != 6'd0)                        nmi_cnt <= nmi_cnt - 6'd1;
end
assign z_nmi_n = (nmi_cnt == 6'd0);
assign vbl_raw = (vcnt >= 9'd256) || (vcnt < V_START);

/////////////////////////////  Control registers  /////////////////////////////

logic [7:0] vidctrl = 8'd0, vidctrl1 = 8'd0;    // 9000 shift / mirror, 9001 video control
logic [4:0] color = 5'd0;                        // colour latch
wire        cdrm  = vidctrl1[7];                 // colour RAM source = colour latch
wire        trans = vidctrl1[6];                 // palette write enable
wire        vwe   = vidctrl1[5];                 // video RAM write enable for lines 0-31 (PROT)
wire        rsel  = vidctrl1[4];                 // ROLL: right-side mask select
wire  [3:0] aluop = ~vidctrl1[3:0];

/////////////////////////////  CPU decode  /////////////////////////////

wire mreq_rd = ~z_mreq_n & ~z_rd_n;
wire mreq_wr = ~z_mreq_n & ~z_wr_n;
logic wr_d = 1'b0, rd_d = 1'b0;
always_ff @(posedge clk) begin wr_d <= mreq_wr; rd_d <= mreq_rd; end
wire wr_go = mreq_wr & ~wr_d;           // one clock at the start of each write
wire rd_go = mreq_rd & ~rd_d;

wire r_rom     = ~z_a[15];
wire r_scratch = (z_a[15:13] == 3'b100);         // 8000-9FFF
wire r_color   = (z_a[15:13] == 3'b101);         // A000-BFFF
wire r_vram    = (z_a[15:14] == 2'b11);          // C000-FFFF
wire r_input   = r_scratch & z_a[11];            // reads 9800-9FFF (A11)

// column / line of the access: scratch RAM converts A[12:0] into lines 0-31
wire [4:0] a_col = r_scratch ? {z_a[7:5], z_a[9:8]} : z_a[12:8];
wire [7:0] a_y   = r_scratch ? {3'b000, z_a[4:0]}   : z_a[7:0];
wire       a_low = (a_y[7:5] == 3'b000);         // lines 0-31 (palette / scratch / PROT)
wire [4:0] a_col2 = a_col + 5'd1;                // second column of a C000-FFFF access

/////////////////////////////  Video / colour RAM banks  /////////////////////////////

// even-column and odd-column banks, address {column[4:1], line}
logic [11:0] ve_a, vo_a, ce_a, co_a;
logic  [7:0] ve_d, vo_d, ce_d, co_d;
logic        ve_w, vo_w, ce_w, co_w;
logic  [7:0] ve_q, vo_q, ce_q, co_q;
logic [11:0] scan_a;
logic  [7:0] ve_s, vo_s, ce_s, co_s;

// hiscore: scratch address -> bank / port A address as for the CPU; it owns port A only while the CPU is paused
// and no CPU write is in flight (st 1 / 2 and ve_w / vo_w finish a CPU cycle); MRA PAUSEPAD covers the takeover
wire [4:0]  hs_col = {hs_a[7:5], hs_a[9:8]};
wire [11:0] hs_ra  = {hs_col[4:1], 3'b000, hs_a[4:0]};
logic [1:0] st = 2'd0;                  // CPU access sequencer: 0 idle, 1 read banks, 2 write back
wire        hs_on  = pause && pause_dl[1] && (st == 2'd0 || st == 2'd3) && !ve_w && !vo_w;
wire        hs_wr  = hs_on && hs_we && (hs_a[15:13] == 3'b100);
logic       hs_odd = 1'b0;
always_ff @(posedge clk) hs_odd <= hs_col[0];
assign hs_dout = hs_odd ? vo_q : ve_q;

dpram_dc #(.widthad_a(12)) vram_e (.clock_a(clk), .address_a(hs_on ? hs_ra : ve_a), .data_a(hs_on ? hs_din : ve_d),
                                   .wren_a(hs_on ? hs_wr & ~hs_col[0] : ve_w), .q_a(ve_q),
                                   .clock_b(clk), .address_b(scan_a), .data_b(8'd0), .wren_b(1'b0), .q_b(ve_s));
dpram_dc #(.widthad_a(12)) vram_o (.clock_a(clk), .address_a(hs_on ? hs_ra : vo_a), .data_a(hs_on ? hs_din : vo_d),
                                   .wren_a(hs_on ? hs_wr & hs_col[0] : vo_w), .q_a(vo_q),
                                   .clock_b(clk), .address_b(scan_a), .data_b(8'd0), .wren_b(1'b0), .q_b(vo_s));
dpram_dc #(.widthad_a(12)) cram_e (.clock_a(clk), .address_a(ce_a), .data_a(ce_d), .wren_a(ce_w), .q_a(ce_q),
                                   .clock_b(clk), .address_b(scan_a), .data_b(8'd0), .wren_b(1'b0), .q_b(ce_s));
dpram_dc #(.widthad_a(12)) cram_o (.clock_a(clk), .address_a(co_a), .data_a(co_d), .wren_a(co_w), .q_a(co_q),
                                   .clock_b(clk), .address_b(scan_a), .data_b(8'd0), .wren_b(1'b0), .q_b(co_s));

/////////////////////////////  Shifter / mask (MAME videoram_w / videoram_r)  /////////////////////////////

wire        sel2 = z_a[13];                                  // E000-FFFF uses shift / mirror set 2
wire  [2:0] sh   = sel2 ? vidctrl[3:1] : vidctrl[7:5];
wire        lr   = sel2 ? vidctrl[0]   : vidctrl[4];
wire  [7:0] dm   = lr ? {z_do[0], z_do[1], z_do[2], z_do[3], z_do[4], z_do[5], z_do[6], z_do[7]} : z_do;
wire [15:0] ds_f = {dm, 8'd0} >> sh;
wire [15:0] mk_f = 16'hFF00 >> sh;
wire [15:0] mask = (a_col == 5'd31) ? (mk_f & (rsel ? 16'h00FF : 16'hFF00)) : mk_f;   // ROLL at column 31

// first column = offset1, second = offset2 (column + 1)
wire  [7:0] d1 = a_col[0] ? vo_q : ve_q;
wire  [7:0] d2 = a_col[0] ? ve_q : vo_q;
wire [15:0] d0f = {d1, d2};
wire [15:0] dsm = ds_f & mask;
wire [15:0] d0m = d0f & mask;
logic [15:0] fn;
always_comb begin
    case (aluop)
        4'd0:  fn = dsm ^ mask;
        4'd1:  fn = (dsm | d0m) ^ mask;
        4'd2:  fn = (dsm ^ mask) & d0m;
        4'd3:  fn = 16'd0;
        4'd4:  fn = (dsm & d0m) ^ mask;
        4'd5:  fn = d0m ^ mask;
        4'd6:  fn = dsm ^ d0m;
        4'd7:  fn = dsm & (d0m ^ mask);
        4'd8:  fn = (dsm ^ mask) | d0m;
        4'd9:  fn = (dsm ^ d0m) ^ mask;
        4'd10: fn = d0m;
        4'd11: fn = dsm & d0m;
        4'd12: fn = mask;
        4'd13: fn = dsm | (d0m ^ mask);
        4'd14: fn = dsm | d0m;
        default: fn = dsm;
    endcase
end
wire [15:0] dalu = (d0f & ~mask) | (fn & mask);

// CPU read of C000-FFFF: masked pair rotated left by the shift
wire  [7:0] rd_m  = (d1 & mask[15:8]) | (d2 & mask[7:0]);
wire [15:0] rd_r2 = {rd_m, rd_m} << sh;
wire  [7:0] rd_rot = rd_r2[15:8];

/////////////////////////////  Colour RAM pseudo-palette (MAME colorram_w / colorram_r)  /////////////////////////////

wire [4:0] cl_w = cdrm ? color : z_do[4:0];
wire [4:0] cr_w = {cdrm ? color[4] : z_do[4], z_a[8], z_do[7:5]};
wire [5:0] pal_i = {z_a[9], a_y[4:0]};
logic [8:0] pal [64];
initial for (int i = 0; i < 64; i++) pal[i] = 9'd0;

/////////////////////////////  CPU access sequencer  /////////////////////////////


// Port A addresses follow the CPU address; a C000-FFFF access reads both columns, the colour palette region
// (A000-BFFF lines 0-31) reads the even / odd pair of the same column pair.
wire [3:0] colh  = a_col[4:1];
wire [3:0] colh2 = a_col2[4:1];
wire       cpair = r_color & a_low;
always_comb begin
    ve_a = {(a_col[0] && !r_scratch) ? colh2 : colh, a_y};
    vo_a = {colh, a_y};
    ce_a = {(a_col[0] && !cpair && r_vram) ? colh2 : colh, a_y};
    co_a = {colh, a_y};
end

always_ff @(posedge clk) begin
    ve_w <= 1'b0; vo_w <= 1'b0; ce_w <= 1'b0; co_w <= 1'b0;
    snd_wr <= 1'b0; music_wr <= 1'b0;
    if (reset) begin
        st <= 2'd0; vidctrl <= 8'd0; vidctrl1 <= 8'd0; color <= 5'd0;
    end
    else begin
        case (st)
            2'd0: if (wr_go) begin
                if (r_scratch) begin
                    // scratch RAM write (no ALU) + control registers at A12 = 1, A3 = 0
                    if (a_col[0]) begin vo_d <= z_do; vo_w <= 1'b1; end
                    else          begin ve_d <= z_do; ve_w <= 1'b1; end
                    if (z_a[12] && !z_a[3]) begin
                        case (z_a[2:0])
                            3'd0: vidctrl  <= z_do;
                            3'd1: vidctrl1 <= z_do;
                            3'd2, 3'd3: begin snd_wr <= 1'b1; snd_a0 <= z_a[0]; end
                            3'd7: begin music_wr <= 1'b1; music_a <= z_a[11:10]; end
                            default: ;
                        endcase
                    end
                end
                else if (r_color) begin
                    if (a_low) begin
                        ce_d <= {3'b000, cl_w}; ce_w <= 1'b1;
                        co_d <= {3'b000, cr_w}; co_w <= 1'b1;
                        color <= cl_w;
                        if (trans) pal[pal_i] <= {cl_w[1:0], cr_w[3:0], cl_w[4:2]};
                    end
                    else begin
                        if (a_col[0]) begin co_d <= {3'b000, cl_w}; co_w <= 1'b1; end
                        else          begin ce_d <= {3'b000, cl_w}; ce_w <= 1'b1; end
                        color <= cl_w;
                    end
                end
                else if (r_vram && !(a_low && !vwe)) st <= 2'd1;   // PROT: lines 0-31 need VWE
            end
            else if (rd_go && cpair && trans) st <= 2'd2;            // colour reads in the palette region refresh it

            2'd1: begin                                             // banks hold both columns: ALU and write back
                if (a_col[0]) begin vo_d <= dalu[15:8]; ve_d <= dalu[7:0]; end
                else          begin ve_d <= dalu[15:8]; vo_d <= dalu[7:0]; end
                ve_w <= 1'b1; vo_w <= 1'b1;
                if (!sel2 && !cdrm) begin                           // colour follows the written columns
                    if (a_col[0]) begin co_d <= {3'b000, color}; co_w <= |mask[15:8]; ce_d <= {3'b000, color}; ce_w <= |mask[7:0]; end
                    else          begin ce_d <= {3'b000, color}; ce_w <= |mask[15:8]; co_d <= {3'b000, color}; co_w <= |mask[7:0]; end
                end
                st <= 2'd3;
            end

            2'd2: begin
                pal[pal_i] <= {ce_q[1:0], co_q[3:0], ce_q[4:2]};
                st <= 2'd3;
            end

            default: if (!mreq_wr && !mreq_rd) st <= 2'd0;          // wait for the bus cycle to end
        endcase
    end
end

/////////////////////////////  CPU read mux  /////////////////////////////

logic [7:0] in_q;
always_comb begin
    in_q = 8'hFF;
    case (z_a[3:0])
        4'd0: in_q = dsw;
        4'd1: in_q = fireone ? sys_in : {sys_in[7:5], laser_on_n, tie_on_n, sys_in[2:0]};
        4'd2: if (fireone) begin
                  in_q = player_sel ? {p2_in[7:6], pad2} : {p1_in[7:6], pad1};
                  in_q[5:0] = in_q[5:0] ^ {1'b0, in_q[5:1]};            // paddle is a 6-bit Gray code
              end
        4'd5: if (!fireone) in_q = throttle;
        4'd6: if (!fireone) in_q = stick_x;
        4'd7: if (!fireone) in_q = stick_y;
        default: ;
    endcase
end

always_comb begin
    z_di = 8'hFF;
    if      (r_rom)     z_di = rom_d;
    else if (r_input)   z_di = in_q;
    else if (r_scratch) z_di = a_col[0] ? vo_q : ve_q;
    else if (r_color)   z_di = cpair ? {co_q[2:0], ce_q[4:0]} : (a_col[0] ? co_q : ce_q);
    else if (r_vram)    z_di = rd_rot;
end

/////////////////////////////  Scan out  /////////////////////////////

// fetch the next column's byte and colour two pixels ahead (the end-of-line fetch is column 0 of the next line),
// latch it two clocks later (address register, then BRAM output), load it at the end of each 8-pixel group
wire [4:0] next_col  = (hcnt == H_TOTAL - 9'd3) ? 5'd0 : hcnt[7:3] + 5'd1;
wire [7:0] next_line = (hcnt == H_TOTAL - 9'd3) ? ((vcnt == V_TOTAL - 9'd1) ? 8'd0 : vcnt[7:0] + 8'd1) : vcnt[7:0];
logic [4:0] fcol;
logic [7:0] fline;
logic [7:0] sr, pend_v;
logic [4:0] cur_c, pend_c;
logic       fetch_d, fetch_d2;
assign scan_a = {fcol[4:1], fline};
always_ff @(posedge clk) begin
    fetch_d  <= 1'b0;
    fetch_d2 <= fetch_d;
    if (ce_pix && hcnt[2:0] == 3'd5) begin fcol <= next_col; fline <= next_line; fetch_d <= 1'b1; end
    if (fetch_d2) begin
        pend_v <= fcol[0] ? vo_s : ve_s;
        pend_c <= fcol[0] ? co_s[4:0] : ce_s[4:0];
    end
    if (ce_pix) begin
        if (hcnt[2:0] == 3'd7) begin sr <= pend_v; cur_c <= pend_c; end
        else sr <= {sr[6:0], 1'b0};
    end
end

always_ff @(posedge clk) begin
    if (ce_pix) begin
        pix_x   <= hcnt;
        pix_y   <= vcnt;
        pix_rgb <= vis ? pal[{sr[7], cur_c}] : 9'd0;
        pix_pen <= vis ? {sr[7], cur_c} : 6'd0;
    end
end

assign pal_rq = pal[pal_ri];

endmodule

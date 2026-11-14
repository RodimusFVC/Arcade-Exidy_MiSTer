//  Based on MAME circus.cpp (Mike Coates, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module circus_main
(
    input  logic        clk,
    input  logic        reset,
    input  logic  [1:0] ph,
    input  logic        ce_pix,
    input  logic  [7:0] cfg,

    input  logic        cpu_ce,
    input  logic [15:0] cpu_a,
    input  logic  [7:0] cpu_do,
    input  logic        cpu_rw,
    output logic  [7:0] cpu_di,
    output logic        cpu_irq_n,

    input  logic  [7:0] rom_d,          // program PROMs (exidy_dispatcher), 1000-1FFF / E000-FFFF = cpu_a[11:0]
    output logic [10:0] spr_a,
    input  logic  [7:0] spr_d,

    input  logic  [7:0] in0,
    input  logic  [7:0] dsw,
    input  logic  [7:0] paddle,

    output logic  [7:0] out_latch,      // 8000: [7] /GAME (mute), [6:4] sound code, [3:0] object image
    output logic        out_wr,

    output logic  [8:0] pix_x,
    output logic  [8:0] pix_y,
    output logic  [2:0] pix_rgb,
    output logic        vbl_irq_raw,

    input  logic  [9:0] hs_a,
    input  logic  [7:0] hs_din,
    output logic  [7:0] hs_dout,
    input  logic        hs_we,

    output logic [10:0] chr_rom_a,
    input  logic  [7:0] chr_rom_q,
    output logic  [9:0] lp_rom_a,
    input  logic  [7:0] lp_rom_q,

    output ram_pool_pkg::pram_i_t [5:0] pr_i,
    input  ram_pool_pkg::pram_o_t [5:0] pr_o
);

localparam [8:0] H_TOTAL = 9'd336;
localparam [8:0] V_TOTAL = 9'd280;
localparam [8:0] H_VCNT  = 9'h13C;

logic [8:0] hcnt = 9'd0, vcnt = 9'd0;
always_ff @(posedge clk) begin
    if (ce_pix) begin
        hcnt <= (hcnt == H_TOTAL - 9'd1) ? 9'd0 : hcnt + 9'd1;
        if (hcnt == H_VCNT) vcnt <= (vcnt == V_TOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
    end
end

wire h_vis = (hcnt < 9'd256);
wire v_vis = (vcnt < 9'd256);
wire vis   = h_vis & v_vis;
wire load  = h_vis && (hcnt[2:0] == 3'd7);

wire sel_ram  = (cpu_a[15:12] == 4'h0);
wire sel_rom  = (cpu_a[15:12] == 4'h1) | (cpu_a[15:13] == 3'b111);
wire sel_pos  = (cpu_a[15:13] == 3'b001);
wire sel_vram = (cpu_a[15:13] == 3'b010);
wire sel_out  = (cpu_a[15:13] == 3'b100);
wire sel_in   = (cpu_a[15:13] == 3'b101);
wire sel_dsw  = (cpu_a[15:12] == 4'hC);
wire sel_pad  = (cpu_a[15:12] == 4'hD);

wire wr = cpu_ce & ~cpu_rw;

// work RAM powers up with a pattern: Trapeze locks up when 0E / 0F are both 0
logic [8:0] init_a = 9'd0;
logic       init_run = 1'b1;
always_ff @(posedge clk) begin
    if (init_run) begin
        init_a <= init_a + 9'd1;
        if (init_a == 9'h1FF) init_run <= 1'b0;
    end
end

logic [7:0] ram_q, vram_q_cpu, vram_q, chr_q, lp_q;
dpram_dc #(.widthad_a(9)) work_ram  // POOL-EXCEPTION: power-on fill runs before the variant byte is known (a pool block would fill every board's RAM)
(
    .clock_a(clk), .address_a(init_run ? init_a : cpu_a[8:0]), .data_a(init_run ? {init_a[0], init_a[0], init_a[0], init_a[0], 4'h0} : cpu_do),
    .wren_a(init_run | (wr & sel_ram)), .q_a(ram_q),
    .clock_b(clk), .address_b(hs_a[8:0]), .data_b(hs_din), .wren_b(hs_we), .q_b(hs_dout)
);

logic [9:0] vram_va;
assign pr_i[0] = '0;
assign pr_i[1] = '0;
assign pr_i[2] = '0;
assign pr_i[3] = '0;
assign pr_i[4] = '0;
assign pr_i[5].a_addr = {6'd0, cpu_a[9:0]};
assign pr_i[5].a_d    = cpu_do;
assign pr_i[5].a_we   = wr & sel_vram;
assign pr_i[5].b_addr = {6'd0, vram_va};
assign pr_i[5].b_d    = 8'd0;
assign pr_i[5].b_we   = 1'b0;
assign {vram_q_cpu, vram_q} = {pr_o[5].a_q, pr_o[5].b_q};

logic [10:0] chr_a;
logic [9:0] lp_a;
assign chr_rom_a = chr_a;
assign chr_q     = chr_rom_q;
assign lp_rom_a  = lp_a;
assign lp_q      = lp_rom_q;

logic [7:0] sh = 8'd0, sv = 8'd0;
always_ff @(posedge clk) begin
    if (reset) out_latch <= 8'h00;
    else if (wr & sel_out) out_latch <= cpu_do;

    if (wr & sel_pos & cpu_a[12])        sh <= cpu_do;
    else if (ce_pix && vis)              sh <= sh + 8'd1;
    if (wr & sel_pos & ~cpu_a[12])       sv <= cpu_do;
    else if (ce_pix && hcnt == H_TOTAL - 9'd1 && v_vis) sv <= sv + 8'd1;
end
assign out_wr = wr & sel_out;

assign vram_va = {vcnt[7:3], hcnt[7:3]};
assign chr_a   = {vram_q, vcnt[2:0]};
assign lp_a    = {vcnt[7:3], hcnt[7:3]};
assign spr_a   = cfg[5] ? {6'd0, sh[3], sv[3:0]} : {2'b00, out_latch[3:0], sh[3], sv[3:0]};

logic [7:0] csr = 8'd0, ssr = 8'd0;
logic [3:0] lbits;
wire        swin  = (sv[7:4] == 4'hF);
wire        sload = ((sh | 8'h08) == 8'hFF);
wire  [7:0] sdata = cfg[4] ? ~spr_d : spr_d;

wire [3:0] rc_lines = {~((hcnt[7:3] == 5'd0 || hcnt[7:3] == 5'd31) && vcnt[7:3] >= 5'd2),
                       ~(vcnt[7:3] == 5'd2),
                       2'b11};

always_ff @(posedge clk) begin
    if (ph == 2'd2) lbits <= ~cfg[0] ? 4'hF : cfg[6] ? rc_lines : lp_q[3:0];
    if (ce_pix) begin
        csr <= (load && v_vis) ? chr_q : {csr[6:0], 1'b0};
        if (swin) ssr <= sload ? sdata : {ssr[6:0], 1'b0};
    end
end

wire row0   = (vcnt[2:0] == 3'd0);
wire lines  = vis & ((~lbits[3] & load) | (~lbits[2] & row0) | (~lbits[1] & row0 & hcnt[0]) | (~lbits[0] & load & ~vcnt[0]));
wire chr_px = csr[7] & v_vis;
wire pf     = chr_px | lines;
wire obj_px = ssr[7];
wire coll   = pf & obj_px & vis;

always_ff @(posedge clk) begin
    if (ce_pix) begin
        pix_x   <= hcnt;
        pix_y   <= vcnt;
        pix_rgb <= (vis && (pf || obj_px)) ? 3'b111 : 3'b000;
    end
end

wire vbl_start = ce_pix && (hcnt == H_VCNT) && (vcnt == 9'd255);
wire irq_clr   = cpu_ce & sel_pad;
logic irq_q = 1'b0;
always_ff @(posedge clk) begin
    if (reset || irq_clr) irq_q <= 1'b0;
    else if ((cfg[3] && ce_pix && coll) || (cfg[2] && vbl_start)) irq_q <= 1'b1;
end
assign cpu_irq_n   = ~irq_q;
assign vbl_irq_raw = ~v_vis;

always_comb begin
    cpu_di = 8'hFF;
    if      (sel_rom)  cpu_di = rom_d;
    else if (sel_ram)  cpu_di = ram_q;
    else if (sel_vram) cpu_di = vram_q_cpu;
    else if (sel_in)   cpu_di = in0;
    else if (sel_dsw)  cpu_di = {cfg[1] ? ~v_vis : v_vis, dsw[6:0]};
    else if (sel_pad)  cpu_di = paddle;
end

endmodule

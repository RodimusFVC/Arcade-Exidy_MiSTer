//  SPDX-License-Identifier: BSD-3-Clause
//  Based on MAME src/devices/sound/hc55516.cpp (license:BSD-3-Clause, copyright-holders: Aaron Giles, Jonathan Gevaryahu)
//  Copyright (C) 2026 Rodimus

module mc3417
(
    input  logic               clk,
    input  logic               rst,
    input  logic               bclk,
    input  logic               din,
    output logic signed [23:0] integ
);

localparam logic signed [23:0] FMAX   = 24'sd71788;
localparam logic signed [23:0] FMIN   = 24'sd2726;
localparam logic        [16:0] LEAK   = 17'd61565;
localparam logic        [16:0] CHARGE = 17'd64520;
localparam logic        [16:0] DECAY  = 17'd64520;

logic        bclk_d;
logic [1:0]  sr;
logic signed [23:0] syl;

wire fall = bclk_d & ~bclk;
wire [2:0] sr_n = {sr[1:0], din};
wire coinc = (sr_n == 3'b000) | (sr_n == 3'b111);

wire signed [24:0] integ_x = {integ[23], integ};
wire signed [24:0] syl_x   = {syl[23], syl};
wire signed [24:0] i_sum   = din ? (integ_x - syl_x) : (integ_x + syl_x);
wire signed [42:0] i_prod = i_sum * $signed({1'b0, LEAK});
wire signed [23:0] i_next = i_prod[39:16];

wire signed [23:0] syl_gap  = FMAX - syl;
wire signed [41:0] chg_prod = syl_gap * $signed({1'b0, CHARGE});
wire signed [41:0] dec_prod = syl * $signed({1'b0, DECAY});
wire signed [23:0] syl_chg  = FMAX - chg_prod[39:16];
wire signed [23:0] syl_dec  = dec_prod[39:16];
wire unused_p = &{1'b0, i_prod[42:40], i_prod[15:0], chg_prod[41:40], chg_prod[15:0], dec_prod[41:40], dec_prod[15:0]};

always_ff @(posedge clk) begin
    if (rst) begin
        bclk_d <= 1'b0;
        sr     <= 2'b00;
        syl    <= 24'sd0;
        integ  <= 24'sd0;
    end else begin
        bclk_d <= bclk;
        if (fall) begin
            sr    <= sr_n[1:0];
            integ <= i_next;
            if (coinc)
                syl <= (syl_chg > FMAX) ? FMAX : syl_chg;
            else
                syl <= (syl_dec < FMIN) ? FMIN : syl_dec;
        end
    end
end

endmodule

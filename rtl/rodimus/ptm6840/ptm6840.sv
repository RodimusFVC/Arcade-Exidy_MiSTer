//  SPDX-License-Identifier: BSD-3-Clause
//  Copyright (C) 2026 Rodimus
//  MC6840 PTM, written from the Motorola datasheet.

module ptm6840
(
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       cs,
    input  logic       rw,
    input  logic [2:0] rs,
    input  logic [7:0] din,
    output logic [7:0] dout,
    input  logic [2:0] cx,
    output logic [2:0] o,
    output logic       irq
);

logic [7:0]  cr [0:2];
logic [15:0] latch [0:2];
logic [15:0] cnt [0:2];
logic [2:0]  st;
logic [2:0]  fired;
logic [2:0]  flag;
logic [2:0]  stat_rd;
logic [7:0]  msb_buf, lsb_buf;
logic [2:0]  cx_d;
logic [2:0]  t3_pre;

wire wr_en = ce & cs & ~rw;
wire rd_en = ce & cs &  rw;
wire hold  = cr[0][0];

logic [2:0] ext_fall;
logic [2:0] tick;
always_comb begin
    ext_fall = cx_d & ~cx;
    for (int i = 0; i < 3; i++)
        tick[i] = ce & (cr[i][1] | ext_fall[i]);
end
wire t3_tick = tick[2] & (~cr[2][0] | (t3_pre == 3'd7));

always_ff @(posedge clk) begin
    if (rst) begin
        cr[0] <= 8'h01; cr[1] <= 8'h00; cr[2] <= 8'h00;
        for (int i = 0; i < 3; i++) begin
            latch[i] <= 16'hFFFF;
            cnt[i]   <= 16'hFFFF;
        end
        st <= 3'b000; fired <= 3'b000; flag <= 3'b000; stat_rd <= 3'b000;
        msb_buf <= 8'h00; lsb_buf <= 8'h00;
        cx_d <= 3'b000; t3_pre <= 3'd0;
    end else begin
        if (ce) begin
            cx_d <= cx;
            if (tick[2] & cr[2][0]) t3_pre <= t3_pre + 3'd1;
        end

        if (hold) begin
            for (int i = 0; i < 3; i++) begin
                cnt[i] <= latch[i];
                st[i]  <= 1'b0;
            end
            fired <= 3'b000;
            flag  <= 3'b000;
            stat_rd <= 3'b000;
        end else begin
            for (int i = 0; i < 3; i++) begin
                if ((i == 2) ? t3_tick : tick[i]) begin
                    if (!cr[i][2]) begin
                        if (cnt[i] == 16'h0000) begin
                            cnt[i] <= latch[i];
                            st[i]  <= ~st[i];
                            flag[i] <= 1'b1; stat_rd[i] <= 1'b0;
                            if (cr[i][5] & st[i]) fired[i] <= 1'b1;
                        end else
                            cnt[i] <= cnt[i] - 16'd1;
                    end else begin
                        if (cnt[i][7:0] == 8'h00) begin
                            if (cnt[i][15:8] == 8'h00) begin
                                cnt[i] <= latch[i];
                                st[i]  <= 1'b0;
                                flag[i] <= 1'b1; stat_rd[i] <= 1'b0;
                                if (cr[i][5]) fired[i] <= 1'b1;
                            end else begin
                                cnt[i][7:0]  <= latch[i][7:0];
                                cnt[i][15:8] <= cnt[i][15:8] - 8'd1;
                                if (cnt[i][15:8] == 8'h01) st[i] <= 1'b1;
                            end
                        end else
                            cnt[i][7:0] <= cnt[i][7:0] - 8'd1;
                    end
                end
            end
        end

        if (rd_en) begin
            case (rs)
                3'd1: stat_rd <= stat_rd | flag;
                3'd2, 3'd4, 3'd6: begin
                    lsb_buf <= cnt[rs[2:1] - 2'd1][7:0];
                    if (stat_rd[rs[2:1] - 2'd1]) begin
                        flag[rs[2:1] - 2'd1]    <= 1'b0;
                        stat_rd[rs[2:1] - 2'd1] <= 1'b0;
                    end
                end
                default: ;
            endcase
        end

        if (wr_en) begin
            case (rs)
                3'd0: begin
                    if (cr[1][0]) cr[0] <= din; else cr[2] <= din;
                end
                3'd1: cr[1] <= din;
                3'd2, 3'd4, 3'd6: msb_buf <= din;
                default: begin
                    latch[rs[2:1] - 2'd1] <= {msb_buf, din};
                    flag[rs[2:1] - 2'd1]  <= 1'b0;
                    if (!cr[rs[2:1] - 2'd1][4] || hold) begin
                        cnt[rs[2:1] - 2'd1]   <= {msb_buf, din};
                        fired[rs[2:1] - 2'd1] <= 1'b0;
                    end
                end
            endcase
        end
    end
end

always_comb begin
    for (int i = 0; i < 3; i++)
        o[i] = cr[i][7] & st[i] & ~fired[i] & ~cr[i][3];
end

wire [2:0] irq_bits = flag & {cr[2][6], cr[1][6], cr[0][6]};
assign irq = |irq_bits;

always_comb begin
    case (rs)
        3'd0:             dout = 8'h00;
        3'd1:             dout = {irq, 4'b0000, flag};
        3'd2, 3'd4, 3'd6: dout = cnt[rs[2:1] - 2'd1][15:8];
        default:          dout = lsb_buf;
    endcase
end

endmodule

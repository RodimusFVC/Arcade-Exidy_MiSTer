//  Based on MAME pit8253.cpp (Wilbert Pol, Nathan Woods, BSD-3-Clause)

module pit8253
(
    input  logic       clk,
    input  logic       rst,
    input  logic       wr_en,
    input  logic [1:0] a,
    input  logic [7:0] din,
    input  logic       clk_ce,
    input  logic [2:0] gate,
    output logic [2:0] out
);

function automatic [16:0] to_count(input [15:0] v, input isbcd);
    logic [16:0] b;
    begin
        if (isbcd)
            b = {13'd0, v[15:12]} * 17'd1000 + {13'd0, v[11:8]} * 17'd100 + {13'd0, v[7:4]} * 17'd10 + {13'd0, v[3:0]};
        else
            b = {1'b0, v};
        if (b == 17'd0) b = isbcd ? 17'd10000 : 17'h10000;
        to_count = b;
    end
endfunction

genvar gi;
generate
for (gi = 0; gi < 3; gi = gi + 1) begin : ctr

    logic [2:0]  mode;
    logic [1:0]  rwm;
    logic        bcd;
    logic        msb_next;
    logic [15:0] cr;
    logic        cr_new;
    logic [16:0] ce_cnt;
    logic        armed;
    logic        o;
    logic        gate_d, trig;
    logic        cnt_stop;

    localparam logic [1:0] IDX = gi;
    wire sel_ctl = wr_en & (a == 2'd3) & (din[7:6] == IDX) & (din[5:4] != 2'd0);
    wire sel_cnt = wr_en & (a == IDX);

    wire [16:0] n_cr = to_count(cr, bcd);

    always_ff @(posedge clk) begin
        if (rst) begin
            mode <= 3'd0; rwm <= 2'd3; bcd <= 1'b0; msb_next <= 1'b0;
            cr <= 16'h0000; cr_new <= 1'b0; ce_cnt <= 17'd0; armed <= 1'b0;
            o <= 1'b0; gate_d <= 1'b1; trig <= 1'b0; cnt_stop <= 1'b0;
        end else begin
            gate_d <= gate[gi];
            if (gate[gi] & ~gate_d) trig <= 1'b1;

            if (clk_ce) begin
                trig <= 1'b0;
                case (mode)
                    3'd0: begin
                        if (cr_new) begin
                            ce_cnt <= n_cr; cr_new <= 1'b0; armed <= 1'b1;
                        end else if (armed & gate[gi] & ~cnt_stop) begin
                            ce_cnt <= ce_cnt - 17'd1;
                            if (ce_cnt == 17'd1) o <= 1'b1;
                        end
                    end
                    3'd1: begin
                        if (trig & (armed | cr_new)) begin
                            ce_cnt <= n_cr; cr_new <= 1'b0; armed <= 1'b1; o <= 1'b0;
                        end else if (armed) begin
                            ce_cnt <= ce_cnt - 17'd1;
                            if (ce_cnt == 17'd1) o <= 1'b1;
                        end
                    end
                    3'd2, 3'd6: begin
                        if ((cr_new & ~armed) | (trig & (armed | cr_new))) begin
                            ce_cnt <= n_cr; cr_new <= 1'b0; armed <= 1'b1; o <= 1'b1;
                        end else if (armed & gate[gi]) begin
                            if (ce_cnt == 17'd2) begin
                                o <= 1'b0; ce_cnt <= 17'd1;
                            end else if (ce_cnt <= 17'd1) begin
                                o <= 1'b1; ce_cnt <= n_cr; cr_new <= 1'b0;
                            end else
                                ce_cnt <= ce_cnt - 17'd1;
                        end
                    end
                    3'd3, 3'd7: begin
                        if ((cr_new & ~armed) | (trig & (armed | cr_new))) begin
                            ce_cnt <= n_cr[0] ? n_cr + 17'd1 : n_cr;
                            cr_new <= 1'b0; armed <= 1'b1; o <= 1'b1;
                        end else if (armed & gate[gi]) begin
                            if (ce_cnt <= 17'd2) begin
                                o <= ~o;
                                cr_new <= 1'b0;
                                if (o)
                                    ce_cnt <= n_cr[0] ? ((n_cr > 17'd3) ? n_cr - 17'd1 : 17'd2) : n_cr;
                                else
                                    ce_cnt <= n_cr[0] ? n_cr + 17'd1 : n_cr;
                            end else
                                ce_cnt <= ce_cnt - 17'd2;
                        end
                    end
                    3'd4: begin
                        if (cr_new) begin
                            ce_cnt <= n_cr; cr_new <= 1'b0; armed <= 1'b1; o <= 1'b1;
                        end else if (armed & gate[gi]) begin
                            ce_cnt <= ce_cnt - 17'd1;
                            if (ce_cnt == 17'd1) o <= 1'b0;
                            else if (ce_cnt == 17'd0) begin o <= 1'b1; armed <= 1'b0; end
                        end else
                            o <= 1'b1;
                    end
                    default: begin
                        if (trig & (armed | cr_new)) begin
                            ce_cnt <= n_cr; cr_new <= 1'b0; armed <= 1'b1; o <= 1'b1;
                        end else if (armed) begin
                            ce_cnt <= ce_cnt - 17'd1;
                            if (ce_cnt == 17'd1) o <= 1'b0;
                            else if (ce_cnt == 17'd0) begin o <= 1'b1; armed <= 1'b0; end
                        end else
                            o <= 1'b1;
                    end
                endcase
            end

            if (sel_ctl) begin
                mode     <= din[3:1];
                rwm      <= din[5:4];
                bcd      <= din[0];
                msb_next <= 1'b0;
                cr_new   <= 1'b0;
                armed    <= 1'b0;
                cnt_stop <= 1'b0;
                o        <= (din[3:1] == 3'd0) ? 1'b0 : 1'b1;
            end

            if (sel_cnt) begin
                case (rwm)
                    2'd1: begin cr <= {8'h00, din}; cr_new <= 1'b1; end
                    2'd2: begin cr <= {din, 8'h00}; cr_new <= 1'b1; end
                    default: begin
                        if (!msb_next) begin
                            cr[7:0]  <= din;
                            msb_next <= 1'b1;
                            if (mode == 3'd0) begin cnt_stop <= 1'b1; o <= 1'b0; end
                        end else begin
                            cr[15:8] <= din;
                            msb_next <= 1'b0;
                            cr_new   <= 1'b1;
                            cnt_stop <= 1'b0;
                        end
                    end
                endcase
                if ((rwm != 2'd3) && (mode == 3'd0)) o <= 1'b0;
            end
        end
    end

    assign out[gi] = o;
end
endgenerate

endmodule

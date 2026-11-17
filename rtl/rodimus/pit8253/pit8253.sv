//============================================================================
//
//  pit8253.sv — Intel 8253 / 8254 PIT
//  Copyright (C) 2026 Rodimus
//  SPDX-License-Identifier: BSD-3-Clause
//  Ported from MAME devices/machine/pit8253.cpp (Wilbert Pol, Nathan Woods, BSD-3-Clause)
//
//  Port mapping: MAME's discrete-event path (CLK pins driven through write_clkN, m_clockin == 0). One clk_ce[n]
//  pulse is one full CLK n cycle: set_clock_signal(1) (GATE sampled, rising-GATE flip-flop acted on) immediately
//  followed by set_clock_signal(0) (simulate(1)). The three counters have independent clocks.
//    gate[n]    write_gateN(): any change is one gate_w event (rising edge latched for modes 1, 2, 3, 5)
//    cs/wr/a/din  write(): a = 0..2 count_w, a = 3 control_w (counter latch) or, 8254, the read-back command
//    cs/rd/a/dout  read(): dout is combinational for address a (a = 3 reads 0); the read side effects (RMSB,
//                  latched-count / latched-status counts) happen at the clock where cs & rd is high
//    out[n]     m_output_pin (MAME's "undetermined" value 2 after reset reads as 1 here)
//  Within one clk the events are applied in this order: gate change, bus write, bus read side effects, clk_ce.
//  wr and rd must not be high on the same clk.
//  Two Intel 8253 datasheet rules (231306-001) replace MAME's behaviour:
//    1. A count takes effect on the CLK cycle after the write (3-54 "followed by a rising edge and a falling edge of
//       the clock"): a bus write on the same clk as a counter's clk_ce reaches that counter one clk later, after the
//       CLK cycle it overlapped (while one is pending, the next write to that counter is also held one clk). A read
//       on the clk a held write lands returns the data from before it; its side effects act after it.
//    2. Modes 2 / 3: a GATE rise starts counting only once a count has been written since the mode word (3-55: the
//       output remains high until the count register is loaded).
//  Both measured on the Exidy sound board stream against the core's write-only 8253 model (2026-11-15). rst = MAME device_start + device_reset (gate input 1, all
//  counters in the undefined state: control 0x30, count 0, output high, null count).
//  PIT8254 = 0: 8253, the read-back command (control write with bits 7:6 = 11) does nothing.
//  PIT8254 = 1: 8254 read-back command (count, status, any mix of counters) and the status byte.
//  The counter latch command (control write with bits 5:4 = 00) works on both.
//  Kept MAME behaviour: modes 6 / 7 act as 2 / 3, count 1 becomes 2 (mode 2) / 0 (mode 3), mode 3 reads mask bit 0,
//  mode 4 / 5 with a zero count strobes at once, a mid-16-bit-write read returns ~LSB, the mode 0 MSB write stops
//  counting, a counter keeps counting down in modes 1, 4, 5 and after the terminal count in mode 0.
//
//============================================================================

module pit8253 #(
    parameter PIT8254 = 0             // 0 = 8253, 1 = 8254 (read-back command + status byte)
)(
    input        clk,
    input        rst,

    input        cs,
    input        wr,                  // one clock per write cycle
    input        rd,                  // one clock per read cycle (side effects at its end)
    input  [1:0] a,
    input  [7:0] din,
    output [7:0] dout,

    input  [2:0] clk_ce,              // CLK n cycle, one pulse per cycle
    input  [2:0] gate,
    output [2:0] out
);

// MAME CTRL_MODE: control bit 2 set -> only modes 2 / 3 exist (6 / 7 alias to them)
function [2:0] mode_of(input [3:1] c);
    mode_of = c[2] ? {1'b0, c[2:1]} : c[3:1];
endfunction

// MAME decrease_counter_value(n) for n = 0..2, binary or BCD (digits A-F count down normally, wrap to 9)
function [15:0] dec_val(input [15:0] v, input bcd, input [1:0] n);
    reg [3:0] un, tn, hn, kn;
    reg [4:0] x;
    reg       bu, bt, bh;
    begin
        if (!bcd) begin
            dec_val = v - {14'd0, n};
        end else begin
            bu = (v[3:0] < {2'b00, n});
            un = bu ? (4'd10 + v[3:0] - {2'b00, n}) : (v[3:0] - {2'b00, n});
            bt = bu && (v[7:4] == 4'd0);
            tn = bu ? ((v[7:4] == 4'd0) ? 4'd9 : (v[7:4] - 4'd1)) : v[7:4];
            bh = bt && (v[11:8] == 4'd0);
            hn = bt ? ((v[11:8] == 4'd0) ? 4'd9 : (v[11:8] - 4'd1)) : v[11:8];
            x  = {1'b0, v[15:12]} + 5'd9;
            kn = bh ? ((x >= 5'd20) ? x[3:0] - 4'd4 : (x >= 5'd10) ? x[3:0] - 4'd10 : x[3:0]) : v[15:12];
            dec_val = {kn, hn, tn, un};
        end
    end
endfunction

wire [23:0] rdat_f;
wire  [2:0] pin_f;

genvar i;
generate for (i = 0; i < 3; i = i + 1) begin : ctr
    localparam [1:0] ID  = i;
    localparam [2:0] RBB = i + 1;     // read-back select bit

    // ---- MAME pit_counter_device state ----
    reg  [5:0]  ctrl;                 // m_control
    reg  [15:0] val;                  // m_value (CE)
    reg  [15:0] cnt;                  // m_count (CR)
    reg  [15:0] latch;                // m_latch (OL)
    reg  [7:0]  lowcnt;               // m_lowcount
    reg  [7:0]  status;               // m_status
    reg  [1:0]  ph;                   // m_phase
    reg  [1:0]  lat_cnt;              // m_latched_count
    reg         outp;                 // m_output
    reg         pin;                  // m_output_pin
    reg         gate_in;              // m_gate_input
    reg         rose;                 // m_gate_rose
    reg         lat_stat;             // m_latched_status
    reg         null_c;               // m_null_count
    reg         rmsb, wmsb;           // m_rmsb, m_wmsb
    reg         cnt_wr;               // a count was written since the last mode word (datasheet rule 2)

    reg  [5:0]  n_ctrl;
    reg  [15:0] n_val, n_cnt, n_latch;
    reg  [7:0]  n_lowcnt, n_status;
    reg  [1:0]  n_ph, n_lat_cnt;
    reg         n_outp, n_pin, n_gate_in, n_rose, n_lat_stat, n_null, n_rmsb, n_wmsb, n_cnt_wr;
    reg         e;                    // elapsed cycles left in simulate() (0 / 1)
    reg         do_ld;
    reg  [15:0] ldv, ldn, rbv;

    `define PIT_FLUSH   n_pin = (n_ctrl[2] && !n_gate_in) ? 1'b1 : n_outp;
    `define PIT_SETOUT(pit_v) \
        if ((pit_v) != n_outp) begin \
            n_outp = (pit_v); \
            `PIT_FLUSH \
        end
    `define PIT_LOAD    n_val = n_cnt; n_null = 1'b0;

    // datasheet rule 1: a write on this counter's clk_ce clk (or behind a held one) is held one clk
    reg         pw;                   // held write
    reg  [1:0]  pa;
    reg  [7:0]  pd;
    wire        bw    = cs && wr;
    wire        hold  = bw && (clk_ce[i] || pw);
    wire        w_e   = pw || (bw && !hold);
    wire [1:0]  a_e   = pw ? pa : a;
    wire [7:0]  d_e   = pw ? pd : din;
    always @(posedge clk) begin
        if (rst) pw <= 1'b0;
        else     pw <= hold;
        if (hold) begin pa <= a; pd <= din; end
    end

    wire bus_ctl = w_e && (a_e == 2'd3);
    wire cw_lat  = bus_ctl && (d_e[7:6] == ID) && (d_e[5:4] == 2'b00);   // counter latch command
    wire cw_set  = bus_ctl && (d_e[7:6] == ID) && (d_e[5:4] != 2'b00);   // mode control word
    wire rbc     = (PIT8254 != 0) && bus_ctl && (d_e[7:6] == 2'b11) && d_e[RBB];
    wire rb_st   = rbc && !d_e[4];                                       // read-back: status
    wire rb_ct   = cw_lat || (rbc && !d_e[5]);                           // read-back / latch: count
    wire cnt_w   = w_e && (a_e == ID);
    wire rd_sel  = cs && rd && (a == ID);

    always_comb begin : ev
        n_ctrl = ctrl; n_val = val; n_cnt = cnt; n_latch = latch; n_lowcnt = lowcnt; n_status = status;
        n_ph = ph; n_lat_cnt = lat_cnt; n_outp = outp; n_pin = pin; n_gate_in = gate_in; n_rose = rose;
        n_lat_stat = lat_stat; n_null = null_c; n_rmsb = rmsb; n_wmsb = wmsb; n_cnt_wr = cnt_wr;
        e = 1'b0; do_ld = 1'b0; ldv = 16'd0; ldn = 16'd0; rbv = 16'd0;

        // 1. gate_w_deferred (CLK driven by write_clk: m_gate is sampled on the clock edge below)
        if (gate[i] != gate_in) begin
            n_gate_in = gate[i];
            if (gate[i] && (ctrl[2] || ctrl[1])) n_rose = 1'b1;     // edge_sensitive_gate: modes 1, 2, 3, 5
            `PIT_FLUSH
        end

        // 2a. readback() — counter latch command and 8254 read-back command
        if (rb_st && !n_lat_stat) begin
            n_status = {n_outp, n_null, n_ctrl};
            n_lat_stat = 1'b1;
        end
        if (rb_ct && !n_rmsb && n_lat_cnt == 2'd0) begin
            rbv = (n_ctrl[2] && n_ctrl[1]) ? {n_val[15:1], 1'b0} : n_val;   // masked_value
            case (n_ctrl[5:4])
            2'd1:    begin n_latch = {rbv[7:0],  rbv[7:0]};  n_lat_cnt = 2'd1; end
            2'd2:    begin n_latch = {rbv[15:8], rbv[15:8]}; n_lat_cnt = 2'd1; end
            2'd3:    begin n_latch = rbv;                    n_lat_cnt = 2'd2; end
            default: ;
            endcase
        end

        // 2b. control_w_deferred (mode set)
        if (cw_set) begin
            n_ctrl = d_e[5:0]; n_null = 1'b1; n_wmsb = 1'b0; n_rmsb = 1'b0; n_ph = 2'd0; n_cnt_wr = 1'b0;
            `PIT_SETOUT(mode_of(d_e[3:1]) != 3'd0)
        end

        // 2c. count_w_deferred
        if (cnt_w) begin
            case (n_ctrl[5:4])
            2'd1: begin
                ldv = {8'h00, d_e}; do_ld = 1'b1;
                if (mode_of(n_ctrl[3:1]) == 3'd0) begin `PIT_SETOUT(1'b0) end
            end
            2'd2: begin
                ldv = {d_e, 8'h00}; do_ld = 1'b1;
                if (mode_of(n_ctrl[3:1]) == 3'd0) begin `PIT_SETOUT(1'b0) end
            end
            2'd3: begin
                if (n_wmsb) begin
                    ldv = {d_e, n_lowcnt}; do_ld = 1'b1;
                end else begin
                    n_lowcnt = d_e;
                    if (mode_of(n_ctrl[3:1]) == 3'd0) begin
                        n_ph = 2'd0;
                        `PIT_SETOUT(1'b0)
                    end
                end
                n_wmsb = ~n_wmsb;
            end
            default: ;
            endcase
        end
        if (do_ld) begin                                            // load_count
            n_cnt_wr = 1'b1;
            ldn = ldv;
            if (ldv == 16'd1) begin
                if (mode_of(n_ctrl[3:1]) == 3'd2) ldn = 16'd2;
                if (mode_of(n_ctrl[3:1]) == 3'd3) ldn = 16'd0;
            end
            n_cnt = ldn;
            if (n_ctrl[2]) begin                                    // modes 2, 3
                if (n_ph == 2'd0) n_ph = 2'd1;
            end else if (n_ctrl[3:1] == 3'd0 || n_ctrl[3:1] == 3'd4) begin   // modes 0, 4
                n_ph = 2'd1;
            end
        end

        // 3. read(): side effects only, after this clk's write (a held write landing with a read; otherwise = registers)
        if (rd_sel) begin
            if (n_lat_stat)                 n_lat_stat = 1'b0;
            else if (n_lat_cnt != 2'd0)   begin n_rmsb = ~n_rmsb; n_lat_cnt = n_lat_cnt - 2'd1; end
            else if (n_ctrl[5:4] == 2'd3) n_rmsb = ~n_rmsb;
        end

        // 4. set_clock_signal(1) then set_clock_signal(0): GATE sample + simulate(1)
        if (clk_ce[i]) begin
            if (n_rose) begin
                // datasheet rule 2: modes 2 / 3 start on the gate edge only after a count was written
                if ((n_ctrl[2] && n_cnt_wr) || (!n_ctrl[2] && n_ctrl[1])) n_ph = 2'd1;
                n_rose = 1'b0;
            end
            e = 1'b1;
            case (mode_of(n_ctrl[3:1]))
            3'd0: begin                                             // interrupt on terminal count
                if (n_ph != 2'd0) begin
                    if (n_ph == 2'd1) begin e = 1'b0; n_ph = 2'd2; `PIT_LOAD end
                    if (n_gate_in) begin
                        if (n_ph == 2'd2 && e && n_val == 16'd1) begin
                            e = 1'b0; n_ph = 2'd3; n_val = 16'd0; `PIT_SETOUT(1'b1)
                        end
                        n_val = dec_val(n_val, n_ctrl[0], {1'b0, e});
                    end
                end
            end
            3'd1: begin                                             // programmable one-shot
                if (n_ph == 2'd1) begin e = 1'b0; n_ph = 2'd2; `PIT_LOAD `PIT_SETOUT(1'b0) end
                if (n_ph == 2'd2 && e && n_val == 16'd1) begin n_ph = 2'd3; `PIT_SETOUT(1'b1) end
                n_val = dec_val(n_val, n_ctrl[0], {1'b0, e});
            end
            3'd2: begin                                             // rate generator
                if (!n_gate_in || n_ph == 2'd0) begin
                    `PIT_SETOUT(1'b1)
                end else begin
                    if (n_ph == 2'd1) begin e = 1'b0; n_ph = 2'd2; `PIT_LOAD end
                    if (n_ph == 2'd2 && (e ? (n_val == 16'd1 || n_val == 16'd2) : (n_val == 16'd1))) begin
                        n_ph = 2'd3; `PIT_SETOUT(1'b0)
                    end
                    if (e && n_ph == 2'd3 && n_val == 16'd1) begin
                        e = 1'b0; n_ph = 2'd2; `PIT_LOAD `PIT_SETOUT(1'b1)
                    end
                    n_val = dec_val(n_val, n_ctrl[0], {1'b0, e});
                end
            end
            3'd3: begin                                             // square wave
                if (!n_gate_in || n_ph == 2'd0) begin
                    `PIT_SETOUT(1'b1)
                end else begin
                    if (n_ph == 2'd1) begin e = 1'b0; n_ph = 2'd2; `PIT_LOAD end
                    if (e) begin
                        // MAME's do { ... } while loop: with one elapsed cycle a second pass is dead code (phase 3 never
                        // sits at value 1: it enters at the loaded count and reloads at 2 / 3), so one pass is enough
                        if (n_ph == 2'd2 && e && (n_val == 16'd1 || n_val == 16'd2)) begin
                            e = 1'b0; n_ph = 2'd3; `PIT_LOAD `PIT_SETOUT(1'b0)
                        end
                        if (n_ph == 2'd3 && (e ? (n_val >= 16'd1 && n_val <= 16'd3) : (n_val == 16'd1))) begin
                            if (e && n_val != 16'd1) e = 1'b0;
                            n_ph = 2'd2; `PIT_LOAD `PIT_SETOUT(1'b1)
                        end
                        n_val = dec_val(n_val, n_ctrl[0], {e, 1'b0});
                    end
                end
            end
            3'd4, 3'd5: begin                                       // software / hardware triggered strobe
                if (!(n_ctrl[3:1] == 3'd4 && !n_gate_in)) begin
                    if (n_ph == 2'd1) begin e = 1'b0; n_ph = 2'd2; `PIT_LOAD end
                    if (n_ph == 2'd2 && (n_val == 16'd0 || e && n_val == 16'd1)) begin
                        if (n_val != 16'd0) e = 1'b0;
                        n_ph = 2'd3; n_val = 16'd0; `PIT_SETOUT(1'b0)
                    end
                    if (e && n_ph == 2'd3) begin
                        e = 1'b0; n_ph = 2'd0; n_val = dec_val(n_val, n_ctrl[0], 2'd1); `PIT_SETOUT(1'b1)
                    end
                    n_val = dec_val(n_val, n_ctrl[0], {1'b0, e});
                end
            end
            default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            ctrl <= 6'h30; val <= 16'd0; cnt <= 16'd0; ph <= 2'd0; lat_cnt <= 2'd0;
            outp <= 1'b1; pin <= 1'b1; gate_in <= 1'b1; rose <= 1'b0; lat_stat <= 1'b0; null_c <= 1'b1;
            rmsb <= 1'b0; wmsb <= 1'b0; cnt_wr <= 1'b0;
        end else begin
            ctrl <= n_ctrl; val <= n_val; cnt <= n_cnt; ph <= n_ph; lat_cnt <= n_lat_cnt;
            outp <= n_outp; pin <= n_pin; gate_in <= n_gate_in; rose <= n_rose; lat_stat <= n_lat_stat;
            null_c <= n_null; rmsb <= n_rmsb; wmsb <= n_wmsb; cnt_wr <= n_cnt_wr;
        end
        // only read after being written (latch command / 16-bit write / read-back), no reset needed
        latch <= n_latch; lowcnt <= n_lowcnt; status <= n_status;
    end

    // read(): value on the bus for this counter
    wire [15:0] mv = (ctrl[2] && ctrl[1]) ? {val[15:1], 1'b0} : val;
    reg  [7:0]  rd_data;
    always_comb begin : rdmux
        if (lat_stat)                rd_data = status;
        else if (lat_cnt != 2'd0)    rd_data = rmsb ? latch[15:8] : latch[7:0];
        else case (ctrl[5:4])
            2'd1:    rd_data = mv[7:0];
            2'd2:    rd_data = mv[15:8];
            2'd3:    rd_data = wmsb ? ~lowcnt : (rmsb ? mv[15:8] : mv[7:0]);
            default: rd_data = 8'd0;
        endcase
    end

    assign rdat_f[8*i +: 8] = rd_data;
    assign pin_f[i]         = pin;

    `undef PIT_FLUSH
    `undef PIT_SETOUT
    `undef PIT_LOAD
end endgenerate

assign out  = pin_f;
assign dout = (a == 2'd0) ? rdat_f[7:0] :
              (a == 2'd1) ? rdat_f[15:8] :
              (a == 2'd2) ? rdat_f[23:16] : 8'h00;       // reading the control register returns 0

endmodule

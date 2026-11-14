//  MOS 6532 RIOT (128 B RAM, two 8-bit ports, interval timer); single clock, qualified by the E enable
//  SPDX-License-Identifier: BSD-3-Clause
//  Copyright (C) 2026 Rodimus
//  Based on MAME src/devices/machine/mos6530.cpp, mos6532_device (license:BSD-3-Clause, copyright-holders: Curt Coder)
//  timer write : A2=1 A4=1, A1:A0 = /1 /8 /64 /1024, A3 = timer IRQ enable; IRQ after 1 + N*P E clocks, then /1 spin
//  timer read  : A2=1 A0=0, A3 = timer IRQ enable; clears the timer flag (not if set this cycle), restarts a spin
//  flag read   : A2=1 A0=1 -> {timer, PA7 edge, 6'b0}; clears the edge flag
//  edge control: write A2=1 A4=0: A0 = positive edge, A1 = edge IRQ enable

module riot6532
(
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       ram_cs,
    input  logic       io_cs,
    input  logic       rw,          // 1 = read
    input  logic [6:0] a,
    input  logic [7:0] din,
    output logic [7:0] dout,
    output logic       irq,

    input  logic [7:0] pa_i,        // external drive for input pins (1 = undriven / pulled up)
    output logic [7:0] pa_pins,
    input  logic [7:0] pb_i,
    output logic [7:0] pb_pins
);

logic [7:0] ram_q;
dpram_dc #(.widthad_a(7), .width_a(8)) ram
(
    .clock_a(clk), .address_a(a), .data_a(din), .wren_a(ce & ram_cs & ~rw), .q_a(),
    .clock_b(clk), .address_b(a), .data_b(8'h00), .wren_b(1'b0), .q_b(ram_q)
);

logic [7:0] pa_out, pa_ddr, pb_out, pb_ddr;
assign pa_pins = (pa_out & pa_ddr) | (pa_i & ~pa_ddr);
assign pb_pins = (pb_out & pb_ddr) | (pb_i & ~pb_ddr);

logic [7:0]  tval;
logic [9:0]  pcnt;
logic [1:0]  psel;
logic        spinning;
logic        irq_timer, ie_timer;
logic        irq_edge, ie_edge, edge_pos;
logic        pa7_d;

function automatic [9:0] presc_max(input [1:0] s);
    case (s)
        2'd0: presc_max = 10'd0;
        2'd1: presc_max = 10'd7;
        2'd2: presc_max = 10'd63;
        default: presc_max = 10'd1023;
    endcase
endfunction

wire wr_io = ce & io_cs & ~rw;
wire rd_io = ce & io_cs &  rw;

wire wr_port  = wr_io & ~a[2];
wire wr_timer = wr_io &  a[2] &  a[4];
wire wr_edge  = wr_io &  a[2] & ~a[4];
wire rd_timer = rd_io &  a[2] & ~a[0];
wire rd_flags = rd_io &  a[2] &  a[0];

wire tick      = ce & (spinning | (pcnt == 10'd0));
wire underflow = tick & (tval == 8'h00);

wire pa7 = pa_pins[7];

always_ff @(posedge clk) begin
    if (rst) begin
        pa_out <= 8'h00; pa_ddr <= 8'h00; pb_out <= 8'h00; pb_ddr <= 8'h00;
        tval <= 8'hFF; pcnt <= 10'd1023; psel <= 2'd3; spinning <= 1'b0;
        irq_timer <= 1'b0; ie_timer <= 1'b0;
        irq_edge <= 1'b0; ie_edge <= 1'b0; edge_pos <= 1'b0;
        pa7_d <= 1'b1;
    end else begin
        if (ce) begin
            if (tick) begin
                tval <= tval - 8'd1;
                if (!spinning) pcnt <= presc_max(psel);
                if (tval == 8'h00) begin
                    irq_timer <= 1'b1;
                    spinning  <= 1'b1;
                end
            end else if (!spinning)
                pcnt <= pcnt - 10'd1;
        end

        if (rd_timer) begin
            ie_timer <= a[3];
            if (!underflow) begin
                irq_timer <= 1'b0;
                if (spinning) begin
                    spinning <= 1'b0;
                    pcnt     <= 10'd0;
                    tval     <= tval;
                end
            end
        end

        if (wr_timer) begin
            tval      <= din;
            psel      <= a[1:0];
            pcnt      <= 10'd0;
            spinning  <= 1'b0;
            irq_timer <= 1'b0;
            ie_timer  <= a[3];
        end

        if (wr_edge) begin
            edge_pos <= a[0];
            ie_edge  <= a[1];
        end
        if (rd_flags) irq_edge <= 1'b0;

        pa7_d <= pa7;
        if ((pa7 != pa7_d) && (pa7 == edge_pos)) irq_edge <= 1'b1;

        if (wr_port) begin
            case (a[1:0])
                2'd0: pa_out <= din;
                2'd1: pa_ddr <= din;
                2'd2: pb_out <= din;
                default: pb_ddr <= din;
            endcase
        end
    end
end

assign irq = (irq_timer & ie_timer) | (irq_edge & ie_edge);

always_comb begin
    if (ram_cs)
        dout = ram_q;
    else if (!a[2]) begin
        case (a[1:0])
            2'd0: dout = pa_pins;
            2'd1: dout = pa_ddr;
            2'd2: dout = pb_pins;
            default: dout = pb_ddr;
        endcase
    end else if (!a[0])
        dout = tval;
    else
        dout = {irq_timer, irq_edge, 6'b000000};
end

endmodule

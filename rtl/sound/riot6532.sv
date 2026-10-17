// ============================================================================
// riot6532.sv — MOS 6532 RIOT (128 B RAM, two 8-bit ports, interval timer)
// Single clock, everything qualified by the E enable. Behaviour follows MAME
// machine/mos6530.cpp (mos6532_device):
//  - timer write  : A2=1 A4=1, A1:A0 = /1 /8 /64 /1024, A3 = timer IRQ enable.
//                   IRQ after 1 + N*P E clocks; afterwards the counter "spins"
//                   at /1 with the flag set.
//  - timer read   : A2=1 A0=0, A3 = new timer IRQ enable; clears the timer flag
//                   (not if it was set this very cycle) and, if spinning,
//                   restarts the prescaler from the current value (MAME).
//  - flag read    : A2=1 A0=1 -> {timer, PA7 edge, 6'b0}; clears the edge flag.
//  - edge control : write A2=1 A4=0: A0 = positive edge, A1 = edge IRQ enable.
// RAM is a dpram_dc (1-clk read latency; the address is stable long before ce).
// ============================================================================

module riot6532
(
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,          // E enable
    input  logic       ram_cs,      // /RS low & chip selected
    input  logic       io_cs,       // /RS high & chip selected
    input  logic       rw,          // 1 = read
    input  logic [6:0] a,
    input  logic [7:0] din,
    output logic [7:0] dout,
    output logic       irq,         // active high (board inverts onto the wired-OR /IRQ)

    input  logic [7:0] pa_i,        // external drive for input pins (1 = undriven / pulled up)
    output logic [7:0] pa_pins,     // resolved pin levels: (out & ddr) | (in & ~ddr)
    input  logic [7:0] pb_i,
    output logic [7:0] pb_pins
);

// ---------------------------------------------------------------- RAM
logic [7:0] ram_q;
dpram_dc #(.widthad_a(7), .width_a(8)) ram
(
    .clock_a(clk), .address_a(a), .data_a(din), .wren_a(ce & ram_cs & ~rw), .q_a(),
    .clock_b(clk), .address_b(a), .data_b(8'h00), .wren_b(1'b0), .q_b(ram_q)
);

// ---------------------------------------------------------------- ports
logic [7:0] pa_out, pa_ddr, pb_out, pb_ddr;
assign pa_pins = (pa_out & pa_ddr) | (pa_i & ~pa_ddr);
assign pb_pins = (pb_out & pb_ddr) | (pb_i & ~pb_ddr);

// ---------------------------------------------------------------- timer / irq state
logic [7:0]  tval;
logic [9:0]  pcnt;          // prescaler down-counter
logic [1:0]  psel;          // 0:/1 1:/8 2:/64 3:/1024
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

// timer tick this E: decrement when the prescaler is at 0 (or spinning at /1)
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
        // ---------------- timer counting
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

        // ---------------- timer read (after counting so its effects win)
        if (rd_timer) begin
            ie_timer <= a[3];
            if (!underflow) begin
                irq_timer <= 1'b0;
                if (spinning) begin
                    spinning <= 1'b0;
                    pcnt     <= 10'd0;          // MAME timer_start(current value)
                    tval     <= tval;           // (current value re-armed)
                end
            end
        end

        // ---------------- timer write
        if (wr_timer) begin
            tval      <= din;
            psel      <= a[1:0];
            pcnt      <= 10'd0;                 // first decrement on the next E
            spinning  <= 1'b0;
            irq_timer <= 1'b0;
            ie_timer  <= a[3];
        end

        // ---------------- edge control / flag read
        if (wr_edge) begin
            edge_pos <= a[0];
            ie_edge  <= a[1];
        end
        if (rd_flags) irq_edge <= 1'b0;

        // ---------------- PA7 edge detect (clk rate; after flag-read clear so a new edge wins)
        pa7_d <= pa7;
        if ((pa7 != pa7_d) && (pa7 == edge_pos)) irq_edge <= 1'b1;

        // ---------------- port registers
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

// ---------------------------------------------------------------- read mux
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

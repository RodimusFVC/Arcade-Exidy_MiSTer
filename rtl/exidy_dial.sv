//============================================================================
//
//  Teeter Torture dial (MAME IPT_DIAL, PORT_REVERSE): an absolute 8-bit position fed by the spinner,
//  the mouse X axis and D-pad left / right. The board steps the game's copy toward it one unit per
//  IN0 read (rtl/exidy_board.sv), as MAME's teetert_input_r does.
//
//============================================================================

module exidy_dial
(
    input               clk,            // 22.578 MHz
    input               reset,

    input         [8:0] spinner,        // hps_io: [8] toggles per event, [7:0] signed delta
    input        [24:0] mouse,          // hps_io: [24] toggles per event, {[4], [15:8]} signed X
    input         [1:0] pad,            // {left, right}

    output reg    [7:0] pos = 8'd0
);

// D-pad: one unit every 1/120 s while held (MAME KEYDELTA 30, SENSITIVITY 5) #unverified rate
reg [17:0] div = 18'd0;
wire pad_tick = div == 18'd0;
always @(posedge clk) div <= (div == 18'd188149) ? 18'd0 : div + 18'd1;

reg spin_seen = 1'b0, mouse_seen = 1'b0;
wire       spin_ev  = spinner[8] != spin_seen;
wire       mouse_ev = mouse[24] != mouse_seen;
wire [7:0] spin_d   = spin_ev  ? spinner[7:0] : 8'd0;
wire [7:0] mouse_d  = mouse_ev ? mouse[15:8]  : 8'd0;
wire [7:0] pad_d    = pad_tick && (pad[1] ^ pad[0]) ? (pad[0] ? 8'd1 : 8'hFF) : 8'd0;

// PORT_REVERSE: clockwise / right counts down
always @(posedge clk) begin
    spin_seen  <= spinner[8];
    mouse_seen <= mouse[24];
    if (reset) pos <= 8'd0;
    else       pos <= pos - spin_d - mouse_d - pad_d;
end

endmodule

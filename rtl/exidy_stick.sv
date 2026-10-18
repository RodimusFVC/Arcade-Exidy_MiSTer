//============================================================================
//
//  Star Fire flight stick (MAME IPT_AD_STICK_X / _Y, centre 0x80, Y reversed) and throttle
//  (OSD Standard Control: Y not reversed, up = up for joypads)
//  (IPT_AD_STICK_Z, reversed, no self-centring).
//  Stick: left analog stick, else the D-pad ramps the axis and it re-centres on release.
//  Throttle: right analog stick Y, else two buttons ramp it (it stays where it was left).
//
//============================================================================

module exidy_stick
(
    input               clk,            // 22.578 MHz
    input               reset,

    input        [15:0] analog,         // hps_io joystick_l_analog_0: [15:8] Y, [7:0] X, signed
    input        [15:0] analog_r,       // right stick (throttle on Y)
    input         [3:0] dpad,           // {up, down, left, right}
    input         [1:0] thr_btn,        // {more, less}
    input               std_ctl,        // 1 = Standard Control (Y un-reversed), 0 = Flight Control

    output reg    [7:0] x = 8'h80,
    output reg    [7:0] y = 8'h80,
    output reg    [7:0] z = 8'h80
);

// ramp tick: 1/600 s per unit (MAME KEYDELTA 10 per frame) #unverified feel
reg [15:0] div = 16'd0;
wire tick = div == 16'd0;
always @(posedge clk) div <= (div == 16'd37629) ? 16'd0 : div + 16'd1;

wire signed [7:0] ax = analog[7:0], ay = analog[15:8], ry = analog_r[15:8];
wire use_ax = (ax > 8'sd16) || (ax < -8'sd16);
wire use_ay = (ay > 8'sd16) || (ay < -8'sd16);
wire use_rz = (ry > 8'sd16) || (ry < -8'sd16);

function [7:0] ramp(input [7:0] v, input up, input down, input centre);
    if      (up   && v != 8'hFF) ramp = v + 8'd1;
    else if (down && v != 8'h00) ramp = v - 8'd1;
    else if (centre && !up && !down) ramp = (v > 8'h80) ? v - 8'd1 : (v < 8'h80) ? v + 8'd1 : v;
    else ramp = v;
endfunction

always @(posedge clk) begin
    if (reset) begin
        x <= 8'h80; y <= 8'h80; z <= 8'h80;
    end
    else begin
        if (use_ax) x <= 8'h80 + analog[7:0];
        else if (tick) x <= ramp(x, dpad[0], dpad[1], 1'b1);
        if (use_ay) y <= std_ctl ? 8'h80 + analog[15:8] : 8'h80 - analog[15:8];   // PORT_REVERSE (flight)
        else if (tick) y <= std_ctl ? ramp(y, dpad[2], dpad[3], 1'b1)            // up lowers the axis
                                    : ramp(y, dpad[3], dpad[2], 1'b1);           // up raises the reversed axis
        if (use_rz) z <= 8'h80 - analog_r[15:8];             // PORT_REVERSE
        else if (tick) z <= ramp(z, thr_btn[1], thr_btn[0], 1'b0);
    end
end

endmodule

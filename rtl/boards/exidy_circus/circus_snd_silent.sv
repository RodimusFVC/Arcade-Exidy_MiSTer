//============================================================================
//  PLACEHOLDER (2026-10-17): silent Circus-family audio so the core builds while circus_snd.sv
//  (synthesized discrete audio) is finished. files.qip lists this file OR circus_snd.sv, never both.
//============================================================================

module circus_snd
(
    input  logic        clk,
    input  logic        reset,
    input  logic  [2:0] game,
    input  logic        ce,
    input  logic  [7:0] latch,
    input  logic        latch_wr,
    input  logic  [3:0] vol_music,
    input  logic  [3:0] vol_sfx,
    output logic signed [15:0] audio
);
    assign audio = 16'sd0;
endmodule

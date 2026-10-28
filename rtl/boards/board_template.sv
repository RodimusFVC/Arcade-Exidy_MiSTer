//============================================================================
//  board_template.sv - start a new Exidy-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/exidy_dispatcher.sv: main 6502 t65_0 (this board's cpu_* ports), sound 6502 t65_1, Z80 z80pa_0, dsnd_0, PIAs
//  pia6821[1:0], pit8253_0, riot6532_0, ptm6840_0, mc3417_0, tms5220rsws_0 (chip_pool_pkg buses), the shared ROM
//  blocks (rom_main, rom_spr, rom_cp0 / rom_cp1, rom_snd, rom_cvsd) and the six board RAM pool blocks
//  (ram_pool_pkg: 0 = 32K, 1 = 16K, 2 / 3 = 8K, 4 = 2K, 5 = 1K; map in the dispatcher's "Shared RAM pool" section).
//  To add the board: copy this file to rtl/boards/<board>/<board>_main.sv, add it to files.qip + verilator/Makefile,
//  instance it in the dispatcher, put it on the variant muxes (m_di / m_irq_n / spr_a, pool_i, any chip bus) and
//  tie the blocks it doesn't use to '0. A RAM bigger than its block = grow the block, never a private dpram_dc.
//  A RAM / chip that truly can't pool = "// POOL-EXCEPTION: <reason>" on its instance line.
//  verilator/common/pool_check.sh (POOL_MODS in verilator/Makefile) enforces it.
//============================================================================

module board_template
(
    input  logic        clk,            // 22.578 MHz
    input  logic        reset,
    input  logic        ce_pix,
    input  logic        cpu_ce,

    // main 6502 (pool slot t65_0, driven through the dispatcher)
    input  logic [15:0] cpu_a,
    input  logic  [7:0] cpu_do,
    input  logic        cpu_rw,
    output logic  [7:0] cpu_di,
    output logic        cpu_irq_n,

    // shared ROM blocks (read ports)
    input  logic  [7:0] rom_d,          // rom_main, addressed by the dispatcher from cpu_a
    output logic [10:0] spr_a,          // rom_spr
    input  logic  [7:0] spr_d,

    // board RAM pool (rtl/ram_pool_pkg.sv)
    output ram_pool_pkg::pram_i_t [5:0] pr_i,
    input  ram_pool_pkg::pram_o_t [5:0] pr_o,

    input  logic  [7:0] in0,
    input  logic  [7:0] dsw,

    output logic  [8:0] pix_x,
    output logic  [8:0] pix_y,
    output logic  [2:0] pix_rgb,
    output logic        vbl_irq_raw
);

endmodule

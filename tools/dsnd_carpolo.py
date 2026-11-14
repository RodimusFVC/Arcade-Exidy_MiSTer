"""Car Polo (Exidy 1977) sound board for the discrete sound engine (tools/dsnd.py, rtl/rodimus/dsnd_engine/dsnd_engine.sv).

MAME has no sound for this game (MACHINE_NO_SOUND; nl_carpolo.cpp is the crash circuit only), so this is traced from
the schematic: Useful Information/schematics/CarPolo.pdf sheets W (PDF p28: ball hit, score), X / Y (p29 / p30: motor,
summing, LM380 amps), Z (p31: noise, 4 crash circuits). References, prototypes and comparison scripts:
verilator/snd/carpolo/ (ngspice decks *_spice.py, float prototype cp_proto.py, *_cmp.py).

Sources (tools/dsnd_boards.py): 0 = {PA7 ball hit, PA5 score (1 idle, 0 = the game's pulse), 0, 0, CRASH P4..P1
(1 = sounding, pulse-extended by the 74161s)}, 1 = {0, 0, speed P2, speed P1}, 2 = {0, 0, speed P4, speed P3} (74173 Q,
before the 7406), 3 = {0000, ACTIVE P4..P1}; 5 = OSD volumes (no music on this board: everything is "effects", Board.vol("E")).

Per player (x4): motor = speed DAC -> LM3900 LPF (0.56 s) -> CV -> three NE566 (4L / 4K / 3L) -> MC3340 (4L + 4K in,
3L on the control pin = AM) -> R87 pot; crash = Targ-type noise burst (envelope C93 gated by the white noise, Q6 stage
as the gen-1 SVF fit); speaker = its own S node (motor, crash, BALL+SCORE bus) unless PLAYER ACTIVE is low (7407
shorts it). Shared: white noise, ball hit (one-shot -> envelope C3 -> Q2 phase-shift oscillator), score (one-shot ->
AN-72 triangle / square, 722 Hz). Stereo: left = P1 + P2 speakers, right = P3 + P4.

Modelling (numbers from the ngspice decks; #unverified = an assumption the scan cannot settle):
- Motor CV (motor_spice.py, MAME's LM3900 transistor model): v1 target = 17.984 - 2.5674 Q (Q = 74173 code), clamped
  0.693 .. 14.36 (output swing), tau R70 C18 = 0.56 s; 15 - CV = 0.4144 + 0.19812 v1 (fit error 0.047 V).
- NE566: f = 2 (15 - CV) / (R C 15), R = 2.2K + pot at mid (2.5K) #unverified; 3L pot taken 0.25K off mid so it does
  not phase-lock to 4K #unverified; triangle 3.0 Vpp (0.2 V+) #unverified. Wrapped 32-bit phase, triangle = |phase|.
- MC3340 (MAME transistor netlist, mc_spice.py): gain 12.84 dB / (1 + e^((ctl - 3.915) / 0.168)) (0.34 dB rms fit), as
  4.39 E / (1 + E), E = 2^(-8.588 (ctl - 3.915)); pin 2 rests at 4.84 V (internal 6.96 V / 4.7K against R85 / R86)
  plus the 3L triangle; input clips at -1.24 V (Q5 off), output at -5.6 / +4.9 V.
- Crash (crash_spice.py, = MAME PLAYER_CRASH): envelope / noise gate as the circuit; Q6 = SVF + slow term fitted to
  the spice collector (q_fit.py: 103.5 Hz, Q 1.08), f0 refit to 90 Hz for the 4-sample round robin it runs in.
- White noise: LFSR -> 2.5 kHz LPF x 30 + 7.5 V clipped 0.2 .. 14 V (the gen-1 stand-in for Q8 / 748 / Q9) #unverified.
- One-shots (os_spice.py + MAME DST_OP_AMP_1SHT): with the drawn R5 / feedback 1M both stages LATCH (set by the input's
  rising edge, reset by its falling edge), which with the game's microsecond pulses would hold the ball tone and the
  score beep on for good. Modelled as timing out with the feedback taken 2.2M (the Midway 1SHT value): ngspice ball
  30 ms, score 1.9 s #unverified. A src0 bit at 0 (re)starts the timer.
- Ball Q2 stage: a self-oscillating phase-shift stage (ngspice 140-190 Hz); behavioural: parabolic sine whose pitch and
  amplitude follow the averaged noise-gate node (ball_cmp.py: env corr 0.94, centroid within 7 Hz).
- Score: square 0.56 / 14.35 V, 722 Hz, duty 0.514 while the one-shot is on (score_spice.py).
- Mix (mix_fit.py, ngspice AC): pots at mid #unverified. With one active player the speaker is
  20.4 x HP 35 Hz x HP 85 Hz (C27 / C29, 470 uF + 470 uF into 8 ohm) x LP 205 Hz of the motor wiper; crash 0.61,
  BALL+SCORE bus: ball 0.14, score 0.014 of that (the shorted S nodes of inactive players load the bus). The bus
  coupling between several active players (shared, brighter sound) is not modelled: exact for one active player.
  LM380 clipping is not modelled (the output is scaled instead).
Rates: per sample = noise, one-shot timers, 4L / 4K triangles + VCA, mix, output high passes; alternate samples =
3L + MC3340 gain (P1 / P2 on even, P3 / P4 on odd) and ball (odd) / score (even); 4-sample round robin = crash and
speed CV of one player per sample.
"""
import math
import dsnd_rate  # noqa: F401,E402  master assembler + this core's FS, before any dsnd import
from dsnd import Board, q, ONE, FS, VBE

DT = 1.0 / FS
VD = 0.6
# ---- noise
N_K = 1.0 - math.exp(-2 * math.pi * 2500.0 / FS)
N_G, N_REST, N_LO, N_HI = 30.0, 7.5, 0.2, 14.0
# ---- crash (cp_proto.CR, f0 refit for the round robin)
CR_VCH, CR_TC, CR_R205, CR_R204, CR_C93, CR_GDIV = 14.4, 1.2e3 * 2.2e-6, 270e3, 100e3, 2.2e-6, 550 / 650
CR_F0, CR_Q, CR_TDC, CR_GLP, CR_GBP, CR_GDC, CR_VQ = 90.0, 1.08, 0.015, 4.9345, 2.2768, -3.3246, 14.2964
# ---- motor (cp_proto.MO)
V1A, V1B, V1LO, V1HI, V1TAU, XA, XB = 17.984, -2.5674, 0.693, 14.36, 0.56, 0.4144, 0.19812
RC4L, RC4K, RC3L = 4.7e3 * 2.2e-6, 4.7e3 * 0.47e-6, 4.95e3 * 0.47e-6
TRI, CTL0, MC_G0, MC_V0, MC_W = 1.5, 4.84, 10 ** (12.84 / 20), 3.915, 0.168
MC_INLO, MC_OUTLO, MC_OUTHI = -1.24, -5.6, 4.9
# ---- ball (cp_proto.BL)
BL_TC, BL_R21, BL_R20, BL_C3, BL_GDIV = 1.2e3 * 2.2e-6, 270e3, 100e3, 2.2e-6, 560 / 660
BL_TAV, BL_TAA, BL_F0, BL_FS, BL_N0, BL_GA, BL_AMAX, BL_VTOP = 0.010, 0.02, 120.0, 10.0, 1.8, 5.0, 7.3, 14.5
T_BALL, T_SCORE = 0.030, 1.9
# ---- score
SC_F, SC_DUTY, SC_HI = 722.0, 0.514, 14.35 - 0.56
# ---- mix (mix_fit.py, one active player)
MX_LP, MX_HP1, MX_HP2 = 205.0, 35.0, 85.0
W_CRASH, W_BALL, W_SCORE = 0.61, 0.14, 0.014
OUT_SCALE = 0.200            # speaker-model volts -> full scale (calibrated on a full-board gameplay run)


def kp(tau, n=1):
    """RC coefficient for a block that runs every n samples"""
    return 1.0 - math.exp(-n * DT / tau)


def round_robin(b, blocks, reg="cp_rr"):
    """blocks[k] runs on samples k, k + n, ...: each block's cost counts once in the worst path"""
    n = len(blocks)
    b.op("LD", reg); b.op("ADDI", imm=ONE); b.op("CMPI", imm=n * ONE); b.op("LDIF", imm=0); b.op("ST", reg)
    ends = []
    for k, f in enumerate(blocks):
        at = None
        if k < n - 1:
            b.op("LD", reg); b.op("CMPI", imm=(k + 1) * ONE)
            at = b.skip_if(True)
        f()
        if k < n - 1:
            ends.append(b.jump())
            b.land(at)
    for e in ends:
        b.land(e)


def alternate(b, block_a, block_b, reg="cp_ph"):
    """block_a on even samples, block_b on odd ones"""
    b.op("LD", reg); b.op("CMPI", imm=q(0.5)); b.op("LDI", imm=ONE); b.op("LDIF", imm=0); b.op("ST", reg)
    at = b.skip_if(True)
    block_a()
    at2 = b.jump()
    b.land(at)
    block_b()
    b.land(at2)


def carpolo():
    b = Board("carpolo")
    P = range(4)

    # ------------------------------------------------ rates (change block: Game Audio cap groups)
    b.kreg("cp_kcc", kp(CR_TC, 4), "T")                       # crash C93 charge (R200 1.2K), round robin
    b.kreg("cp_kc4", -kp(CR_R204 * CR_C93, 4), "T", clamp=False)  # crash C93 -> R204 into the noise gate
    b.kreg("cp_kcf", 2 * math.sin(math.pi * CR_F0 * 4 / FS), "F")   # Q6 bridged-T (C90 / C91)
    b.kreg("cp_kv1", kp(V1TAU, 4), "T")                       # R70 C18
    b.kreg("cp_k4l", 256 * 2 / (RC4L * 15) / FS, "O", clamp=False)   # 566 phase step (256 = 1 cycle) per V (C20)
    b.kreg("cp_k4k", 256 * 2 / (RC4K * 15) / FS, "O", clamp=False)   # C22
    b.kreg("cp_k3l", 256 * 2 * 2 / (RC3L * 15) / FS, "O", clamp=False)   # C24, alternate samples
    b.kreg("cp_kdec", DT, "T", clamp=False)                   # one-shot timers (C1 / C11)
    b.kreg("cp_kbc", kp(BL_TC, 2), "T")                       # ball C3 charge, alternate samples
    b.kreg("cp_kb0", -kp(BL_R20 * BL_C3, 2), "T", clamp=False)
    b.kreg("cp_kbw", 256 * BL_FS * 2 / FS, "O", clamp=False)  # ball pitch (C4-C6): phase step per volt
    b.kreg("cp_kbw0", 256 * BL_F0 * 2 / FS, "O", clamp=False)
    b.kreg("cp_ksc", 256 * SC_F * 2 / FS, "O", clamp=False)   # score (C8), alternate samples
    b.kreg("cp_kmx", kp(1 / (2 * math.pi * MX_LP)), "F")      # speaker LP (C30 / bus)
    b.kreg("cp_kh1", kp(1 / (2 * math.pi * MX_HP1)), "F")     # C27 / C29
    b.kreg("cp_kh2", kp(1 / (2 * math.pi * MX_HP2)), "F")     # C33 / C34 470 uF into the speaker
    b.init("cp_sph", -128.0)

    # ------------------------------------------------ white noise (Q9 collector) + the gate diode: wnd = noise + VD
    b.op("NOISE", 0, 0)
    b.op("LDI", imm=q(-1.0)); b.op("LDIF", imm=q(1.0))
    b.op("RC", "cp_nlp", imm=q(N_K))
    b.op("MULI", imm=q(N_G)); b.op("ADDI", imm=q(N_REST + VD))
    b.op("MAXI", imm=q(N_LO + VD)); b.op("MINI", imm=q(N_HI + VD))
    b.op("ST", "cp_wnd")

    # ------------------------------------------------ one-shot timers (every sample: a pulse may last one sample)
    for t, bit, tos in (("cp_tb", 7, T_BALL), ("cp_ts", 6, T_SCORE)):
        b.op("LD", t); b.op("SUB", "cp_kdec"); b.op("MAXI", imm=0); b.op("ST", t)
        b.op("BIT", 1, b.src(0, bit))                          # F = input low (the game's pulse)
        b.op("LDI", imm=q(tos)); b.op("STF", t)

    # ------------------------------------------------ round robin: crash + speed CV of player p
    def slot(p):
        def f():
            e, n, lp, bp, dc = (f"cp_ce{p}", f"cp_cn{p}", f"cp_cl{p}", f"cp_cb{p}", f"cp_cd{p}")
            # envelope: C93 charges through R200 / CR11 while CRASH, R205 / R204 discharge
            b.op("BIT", 0, b.src(0, p))
            b.op("LD", e); b.op("LDIF", imm=q(CR_VCH)); b.op("RCM", e, b.r("cp_kcc"))
            b.op("MULI", imm=q(CR_GDIV)); b.op("ADDI", imm=q(VBE * (1 - CR_GDIV)))   # R204 / R203 to the base
            b.op("CMP", "cp_wnd"); b.op("LDF", "cp_wnd"); b.op("ST", n)              # CR10 to the noise
            b.op("LD", e); b.op("SUB", n); b.op("MAXI", imm=0); b.op("MUL", "cp_kc4")
            b.op("MACI", e, imm=q(1 - 4 * DT / (CR_R205 * CR_C93))); b.op("ST", e)
            # Q6 stage: SVF (Chamberlin) + slow term, collector clamped (the CR14 output node tops at 10.2 V)
            b.op("LD", bp); b.op("MUL", "cp_kcf"); b.op("ADD", lp); b.op("ST", lp)
            b.op("LD", n); b.op("ADDI", imm=q(-VBE)); b.op("ST", "cp_cx")
            b.op("SUB", lp); b.op("MACI", bp, imm=q(-1 / CR_Q)); b.op("MUL", "cp_kcf"); b.op("ADD", bp)
            b.op("ST", bp)
            b.op("LD", "cp_cx"); b.op("RC", dc, imm=q(kp(CR_TDC, 4)))
            b.op("MULI", imm=q(-CR_GDC)); b.op("MACI", lp, imm=q(-CR_GLP)); b.op("MACI", bp, imm=q(-CR_GBP))
            b.op("ADDI", imm=q(CR_VQ)); b.op("MAXI", imm=q(0.1)); b.op("MINI", imm=q(10.2 - VD))
            b.op("ST", f"cp_cc{p}")
            # speed latch -> v1 (LM3900 LPF) -> 15 - CV -> 566 phase steps
            src, mask, sh = (1, 0x07, 21) if p == 0 else (1, 0x38, 18) if p == 1 else (2, 0x07, 21) if p == 2 \
                else (2, 0x38, 18)
            b.op("LDLM", 0, b.src(src, 0), imm=mask | (sh << 8))                    # Q / 8
            b.op("MULI", imm=q(V1B * 8)); b.op("ADDI", imm=q(V1A)); b.op("MAXI", imm=q(V1LO))
            b.op("RCM", f"cp_v{p}", b.r("cp_kv1")); b.op("MINI", imm=q(V1HI)); b.op("ST", f"cp_v{p}")
            b.op("MULI", imm=q(XB)); b.op("ADDI", imm=q(XA)); b.op("ST", "cp_x")
            for k in ("4l", "4k", "3l"):
                b.op("LD", "cp_x"); b.op("MUL", f"cp_k{k}"); b.op("ST", f"cp_s{k}{p}")
        return f
    round_robin(b, [slot(p) for p in P])

    # ------------------------------------------------ motors: 4L + 4K triangles -> MC3340 input, VCA (every sample)
    for p in P:
        b.op("LD", f"cp_p4l{p}"); b.op("ADD", f"cp_s4l{p}"); b.op("ST", f"cp_p4l{p}"); b.op("ABS")
        b.op("MULI", imm=q(TRI / 128)); b.op("ST", "cp_t")
        b.op("LD", f"cp_p4k{p}"); b.op("ADD", f"cp_s4k{p}"); b.op("ST", f"cp_p4k{p}"); b.op("ABS")
        b.op("MULI", imm=q(TRI / 128)); b.op("ADD", "cp_t"); b.op("ADDI", imm=q(-TRI)); b.op("MAXI", imm=q(MC_INLO))
        b.op("MUL", f"cp_g{p}"); b.op("MAXI", imm=q(MC_OUTLO)); b.op("MINI", imm=q(MC_OUTHI)); b.op("ST", f"cp_y{p}")

    # ------------------------------------------------ alternate samples: MC3340 control (3L) + gain, ball / score
    def gain(p):
        b.op("LD", f"cp_p3l{p}"); b.op("ADD", f"cp_s3l{p}"); b.op("ST", f"cp_p3l{p}"); b.op("ABS")
        b.op("MULI", imm=q(2 * TRI / 128)); b.op("ADDI", imm=q(CTL0 - TRI - MC_V0))    # ctl - v0
        b.op("MULI", imm=q(-1.0 / (MC_W * math.log(2)))); b.op("EXP"); b.op("ST", "cp_e")
        b.op("ADDI", imm=ONE); b.op("RCP"); b.op("MUL", "cp_e"); b.op("MULI", imm=q(MC_G0)); b.op("ST", f"cp_g{p}")

    def score():
        b.op("LD", "cp_ts"); b.op("CMPI", imm=1)              # F = one-shot on
        b.op("LD", "cp_sph"); b.op("ADD", "cp_ksc"); b.op("ST", "cp_sph")
        b.op("LDI", imm=-(1 << 31)); b.op("STNF", "cp_sph")   # off: held at the start of the low phase
        b.op("LD", "cp_sph"); b.op("CMPI", imm=q(128.0 - SC_DUTY * 256))
        b.op("LDI", imm=0); b.op("LDIF", imm=q(SC_HI)); b.op("ST", "cp_sq")

    def ball():
        b.op("LD", "cp_tb"); b.op("CMPI", imm=1)              # F = one-shot on: Q1 / 7407 let R17 charge C3
        b.op("LD", "cp_be"); b.op("LDIF", imm=q(CR_VCH)); b.op("RCM", "cp_be", b.r("cp_kbc"))
        b.op("MULI", imm=q(BL_GDIV)); b.op("ADDI", imm=q(VBE * (1 - BL_GDIV)))
        b.op("CMP", "cp_wnd"); b.op("LDF", "cp_wnd"); b.op("ST", "cp_bn")          # CR3 to the noise
        b.op("LD", "cp_be"); b.op("SUB", "cp_bn"); b.op("MAXI", imm=0); b.op("MUL", "cp_kb0")
        b.op("MACI", "cp_be", imm=q(1 - 2 * DT / (BL_R21 * BL_C3))); b.op("ST", "cp_be")
        b.op("LD", "cp_bn"); b.op("RC", "cp_bv", imm=q(kp(BL_TAV, 2)))            # averaged gate node
        b.op("ST", "cp_t"); b.op("MUL", "cp_kbw"); b.op("ADD", "cp_kbw0")           # pitch: phase step
        b.op("ADD", "cp_bph"); b.op("ST", "cp_bph")
        b.op("MULI", imm=q(1 / 128)); b.op("ST", "cp_bx"); b.op("ABS"); b.op("MULI", imm=q(-1)); b.op("ADDI", imm=ONE)
        b.op("MUL", "cp_bx"); b.op("MULI", imm=q(4.0)); b.op("ADDI", imm=ONE); b.op("ST", "cp_bx")   # 1 + sin
        b.op("LD", "cp_t"); b.op("ADDI", imm=q(-BL_N0)); b.op("MULI", imm=q(BL_GA)); b.op("MAXI", imm=0)
        b.op("MINI", imm=q(BL_AMAX)); b.op("RC", "cp_ba", imm=q(kp(BL_TAA, 2)))       # amplitude
        b.op("MUL", "cp_bx"); b.op("MULI", imm=q(-1)); b.op("ADDI", imm=q(BL_VTOP))
        b.op("MAXI", imm=q(0.1)); b.op("MINI", imm=q(10.2 - VD)); b.op("ST", "cp_bc")

    alternate(b, lambda: (gain(0), gain(1), score()), lambda: (gain(2), gain(3), ball()))

    # ------------------------------------------------ BALL+SCORE bus and the four speakers
    b.op("LD", "cp_bc"); b.op("MULI", imm=q(W_BALL / 2)); b.op("MACI", "cp_sq", imm=q(W_SCORE / 2))
    b.op("ADDI", imm=q(-W_BALL / 2 * (10.2 - VD))); b.op("ST", "cp_wb")
    for side, pl in ((False, (0, 1)), (True, (2, 3))):
        for j, p in enumerate(pl):
            b.op("BIT", 1, b.src(3, p))                        # F = player inactive: 7407 shorts the S node
            b.op("LD", f"cp_y{p}"); b.op("MULI", imm=q(0.5))  # R87 wiper (mid)
            b.op("MACI", f"cp_cc{p}", imm=q(W_CRASH / 2)); b.op("ADD", "cp_wb")
            b.op("ADDI", imm=q(-W_CRASH / 2 * (10.2 - VD)))
            b.op("LDIF", imm=0)
            b.op("RCM", f"cp_m{p}", b.r("cp_kmx"))
            if j == 0:
                b.op("ST", "cp_t")
            else:
                b.op("ADD", "cp_t")
        o = "r" if side else "l"
        b.op("ST", "cp_t")                                     # two high passes: x - LP(x)
        b.op("RCM", f"cp_h1{o}", b.r("cp_kh1")); b.op("MULI", imm=q(-1)); b.op("ADD", "cp_t"); b.op("ST", "cp_t")
        b.op("RCM", f"cp_h2{o}", b.r("cp_kh2")); b.op("MULI", imm=q(-1)); b.op("ADD", "cp_t")
        b.op("MULI", imm=q(OUT_SCALE))
        b.vol("E")
        b.op("OUTR" if side else "OUT")
    return b.finish()


if __name__ == "__main__":
    p = carpolo()
    print(f"carpolo words {len(p.code)} worst units {p.worst_path()} registers {len(p.regs)}")

"""Exidy Star Fire (mono) and Fire One (stereo) discrete audio as sound engine programs (rtl/rodimus/dsnd_engine/dsnd_engine.sv).

Primary reference: rtl/boards/exidy_starfire/starfire_snd.sv (runs on HW; circuits from MAME exidy/nl_starfire.cpp /
nl_fireone.cpp, which were transcribed from the manual schematics; constants verilator/starfiresnd/gen_consts.py).
Every RTL node is re-derived for FS = 27137 Hz (RTL: 88.2 kHz). Comparison scripts: verilator/snd/starfire/.

Sources (tools/dsnd_boards.py): 0 = Star Fire latch / Fire One offset-0 latch, 1 = Fire One offset-1 latch,
2 / 3 / 4 = Fire One 8253 OUT0 / OUT1 / OUT2 box averages (Z80 enables high in the sample, N_CE = 92.1 per sample),
5 = OSD volumes: Fire One 8253 music x _fM, everything else x _fE. Star Fire's TIE ON / LASER ON status bits stay in the
RTL module (it keeps running alongside), so the program only makes the audio.
Latches: Star Fire D0 SIZE, D1 EXPLOSION, D2 TIE, D3 LASER, D4 TRACK, D5 LOCK, D6 SCANNER, D7 OVERHEAT.
  Fire One offset 0: D0 L TORP, D1 L PARTIAL HIT, D2 L BOOM, D3 player select, D4-D6 8253 GATE0-2, D7 SOUND OFF;
  offset 1: D0 R TORP, D1 R PARTIAL HIT, D2 R BOOM, D3 TORP COLLISION, D4 SUB ENGINE, D5 ALERT, D6 SONAR SYNC,
  D7 noise clock enable.

Modelling choices vs the RTL (each one flagged):
  - exact one-pole coefficients 1 - exp(-dt / tau) everywhere (the RTL used dt / tau for a few slow nodes);
  - 555 / 556 threshold crossings: the overshoot continues on the other branch scaled by the slope ratio at the
    threshold (the RTL reflected it 1:1, which lengthens the period by ~0.5 sample: 2.8 % at 27 kHz for the
    scanner); a cap already more than ~1 step past the threshold (release from RESET, CV jump) switches without the
    jump, as a real 555 does (the RTL's reflection put the cap near the other threshold, so the first period after a
    RESET release was short);
  - square outputs that reach the mix (scanner, tracking computer, sub engine B, alert flip-flop) are box-averaged over
    the crossing sample (anti-aliasing at 27 kHz);
  - noise: the engine's 31-bit LFSR clocked at the 556 / 1 kHz rate instead of the CD4006 17-stage register (same
    white binary spectrum; the sequence and Fire One's SONAR SYNC feedback inversion are not reproduced);
  - MC3340 gain 1 / (1 + 2^z) computed exactly (EXP / RCP) instead of the RTL's 1/32-octave table;
  - Fire One slow nodes (torpedo / hit / collision envelopes and integrator, sub-engine LFO, alert ramp, sonar
    timing) run in a 6-sample round robin (4.5 kHz) with their coefficients re-derived for that step.
Game Audio groups: T = envelope / ramp / hold caps, F = coupling and filter caps, O = oscillator caps.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dsnd_rate  # noqa: F401,E402  master assembler + this core's FS, before any dsnd import
from dsnd import Board, FS, ONE, q  # noqa: E402

DT = 1.0 / FS
HALF = q(0.5)
L0, L1, P0, P1, P2 = 0, 1, 2, 3, 4
N_CE = 832 * 2.5e6 / 22.578e6                   # Z80 enables per engine sample (box-average full scale)
RR = 6                                          # Fire One round robin length
DT_RR = RR * DT


def kx(tau, dt=DT):
    return 1.0 - math.exp(-dt / tau)


def par(*r):
    return 1.0 / sum(1.0 / x for x in r)


# ---------------------------------------------------------------- constants (gen_consts.py, re-derived for FS)
# MC3340 (MAME transistor model measured with nltool): gain G / (1 + exp((Vc - 3.124) / 0.1625)), control =
# (C + 5) / 2, input 17.7K, inverting, internal roll-off 263 Hz
V0MC, VTMC = 3.124, 0.1625
ZOFF = 2 * V0MC - 5.0
ZK = math.log2(math.e) / (2 * VTMC)            # octaves per volt of the envelope cap
TAU_MC = 1 / (2 * math.pi * 263)
ZIN = 17.7e3
DIV = 0.5 * ZIN / (50e3 + ZIN)
G_SE, G_FB, G_SH = 4.0, 4.3, 4.37
VOPCL = 10.4
# rumble Sallen-Key 16K / 16K, 0.1u / 0.1u, K 2.6 (Star Fire 6D_C; Fire One IC17 identical)
SK_F0, SK_QD, SK_K = 1 / (2 * math.pi * 16e3 * 0.1e-6), 0.4, 2.6
# Star Fire
I45 = (12 - (12 * 10 / 14.7 + 0.65)) / 1e6     # Q2 current source into C45 4.7u
VT45 = 1.541
VSZ, VSZT = 3.77, 5 * 2.2 / 5.5
IL = (12 - (12 * 10 / 14.7 + 0.65)) / 470e3     # Q1 into C32 1u
_RB = par(10e3, 3e3)
ILS = (12 - (12 * _RB / (4.7e3 + _RB) + 0.65)) / 470e3
VT32 = 1.541
KL0 = (12 - 3.951) / (22e3 * 0.01e-6)          # 8038 6F slope V/s: (12 - V8) / RC, V8 = 4.029 V32 + 3.951
KL8 = -4.029 / (22e3 * 0.01e-6)
TRI = 4.0
VOH5, VS11 = 3.3, 3.3 / 11
GT = 4.7e3 / 50.5e3
GL = -0.303 * 4.7e3 / 50.5e3
GS = 4.7e3 / (16.5e3 + 0.5e3)
GE = -4.7e3 / 5e3 * G_SE * DIV
GC = 1e3 / 5.7e3 * 4.7e3 / (50.5e3 + par(4.7e3, 1e3))
GH = -4.7e3 / 50e3 * G_SH * 0.951
CLE_S = 3.2 / (G_SE * DIV)
CLH_S = 3.2 / (G_SH * 0.951)
CLB_F = 3.2 / (G_FB * DIV)
KSF = 8000.0                                    # Star Fire counts per volt at the output (RTL OSF)
# Fire One
NINC_F = 1000.0                                 # HLE_SONAR_CLOCK 1 kHz (MAME) #unverified
GFI = -27e3 / 100e3
VLM, VCH, VOHI = 0.5, 5.0 - 0.6, 10.8
K034 = 680e3 / 2e6
VIB = (12 - 0.5) / 5.6e6 * 680e3
TAU_INT = 680e3 * 1e-6
NLO, NHI = 12 - 12 * 10e3 / 13e3, 12.0
GTG = 1.2e6 / 680e3
VGT_L, VGT_H = 0.5 - 1.2e6 * (NLO - 0.5) / 820e3, 0.5 - 1.2e6 * (NHI - 0.5) / 820e3
VGP_L, VGP_H = 0.5 - 1.2e6 * (NLO - 0.5) / 560e3, 0.5 - 1.2e6 * (NHI - 0.5) / 560e3
GCG = 820e3 / 220e3
VGC_L, VGC_H = 0.5 - 820e3 * (NLO - 0.5) / 620e3, 0.5 - 820e3 * (NHI - 0.5) / 620e3
_RA, _RBS = 5.6e3, 2.7e3
_RCV, _VCV = par(5e3, 10e3), 10 / 3
VAC = (5 / (_RA + _RBS) + _VCV / _RCV) / (1 / (_RA + _RBS) + 1 / _RCV)
TAC = par(_RA + _RBS, _RCV) * 2.2e-6
VAD = (_VCV / _RCV) / (1 / _RBS + 1 / _RCV)
TAD = par(_RBS, _RCV) * 2.2e-6
TBC, TBD = 15e3 * 0.1e-6, 8.2e3 * 0.1e-6       # sub engine B: R126 + R127 / R127, C84
V8I, V8M = 11.6, 8.1
SP8 = ((12 * 10 / 13.9) - 0.65) / 1e6 / 1e-6   # alert ramp V/s (Q1 sink into C41 1u)
RA38 = 43e3 * 4.7e-9                            # alert 8038 R59 / R60 43K, C44 4.7n
V100 = 12 * 5.6e3 / (47e3 + 5.6e3)
F2, QD2 = 760.0, 1 / 12.0                       # sonar MFB band-pass (nltool f0, Q 12) #unverified (RTL)
LOSS = 3.9
GN100 = 820e3 / (2 * 5.6e3) / LOSS * 0.77
_GD = 820e3 / (2 * 150e3) / LOSS
VDK = {c: 12 * 150e3 / (150e3 + r) * _GD for c, r in ((1, 15e3), (2, 68e3), (4, 47e3), (9, 120e3))}
GTC = 68e3 / 33e3 * 33e3 / 2 / (33e3 / 2 + 7.8e3)
GSE = 68e3 / 130e3 * 65e3 / (65e3 + 6e3)
GSON = 68e3 / 270e3
GAL = 68e3 / 560e3
GBM = -68e3 / 20e3 * G_FB * DIV
GSH = 68e3 / 150e3 * 150e3 / 174e3
GTP = 68e3 / 560e3
GMU = 4.95 * 68e3 / 560e3
RPL = par(20e3, 33e3, 150e3, 150e3, 130e3, 270e3, *([560e3] * 5))
RPR = par(20e3, 33e3, 130e3, 270e3, *([560e3] * 5))
VBF = 0.5 + 68e3 * (11.9 - 0.5) / 130e3
VMX = 11.6
OFO = 0.0287 * 100000 / 1.16                    # Fire One counts per volt at the output (RTL OFO)


# ---------------------------------------------------------------- helpers
def vol(b, g):
    """acc *= OSD volume g ("M" / "E"): level / 8. Same as dsnd.Board.gain(g), which tools/dsnd.py shadows with the
    DST_GAIN node method Board.gain(out, src, k)"""
    b.vols.add(g)
    b.op("MUL", "_f" + g)


def fac(b, g):
    """acc *= Game Audio group factor g"""
    b.groups.add(g)
    b.op("MUL", "_f" + g)


def lbit(b, src, bit):
    """acc = source bit as 0 / 1.0"""
    b.op("LDLM", 0, b.src(src, bit), imm=(1 << bit) | ((24 - bit) << 8))


def rcm(b, reg, k):
    """acc = target: reg relaxes toward it with the rate in register k; acc = reg"""
    b.op("RCM", reg, b.r(k))


def clampv(b, lo, hi):
    b.op("MAXI", imm=q(lo))
    b.op("MINI", imm=q(hi))


def round_robin(b, name, blocks):
    """blocks[k] runs on samples k, k + n, ...: each block counts once in the worst path"""
    n = len(blocks)
    b.op("LD", name); b.op("ADDI", imm=ONE); b.op("CMPI", imm=n * ONE); b.op("LDIF", imm=0); b.op("ST", name)
    ends = []
    for k, f in enumerate(blocks):
        at = None
        if k < n - 1:
            b.op("LD", name); b.op("CMPI", imm=(k + 1) * ONE)
            at = b.skip_if(True)
        f()
        if k < n - 1:
            ends.append(b.jump())
            b.land(at)
    for e in ends:
        b.land(e)


def oneshot_ramp(b, p, src, bit, kreg, vt):
    """556 one-shot set by the latch bit's rising edge (RESET and TRIGGER rise together), reset while the bit is low,
    timed out when the current-source ramp p+'v' (slope register kreg, volts per sample) reaches vt; p+'q' = output"""
    qq, d, v, t = p + "q", p + "d", p + "v", p + "t"
    b.op("LD", qq); b.op("CMPI", imm=HALF); b.op("NOT")
    b.op("LD", v); b.op("ADD", kreg); b.op("LDIF", imm=0); b.op("ST", v)            # v = q ? v + k : 0
    b.op("CMPI", imm=q(vt)); b.op("LDI", imm=0); b.op("STF", qq)                     # threshold: q = 0
    lbit(b, src, bit); b.op("ST", t); b.op("SUB", d); b.op("CMPI", imm=HALF)        # rising edge: q = 1
    b.op("LDI", imm=ONE); b.op("STF", qq)
    b.op("LD", t); b.op("ST", d)
    b.op("BIT", 1, b.src(src, bit)); b.op("LDI", imm=0); b.op("STF", qq)            # RESET low: q = 0


def osc555(b, p, Vc, tc, Vd, td, th, tl, g="O", en=None, lvl=None, chg=None, dt=DT, mk=True, on_set=None):
    """555 / 556 astable: timing cap p+'c' charges toward Vc (tau tc) while charging, else discharges toward Vd (tau td);
    output p+'q' = 1.0 while high; thresholds th / tl. en = (src, bit): low = RESET (q forced 0, the cap keeps
    discharging, no set). chg: callable leaving F = charging (default F = q). A crossing inside the step continues
    the overshoot on the other branch scaled by the slope ratio at the threshold; a cap more than 1.5 steps past the
    threshold (RESET release, threshold jump) switches without moving. lvl: p+'o' = box average of q x lvl over the
    step (crossing fraction = overshoot / step at the threshold). on_set: callable emitted when q goes high"""
    kc, kd = kx(tc, dt), kx(td, dt)
    s_ct, s_dt = (Vc - th) * kc, (Vd - th) * kd    # steps at th (s_dt < 0)
    s_cb, s_db = (Vc - tl) * kc, (Vd - tl) * kd    # steps at tl
    if mk:
        b.kreg(p + "kc", kc, g, clamp=False)
        b.kreg(p + "kd", kd, g, clamp=False)
    c, qq, t = p + "c", p + "q", p + "t"
    if en:
        b.op("BIT", 1, b.src(*en)); b.op("LDI", imm=0); b.op("STF", qq)
    if chg:
        chg()
    else:
        b.op("LD", qq); b.op("CMPI", imm=HALF)
    at = b.skip_if(False)
    # charging
    b.op("LDI", imm=q(Vc)); rcm(b, c, p + "kc")
    b.op("CMPI", imm=q(th)); a1 = b.skip_if(False)
    b.op("ADDI", imm=q(-th)); b.op("ST", t)
    b.op("CMPI", imm=q(1.5 * s_ct)); a5 = b.skip_if(True)
    b.op("MULI", imm=q(s_dt / s_ct)); b.op("ADDI", imm=q(th)); b.op("ST", c)
    b.land(a5)
    b.op("LDI", imm=0); b.op("ST", qq)
    if lvl is not None:
        b.op("LD", t); b.op("MULI", imm=q(-lvl / s_ct)); b.op("ADDI", imm=q(lvl)); b.op("MAXI", imm=0)
        b.op("ST", p + "o")
    j1 = b.jump()
    b.land(at)
    # discharging
    b.op("LDI", imm=q(Vd)); rcm(b, c, p + "kd")
    b.op("CMPI", imm=q(tl)); a2 = b.skip_if(True)
    a3 = a4 = None
    if chg:                                        # high but not charging (scanner while LOCK is low): no set
        b.op("LD", qq); b.op("CMPI", imm=HALF); a3 = b.skip_if(True)
        b.op("LD", c)
    if en:
        b.op("BIT", 0, b.src(*en)); a4 = b.skip_if(False)
    b.op("ADDI", imm=q(-tl)); b.op("ST", t)
    b.op("CMPI", imm=q(1.5 * s_db)); a6 = b.skip_if(False)
    b.op("MULI", imm=q(s_cb / s_db)); b.op("ADDI", imm=q(tl)); b.op("ST", c)
    b.land(a6)
    b.op("LDI", imm=ONE); b.op("ST", qq)
    if on_set:
        on_set()
    if lvl is not None:
        b.op("LD", t); b.op("MULI", imm=q(lvl / s_db)); b.op("MINI", imm=q(lvl)); b.op("ST", p + "o")
    j2 = b.jump()
    for a in (a1, a2, a3, a4):
        if a is not None:
            b.land(a)
    if lvl is not None:
        b.op("LD", qq); b.op("MULI", imm=q(lvl)); b.op("ST", p + "o")
    b.land(j1)
    b.land(j2)


def triangle(b, p, lo, hi, step_code):
    """8038 triangle p+'x' between lo and hi; step_code leaves acc = slope (volts per sample, > 0); direction p+'d'
    = +-1.0, the overshoot is reflected (equal slopes). Returns (reg of the bottom-turn skip, ...) via hooks"""
    step_code()
    b.op("MUL", p + "d"); b.op("ADD", p + "x")
    b.op("CMPI", imm=q(hi)); a = b.skip_if(False)
    b.op("MULI", imm=-ONE); b.op("ADDI", imm=q(2 * hi)); b.op("ST", p + "x")
    b.op("LDI", imm=-ONE); b.op("ST", p + "d")
    j1 = b.jump()
    b.land(a)
    b.op("CMPI", imm=q(lo)); a2 = b.skip_if(True)
    b.op("MULI", imm=-ONE); b.op("ADDI", imm=q(2 * lo)); b.op("ST", p + "x")
    b.op("LDI", imm=ONE); b.op("ST", p + "d")
    return j1, a2


def mc3340(b, p, trg, tau_d, tau_c, inp, clv, y=None):
    """MC3340 attenuator: envelope cap p+'e' (trg high: discharge toward 0, tau_d; else charge toward 5 V, tau_c;
    group T; stored as p+'e' = 5 V - cap, 0 at rest), gain 1 / (1 + 2^z), z = (cap - ZOFF) ZK; input inp low-passed at 263 Hz (p+'y', or a shared y);
    p+'o' = clamp(y x gain, +-clv)"""
    b.kreg(p + "kd", kx(tau_d), "T", clamp=False)
    b.kreg(p + "kc", kx(tau_c), "T", clamp=False)
    b.op("BIT", 0, b.src(*trg)); b.op("LD", p + "kc"); b.op("LDF", p + "kd"); b.op("ST", p + "k")
    b.op("LDI", imm=0); b.op("LDIF", imm=q(5.0)); rcm(b, p + "e", p + "k")
    b.op("ADDI", imm=q(-(5.0 - ZOFF))); b.op("MULI", imm=q(-ZK)); b.op("ST", p + "z")
    b.op("ABS"); b.op("MULI", imm=-ONE); b.op("EXP"); b.op("ST", p + "w")          # w = 2^-|z|
    b.op("ADDI", imm=ONE); b.op("RCP"); b.op("ST", p + "g")                         # 1 / (1 + w)
    b.op("LD", p + "z"); b.op("CMPI", imm=0); b.op("LD", p + "w"); b.op("MUL", p + "g"); b.op("STF", p + "g")
    if y is None:
        b.kreg(p + "ky", kx(TAU_MC), "F", clamp=False)
        b.op("LD", inp); rcm(b, p + "y", p + "ky")
        y = p + "y"
    else:
        b.op("LD", y)
    b.op("MUL", p + "g"); clampv(b, -clv, clv); b.op("ST", p + "o")


def rumble(b, p, inp):  # registers p_lp, p_bp, p_rum, p_svf
    """Sallen-Key 99.5 Hz Q 2.5 gain 2.6 (Chamberlin state variable form, group F): p+'rum' = clamp(2.6 lp)"""
    p = p + "_"
    b.kreg(p + "svf", 2 * math.sin(math.pi * SK_F0 / FS), "F", clamp=False)
    b.op("LD", p + "bp"); b.op("MUL", p + "svf"); b.op("ADD", p + "lp"); b.op("ST", p + "lp")
    b.op("LD", inp); b.op("SUB", p + "lp"); b.op("MACI", p + "bp", imm=q(-SK_QD))
    b.op("MUL", p + "svf"); b.op("ADD", p + "bp"); b.op("ST", p + "bp")
    b.op("LD", p + "lp"); b.op("MULI", imm=q(SK_K)); clampv(b, -VOPCL, VOPCL); b.op("ST", p + "rum")


def noise_clock(b, p, step_code, en=None):
    """noise flip-flop p+'na' (0 / 1.0): the engine LFSR steps once per oscillator cycle (phase p+'ph' += step)"""
    a0 = None
    if en:
        b.op("BIT", 1, b.src(*en)); a0 = b.skip_if(True)
    step_code()
    b.op("ADD", p + "ph"); b.op("CMPI", imm=ONE); a = b.skip_if(False)
    b.op("ADDI", imm=-ONE); b.op("ST", p + "ph")
    b.op("NOISE", 0, 0); b.op("LDI", imm=0); b.op("LDIF", imm=ONE); b.op("ST", p + "na")
    j = b.jump()
    b.land(a)
    b.op("ST", p + "ph")
    b.land(j)
    if a0 is not None:
        b.land(a0)


def probe_out(b, reg, scale, right=False):
    b.op("LD", reg); b.op("MULI", imm=q(scale)); b.op("OUTR" if right else "OUT")


# ---------------------------------------------------------------- Star Fire
def starfire(probe=None):
    b = Board("starfire")
    S = L0
    SIZE, EXPLO, TIE, LASER, TRACK, LOCK, SCAN, OHEAT = range(8)
    b.init("sflsd", 1.0)                            # 8038 direction up
    # TIE: Q2 ramps C45 4.7u; 556 8F-A one-shot until 8D_D crosses the 8F-A threshold (V45 = 1.541)
    b.kreg("sf_k45", I45 / 4.7e-6 * DT, "T", clamp=False)
    oneshot_ramp(b, "sft", S, TIE, "sf_k45", VT45)
    # noise clock 556 8F-B (R86 1K, R87 2K, C38 0.1u, 12 V), CV = 8D_D out: cubic fit of f(V45) / FS (as the RTL)
    import numpy as np
    vs = np.linspace(0, 1.55, 200)
    f556 = lambda cv: 1 / (3e3 * 0.1e-6 * math.log((12 - cv / 2) / (12 - cv)) + 2e3 * 0.1e-6 * math.log(2))
    pc = np.polyfit(vs, np.array([f556(4.029 * x + 3.951) for x in vs]) / FS, 3)

    def nstep():
        b.op("LD", "sftv"); b.op("MULI", imm=q(pc[0])); b.op("ADDI", imm=q(pc[1])); b.op("MUL", "sftv")
        b.op("ADDI", imm=q(pc[2])); b.op("MUL", "sftv"); b.op("ADDI", imm=q(pc[3])); fac(b, "O")
    noise_clock(b, "sfn", nstep)
    # noise node: 4006 out (12 V; SIZE: 6 V via R56 / R73) into C29 0.1u / R74 100K, 8D_A gain -R75 / (R + R74)
    b.kreg("sf_k29", kx(104.7e3 * 0.1e-6), "F", clamp=False)
    b.kreg("sf_k29s", kx(102.35e3 * 0.1e-6), "F", clamp=False)
    b.op("BIT", 0, b.src(S, SIZE)); b.op("LD", "sf_k29"); b.op("LDF", "sf_k29s"); b.op("ST", "sf_kn")
    b.op("LDI", imm=q(12.0)); b.op("LDIF", imm=q(6.0)); b.op("MUL", "sfnna"); b.op("ST", "sf_vs")
    rcm(b, "sf_c29", "sf_kn"); b.op("MULI", imm=-ONE); b.op("ADD", "sf_vs"); b.op("ST", "sf_t")
    b.op("BIT", 0, b.src(S, SIZE)); b.op("LDI", imm=q(-27e3 / 104.7e3)); b.op("LDIF", imm=q(-27e3 / 102.35e3))
    b.op("MUL", "sf_t"); b.op("ST", "sf_nsf")
    rumble(b, "sf", "sf_nsf")
    # SIZE hold: R42 1K + D3 into C18 1u, R43 1M; SIZE ON while C18 > 2 V
    b.kreg("sf_k18c", kx(1e3 * 1e-6), "T", clamp=False)
    b.kreg("sf_k18d", kx(1e6 * 1e-6), "T", clamp=False)
    b.op("BIT", 0, b.src(S, SIZE)); b.op("LD", "sf_k18d"); b.op("LDF", "sf_k18c"); b.op("ST", "sf_k18")
    b.op("LDI", imm=0); b.op("LDIF", imm=q(VSZ)); rcm(b, "sf_c18", "sf_k18")
    # explosion: MC3340 7D on RUMBLE 1, envelope C27 (R40 2.7K discharge, R62 + R63 2M charge)
    mc3340(b, "sf1", (S, EXPLO), 2.7e3 * 1e-6, 2e6 * 1e-6, "sf_rum", CLE_S)
    # laser: Q1 ramps C32 1u (faster with SIZE); 556 6E one-shot; ICL8038 6F triangle +-4 V swept by 6D_D
    b.kreg("sf_k32", IL / 1e-6 * DT, "T", clamp=False)
    b.kreg("sf_k32s", ILS / 1e-6 * DT, "T", clamp=False)
    b.op("BIT", 0, b.src(S, SIZE)); b.op("LD", "sf_k32"); b.op("LDF", "sf_k32s"); b.op("ST", "sf_k3")
    oneshot_ramp(b, "sfl", S, LASER, "sf_k3", VT32)

    def lstep():
        b.op("LD", "sflv"); b.op("MULI", imm=q(KL8 * DT)); b.op("ADDI", imm=q(KL0 * DT)); fac(b, "O")
    j1, a2 = triangle(b, "sfls", -TRI, TRI, lstep)
    j2 = b.jump()
    b.land(a2)
    b.op("ST", "sflsx")
    b.land(j1)
    b.land(j2)
    # tracking computer: 556 6A-A LOCK (R13 / R14 470K, C7 0.1u), 555 5B SCANNER (R24 470, R23 47K, C15 0.01u,
    # charges only while node N is high = LOCK out & SCANNER out & SCANNER), 556 6A-B TRACK (R27 / R28 30K, C12
    # 0.01u, CV 2/3 VCC moved by node N through R12 10K)
    osc555(b, "sfk", 5.0, 940e3 * 0.1e-6, 0.0, 470e3 * 0.1e-6, 10 / 3, 5 / 3, en=(S, LOCK))

    def nhi():
        b.op("LD", "sfsq"); b.op("MUL", "sfkq"); b.op("CMPI", imm=HALF); b.op("FAND", 0, b.src(S, SCAN))
    osc555(b, "sfs", 5.0, 47.47e3 * 0.01e-6, 0.0, 47e3 * 0.01e-6, 10 / 3, 5 / 3, en=(S, SCAN), lvl=VS11, chg=nhi)
    nhi()
    a = b.skip_if(False)
    osc555(b, "sfr", 5.0, 60e3 * 0.01e-6, 0.0, 30e3 * 0.01e-6, 3.75, 1.875, en=(S, TRACK), lvl=VOH5)
    j = b.jump()
    b.land(a)
    osc555(b, "sfr", 5.0, 60e3 * 0.01e-6, 0.0, 30e3 * 0.01e-6, 2.5, 1.25, en=(S, TRACK), lvl=VOH5, mk=False)
    b.land(j)
    b.kreg("sf_k13", kx(5.7e3 * 1e-6), "F", clamp=False)          # C13 1u, R30 4.7K + R29 1K
    b.op("LD", "sfro"); rcm(b, "sf_c13", "sf_k13")
    b.kreg("sf_k9", kx((par(10e3, 1e3) + ZIN) * 0.1e-6), "F", clamp=False)   # C9 0.1u into MC3340 6B pin 1
    b.op("LD", "sfso"); rcm(b, "sf_c9", "sf_k9"); b.op("MULI", imm=-ONE); b.op("ADD", "sfso"); b.op("ST", "sf_in2")
    # overheat / LOH: MC3340 6B, envelope C20 (R38 2.7K, R69 + R70 940K)
    mc3340(b, "sf2", (S, OHEAT), 2.7e3 * 1e-6, 940e3 * 1e-6, "sf_in2", CLH_S)
    # RUMBLE 2: R51 16K / C21 0.1u, loaded by the switched 17K path (drains 15/16 more) while SIZE ON
    tau51 = 16e3 * 0.1e-6
    b.kreg("sf_k51", kx(tau51), "F", clamp=False)
    b.kreg("sf_k51s", kx(tau51 / 1.9375), "F", clamp=False)
    b.op("LD", "sf_c18"); b.op("CMPI", imm=q(VSZT)); b.op("LD", "sf_k51"); b.op("LDF", "sf_k51s"); b.op("ST", "sf_k5")
    b.op("LD", "sf_rum"); at = b.skip_if(False); b.op("MULI", imm=q(1 / 1.9375)); b.land(at)
    rcm(b, "sf_r2", "sf_k5")
    # mixer 8D_B (pots at 50 %) x OSD effects, clamp, output C14 / R31 high-pass, R21 at 50 %, soft limit
    b.op("LD", "sf_nsf"); b.op("MUL", "sftq"); b.op("MULI", imm=q(GT)); b.op("ST", "sf_m")
    b.op("LD", "sflsx"); b.op("MUL", "sflq"); b.op("MULI", imm=q(GL)); b.op("ADD", "sf_m"); b.op("ST", "sf_m")
    b.op("LD", "sf_c18"); b.op("CMPI", imm=q(VSZT)); b.op("LDI", imm=0); b.op("LDF", "sf_r2")
    b.op("MULI", imm=q(GS)); b.op("ADD", "sf_m")
    b.op("MACI", "sf1o", imm=q(GE)); b.op("MACI", "sf2o", imm=q(GH)); b.op("ST", "sf_m")
    b.op("BIT", 1, b.src(S, TRACK)); b.op("LD", "sfro"); b.op("SUB", "sf_c13"); b.op("LDIF", imm=0)
    b.op("MULI", imm=q(GC)); b.op("ADD", "sf_m")
    vol(b, "E"); clampv(b, -VOPCL, VOPCL); b.op("ST", "sf_mx")
    b.kreg("sf_kho", kx(1.005e6 * 0.1e-6), "F", clamp=False)
    rcm(b, "sf_hpo", "sf_kho"); b.op("MULI", imm=-ONE); b.op("ADD", "sf_mx")
    if probe:
        probe_out(b, *probe)
        return b.finish()
    b.op("MULI", imm=q(KSF / 32768)); b.op("ST", "sf_ys")
    # RTL limiter: linear to 20000, slope 1/4 to 52000 (-> 28000), 1/16 above = min of the three lines
    b.op("ABS"); b.op("ST", "sf_ya"); b.op("MULI", imm=q(0.25)); b.op("ADDI", imm=q(15000 / 32768)); b.op("ST", "sf_t")
    b.op("LD", "sf_ya"); b.op("MULI", imm=q(1 / 16)); b.op("ADDI", imm=q(24750 / 32768))
    b.op("CMP", "sf_t"); b.op("LDF", "sf_t"); b.op("CMP", "sf_ya"); b.op("LDF", "sf_ya"); b.op("ST", "sf_t")
    b.op("LD", "sf_ys"); b.op("CMPI", imm=0); b.op("LD", "sf_t")
    at = b.skip_if(True); b.op("MULI", imm=-ONE); b.land(at)
    b.op("OUT")
    return b.finish()


# ---------------------------------------------------------------- Fire One
def fireone(probe=None):
    b = Board("fireone")
    LTORP, LSHP, LBOOM, _PSEL, _G0, _G1, _G2, SOFF = range(8)
    RTORP, RSHP, RBOOM, TCOLL, SUB, ALERT, SYNC, NOISEN = range(8)
    # no init block: every register is 0 at rest (envelope caps stored relative to their rest voltage, the mixer
    # outputs relative to the VBF bias); the free-running 556 A / alert 8038 / sonar 555 start from 0 V (power-up only)
    # noise: HLE 1 kHz clock while offset 1 D7 = 1 (MAME HLE_SONAR_CLOCK); IC16B node: C45 0.1u -> R68 100K, -R66 / R68
    noise_clock(b, "fon", lambda: b.op("LDI", imm=q(NINC_F / FS)), en=(L1, NOISEN))
    b.kreg("fo_k45", kx(100e3 * 0.1e-6), "F", clamp=False)
    b.op("LD", "fonna"); b.op("MULI", imm=q(12.0)); b.op("ST", "fo_vs")
    rcm(b, "fo_c29", "fo_k45"); b.op("MULI", imm=-ONE); b.op("ADD", "fo_vs"); b.op("MULI", imm=q(GFI))
    b.op("ST", "fo_nsf")
    rumble(b, "fo", "fo_nsf")
    # noise-gate offsets of the LM3900 gates (NOISE = R140 / R141 tap of NOISE_A: 2.77 / 12 V)
    for r, lo, hi in (("fo_vgt", VGT_L, VGT_H), ("fo_vgp", VGP_L, VGP_H), ("fo_vgc", VGC_L, VGC_H)):
        b.op("LD", "fonna"); b.op("MULI", imm=q(hi - lo)); b.op("ADDI", imm=q(lo)); b.op("ST", r)
    # booms: MC3340 L / R on the rumble (R103 / R102 3K, C70 / C73 1u, 2M)
    b.kreg("fo_ky", kx(TAU_MC), "F", clamp=False)
    b.op("LD", "fo_rum"); rcm(b, "fo_y", "fo_ky")
    mc3340(b, "fo1", (L0, LBOOM), 3e3 * 1e-6, 2e6 * 1e-6, None, CLB_F, y="fo_y")
    mc3340(b, "fo2", (L1, RBOOM), 3e3 * 1e-6, 2e6 * 1e-6, None, CLB_F, y="fo_y")
    # torpedo gates (fast part): vg = clamp(noise offset + E, 0, 10.8), C35 / R132 and C98 / R133 || R118 high-pass
    b.kreg("fo_kh1", kx(1e6 * 2.2e-9), "F", clamp=False)
    b.kreg("fo_kh2", kx(par(1e6, 560e3) * 2.2e-9), "F", clamp=False)
    for s in "lr":
        p = "fot" + s
        b.op("LD", p + "E"); b.op("ADD", "fo_vgt"); clampv(b, 0, VOHI); b.op("ST", p + "g")
        rcm(b, p + "h1", "fo_kh1"); b.op("MULI", imm=-ONE); b.op("ADD", p + "g"); b.op("ST", p + "t")
        rcm(b, p + "h2", "fo_kh2"); b.op("MULI", imm=-ONE); b.op("ADD", p + "t"); b.op("ST", p + "o")
    # partial hits (fast): R34 12K / C49 2.2n, R74 12K / C22 33n
    b.kreg("fo_kq1", kx(12e3 * 2.2e-9), "F", clamp=True)
    b.kreg("fo_kq2", kx(12e3 * 33e-9), "F", clamp=False)
    for s in "lr":
        p = "fop" + s
        b.op("LD", p + "E"); b.op("ADD", "fo_vgp"); clampv(b, 0, VOHI)
        rcm(b, p + "1", "fo_kq1"); rcm(b, p + "2", "fo_kq2")
    # torpedo collision (fast): R12 / R13 3.9K, C4 / C38 0.1u
    b.kreg("fo_kcl", kx(3.9e3 * 0.1e-6), "F", clamp=False)
    b.op("LD", "focE"); b.op("ADD", "fo_vgc"); clampv(b, 0, VOHI)
    rcm(b, "foc1", "fo_kcl"); rcm(b, "foc2", "fo_kcl")
    # sub engine 556 IC31 B (R126 6.8K, R127 8.2K, C84 0.1u, 5 V), CV = C85 (A side): thresholds c85 / c85/2;
    # output R124 3K / C114 0.1u, R125 3K / C52 0.1u
    sub_b(b)
    b.kreg("fo_ksl", kx(3e3 * 0.1e-6), "F", clamp=False)
    b.op("LD", "fobo"); rcm(b, "fo_sl1", "fo_ksl"); rcm(b, "fo_sl2", "fo_ksl")
    # alert: 8038 IC15 triangle 4..8 V, slope (12 - pin 8) / (R59 C44); 4013 IC3B toggles at the bottom turn while
    # ALERT, reset otherwise; R18 1K / C10 0.1u
    alert_fast(b)
    # sonar: noise via R138 47K / R137 5.6K into C100 0.22u, 4017 drive (Q2 chops it while IC6A out > 0), MFB band-pass
    b.kreg("fo_k100", kx(par(47e3, 5.6e3) * 0.22e-6), "F", clamp=False)
    b.op("LD", "fonna"); b.op("MULI", imm=q(V100)); rcm(b, "fo_c100", "fo_k100"); b.op("MULI", imm=q(GN100))
    b.op("ST", "fo_t")
    b.op("LD", "fo_bp2"); b.op("CMPI", imm=0); b.op("LDI", imm=0); b.op("LDF", "fo_drv"); b.op("ADD", "fo_t")
    b.op("ST", "fo_t")
    b.kreg("fo_f2", 2 * math.sin(math.pi * F2 / FS), "F", clamp=False)
    b.op("LD", "fo_bp2"); b.op("MUL", "fo_f2"); b.op("ADD", "fo_lp2"); b.op("ST", "fo_lp2")
    b.op("LD", "fo_t"); b.op("SUB", "fo_lp2"); b.op("MACI", "fo_bp2", imm=q(-QD2))
    b.op("MUL", "fo_f2"); b.op("ADD", "fo_bp2"); b.op("ST", "fo_bp2")
    b.op("MULI", imm=q(-QD2)); clampv(b, -VOPCL, VOPCL); b.op("ST", "fo_son")
    # slow nodes, costliest slot first (the dispatch chain adds 3 units per earlier slot)
    round_robin(b, "fo_rr", [lambda: subA_alert_slow(b), lambda: torp_slow(b, "l", L0, LTORP),
                             lambda: torp_slow(b, "r", L1, RTORP), lambda: sonar_timing(b), lambda: hits_slow(b),
                             lambda: sonar_drive(b)])
    # mixers IC4A (L) / IC4B (R), LM3900: both partial hits feed L (MAME netlist), music x _fM, rest x _fE
    b.op("LD", "foc2"); b.op("MULI", imm=q(GTC)); b.op("MACI", "fo_sl2", imm=q(GSE)); b.op("MACI", "fo_son", imm=q(GSON))
    b.op("MACI", "fo_al", imm=q(GAL)); b.op("ST", "fo_m")
    b.op("MACI", "fo1o", imm=q(GBM)); b.op("MACI", "fopl2", imm=q(GSH)); b.op("MACI", "fopr2", imm=q(GSH))
    b.op("MACI", "fotlo", imm=q(GTP)); vol(b, "E"); b.op("ST", "fo_tl")
    b.op("LD", "fo_m"); b.op("MACI", "fo2o", imm=q(GBM)); b.op("MACI", "fotro", imm=q(GTP)); vol(b, "E")
    b.op("ST", "fo_tr")
    b.op("LDL", 0, b.src(P0, 0)); b.op("ST", "fo_t"); b.op("LDL", 0, b.src(P1, 0)); b.op("ADD", "fo_t")
    b.op("ST", "fo_t"); b.op("LDL", 0, b.src(P2, 0)); b.op("ADD", "fo_t"); b.op("MULI", imm=q(256 / N_CE * GMU))
    vol(b, "M"); b.op("ST", "fo_mu")
    b.kreg("fo_khil", kx(RPL * 1e-6), "F", clamp=False)
    b.kreg("fo_khir", kx(RPR * 1e-6), "F", clamp=False)
    b.kreg("fo_k121", kx(68e3 * 1e-9), "F", clamp=True)
    b.kreg("fo_kho", kx(105e3 * 0.1e-6), "F", clamp=False)
    outs = []
    for s, kh in (("l", "fo_khil"), ("r", "fo_khir")):
        b.op("LD", "fo_mu"); b.op("ADD", "fo_t" + s); b.op("ST", "fo_t" + s)
        rcm(b, "fo_hi" + s, kh); b.op("SUB", "fo_t" + s); clampv(b, -VBF, VMX - VBF)   # (out - VBF)
        b.op("BIT", 0, b.src(L0, SOFF)); b.op("LDIF", imm=q(-VBF))
        rcm(b, "fo_vm" + s, "fo_k121"); rcm(b, "fo_ho" + s, "fo_kho"); b.op("MULI", imm=-ONE)
        b.op("ADD", "fo_vm" + s); outs.append("fo_y" + s); b.op("ST", "fo_y" + s)
    if probe:
        probe_out(b, *probe[:2])
        if len(probe) > 2:
            probe_out(b, *probe[2:], right=True)
        return b.finish()
    b.op("LD", "fo_yl"); b.op("MULI", imm=q(OFO / 32768)); b.op("OUT")
    b.op("LD", "fo_yr"); b.op("MULI", imm=q(OFO / 32768)); b.op("OUTR")
    return b.finish()


def sub_b(b):
    """sub engine 556 B: charge toward 5 V (tau TBC) while high, discharge (TBD); thresholds c85 / c85 / 2 (CV = the A
    side's cap); reset while SUB ENGINE is low. Crossing: overshoot fraction f = overshoot / step at the threshold
    (RCP), the remainder runs on the other branch; fobo = box-averaged 3.3 V output"""
    kc, kd = kx(TBC), kx(TBD)
    b.kreg("fo_kbc", kc, "O", clamp=False)
    b.kreg("fo_kbd", kd, "O", clamp=False)
    tmax = 6.0 * kc                                 # bound on one step (cap below 5 V)
    b.op("BIT", 1, b.src(L1, 4)); b.op("LDI", imm=0); b.op("STF", "fobq")
    b.op("LD", "fobq"); b.op("CMPI", imm=HALF); at = b.skip_if(False)
    # charging: top threshold c85
    b.op("LDI", imm=q(5.0)); rcm(b, "fobc", "fo_kbc")
    b.op("CMP", "foac"); a1 = b.skip_if(False)
    b.op("SUB", "foac"); b.op("ST", "fobt")
    b.op("CMPI", imm=q(1.5 * tmax)); a5 = b.skip_if(True)
    b.op("LDI", imm=q(5.0)); b.op("SUB", "foac"); b.op("MUL", "fo_kbc"); b.op("RCP"); b.op("MUL", "fobt")
    b.op("MINI", imm=ONE); b.op("ST", "fobf")                                      # f = overshoot / step
    b.op("MUL", "fo_kbd"); b.op("MULI", imm=-ONE); b.op("ADDI", imm=ONE); b.op("MUL", "foac"); b.op("ST", "fobc")
    b.op("LD", "fobf"); b.op("MULI", imm=q(-VOH5)); b.op("ADDI", imm=q(VOH5)); b.op("ST", "fobo")
    a7 = b.jump()
    b.land(a5)
    b.op("LDI", imm=0); b.op("ST", "fobo")
    b.land(a7)
    b.op("LDI", imm=0); b.op("ST", "fobq")
    j1 = b.jump()
    b.land(at)
    # discharging: bottom threshold c85 / 2
    b.op("LD", "foac"); b.op("MULI", imm=HALF); b.op("ST", "fobl")
    b.op("LDI", imm=0); rcm(b, "fobc", "fo_kbd")
    b.op("CMP", "fobl"); a2 = b.skip_if(True)
    b.op("BIT", 0, b.src(L1, 4)); a4 = b.skip_if(False)
    b.op("SUB", "fobl"); b.op("ST", "fobt")
    b.op("CMPI", imm=q(-1.5 * 4.0 * kd)); a6 = b.skip_if(False)
    b.op("LD", "fobl"); b.op("MUL", "fo_kbd"); b.op("RCP"); b.op("MUL", "fobt"); b.op("MULI", imm=-ONE)
    b.op("MINI", imm=ONE); b.op("ST", "fobf")                                      # f = overshoot / |step|
    b.op("LDI", imm=q(5.0)); b.op("SUB", "fobl"); b.op("MUL", "fo_kbc"); b.op("MUL", "fobf"); b.op("ADD", "fobl")
    b.op("ST", "fobc")
    b.op("LD", "fobf"); b.op("MULI", imm=q(VOH5)); b.op("ST", "fobo")
    a8 = b.jump()
    b.land(a6)
    b.op("LDI", imm=q(VOH5)); b.op("ST", "fobo")
    b.land(a8)
    b.op("LDI", imm=ONE); b.op("ST", "fobq")
    j2 = b.jump()
    b.land(a1)
    b.land(a2)
    b.land(a4)
    b.op("LD", "fobq"); b.op("MULI", imm=q(VOH5)); b.op("ST", "fobo")
    b.land(j1)
    b.land(j2)


def alert_fast(b):
    """alert 8038 triangle fo3x 4..8 V (slope register fo_asl, its reciprocal fo_ainv from the slow slot), 4013 aq"""
    b.kreg("fo_kal", kx(1e3 * 0.1e-6), "F", clamp=True)
    j1, a2 = triangle(b, "fo3", 4.0, 8.0, lambda: b.op("LD", "fo_asl"))
    # bottom turn: after the reflection fo3x - 4 = overshoot; fraction of the sample after the turn
    b.op("LD", "fo3x"); b.op("ADDI", imm=q(-4.0)); b.op("MUL", "fo_ainv"); b.op("MINI", imm=ONE); b.op("ST", "fo_af")
    b.op("LD", "fo_aq"); b.op("ST", "fo_aq0"); b.op("MULI", imm=-ONE); b.op("ADDI", imm=ONE)
    b.op("BIT", 1, b.src(L1, 5)); b.op("LDIF", imm=0); b.op("ST", "fo_aq")
    b.op("SUB", "fo_aq0"); b.op("MUL", "fo_af"); b.op("ADD", "fo_aq0"); b.op("MULI", imm=q(12.0)); b.op("ST", "fo_vfa")
    j2 = b.jump()
    b.land(a2)
    b.op("ST", "fo3x")
    b.land(j1)
    b.op("BIT", 1, b.src(L1, 5)); b.op("LDI", imm=0); b.op("STF", "fo_aq")
    b.op("LD", "fo_aq"); b.op("MULI", imm=q(12.0)); b.op("ST", "fo_vfa")
    b.land(j2)
    b.op("LD", "fo_vfa"); rcm(b, "fo_al", "fo_kal")


def torp_slow(b, s, src, bit):
    """torpedo envelopes (slow slot): C7 / C8 0.33u and C14 / C12 2.2u charged to 4.4 V through 1K while TORP, else
    discharged toward the 0.5 V Norton input through 680K; IC14C / IC2A integrator (R51 / R15 5.6M bias, C42 / C3 1u,
    R54 / R8 2M); gate drive E = (R47 1.2M / R46 680K) (pos(c7 - 0.5) + pos(int - 0.5))"""
    p = "fot" + s
    if s == "l":
        b.kreg("fo_kt7c", kx(1e3 * 0.33e-6, DT_RR), "T", clamp=True)
        b.kreg("fo_kt7d", kx(680e3 * 0.33e-6, DT_RR), "T", clamp=False)
        b.kreg("fo_kt14c", kx(1e3 * 2.2e-6, DT_RR), "T", clamp=False)
        b.kreg("fo_kt14d", kx(680e3 * 2.2e-6, DT_RR), "T", clamp=False)
        b.kreg("fo_kint", DT_RR / TAU_INT, "T", clamp=False)
    b.op("BIT", 0, b.src(src, bit)); b.op("LD", "fo_kt7d"); b.op("LDF", "fo_kt7c"); b.op("ST", "fo_k")
    b.op("LDI", imm=0); b.op("LDIF", imm=q(VCH - VLM)); rcm(b, p + "7", "fo_k")
    b.op("LD", "fo_kt14d"); b.op("LDF", "fo_kt14c"); b.op("ST", "fo_k")
    b.op("LDI", imm=0); b.op("LDIF", imm=q(VCH - VLM)); rcm(b, p + "14", "fo_k")
    b.op("MAXI", imm=0); b.op("ST", "fo_t2")
    b.op("LD", p + "i"); b.op("ADDI", imm=q(-VLM)); b.op("MULI", imm=q(-K034)); b.op("ADD", "fo_t2")
    b.op("ADDI", imm=q(-VIB)); b.op("MUL", "fo_kint"); b.op("ADD", p + "i"); clampv(b, 0, VOHI); b.op("ST", p + "i")
    b.op("ADDI", imm=q(-VLM)); b.op("MAXI", imm=0); b.op("ST", "fo_t2")
    b.op("LD", p + "7"); b.op("MAXI", imm=0); b.op("ADD", "fo_t2")
    b.op("MULI", imm=q(GTG)); b.op("ST", p + "E")


def hits_slow(b):
    """partial hits L / R (C13 / C6 4.7u, R32 / R40 680K) and torpedo collision (C11 2.2u, R10 220K) envelopes"""
    b.kreg("fo_kpc", kx(1e3 * 4.7e-6, DT_RR), "T", clamp=False)
    b.kreg("fo_kpd", kx(680e3 * 4.7e-6, DT_RR), "T", clamp=False)
    b.kreg("fo_kcc", kx(1e3 * 2.2e-6, DT_RR), "T", clamp=False)
    b.kreg("fo_kcd", kx(220e3 * 2.2e-6, DT_RR), "T", clamp=False)
    for reg, out, src, bit, kc, kd, g in (("fopl", "foplE", L0, 1, "fo_kpc", "fo_kpd", GTG),
                                         ("fopr", "foprE", L1, 1, "fo_kpc", "fo_kpd", GTG),
                                         ("foc11", "focE", L1, 3, "fo_kcc", "fo_kcd", GCG)):
        b.op("BIT", 0, b.src(src, bit)); b.op("LD", kd); b.op("LDF", kc); b.op("ST", "fo_k")
        b.op("LDI", imm=0); b.op("LDIF", imm=q(VCH - VLM)); rcm(b, reg, "fo_k")
        b.op("MAXI", imm=0); b.op("MULI", imm=q(g)); b.op("ST", out)


def subA_alert_slow(b):
    """sub engine 556 A (free-running 64 Hz, C85 2.2u loaded by CV2) and the alert ramp: Q1 sinks 8 uA from C41 1u
    (pin 8 falls 11.6 -> 8.1 V) while ALERT, else recharged through 1K; slope register fo_asl = (12 - p8) / (R C44)
    per sample and its reciprocal fo_ainv"""
    osc555(b, "foa", VAC, TAC, VAD, TAD, 10 / 3, 5 / 3, dt=DT_RR)
    b.kreg("fo_kp8s", SP8 * DT_RR, "T", clamp=False)
    b.kreg("fo_kp8c", kx(1e3 * 1e-6, DT_RR), "T", clamp=False)
    b.kreg("fo_va38", DT / RA38, "O", clamp=False)
    b.op("BIT", 0, b.src(L1, 5)); a = b.skip_if(False)
    b.op("LD", "fo_p8"); b.op("SUB", "fo_kp8s"); b.op("MAXI", imm=q(V8M)); b.op("ST", "fo_p8")
    j = b.jump()
    b.land(a)
    b.op("LDI", imm=q(V8I)); rcm(b, "fo_p8", "fo_kp8c")
    b.land(j)
    b.op("LDI", imm=q(12.0)); b.op("SUB", "fo_p8"); b.op("MUL", "fo_va38"); b.op("ST", "fo_asl")
    b.op("RCP"); b.op("ST", "fo_ainv")


def sonar_timing(b):
    """sonar 555 IC29 (R110 1K, R107 47K, C72 2.2u, 12 V): its rising edge clocks 4013 IC3A (/2), whose rising edge
    clocks the 4017 IC25 (held at 0 while SONAR SYNC is low). fo_ffn = NOT IC3A Q: 0 at power-up, so the power-up set
    of the engine's 555 (cap at 0 V) leaves Q = 0 for the first real cycle, as the RTL's reset state does"""
    def on_set():
        b.op("LD", "fo_ffn"); b.op("CMPI", imm=HALF); b.op("LDI", imm=ONE); b.op("LDIF", imm=0); b.op("ST", "fo_ffn")
        a = b.skip_if(False)                       # counts when Q rises (ffn was 1)
        b.op("LD", "fo_cnt"); b.op("ADDI", imm=ONE); b.op("CMPI", imm=q(9.5)); b.op("LDIF", imm=0)
        b.op("ST", "fo_cnt")
        b.land(a)
    osc555(b, "fo5", 12.0, 48e3 * 2.2e-6, 0.0, 47e3 * 2.2e-6, 8.0, 4.0, dt=DT_RR, on_set=on_set)
    b.op("BIT", 1, b.src(L1, 6)); b.op("LDI", imm=0); b.op("STF", "fo_cnt")


def sonar_drive(b):
    """4017 outputs 1 / 2 / 4 / 9 via R36 / R72 / R73 / R75 into R19 while 555 out and IC3A Q are high"""
    b.op("LDI", imm=0); b.op("ST", "fo_d0")
    for i, v in ((1, VDK[1]), (2, VDK[2]), (3, 0.0), (4, VDK[4]), (5, 0.0), (9, VDK[9])):
        b.op("LD", "fo_cnt"); b.op("CMPI", imm=q(i - 0.5)); b.op("LDI", imm=q(v)); b.op("STF", "fo_d0")
    b.op("LD", "fo_ffn"); b.op("MULI", imm=-ONE); b.op("ADDI", imm=ONE); b.op("MUL", "fo_d0"); b.op("MUL", "fo5q")
    b.op("ST", "fo_drv")


if __name__ == "__main__":
    for f in (starfire, fireone):
        p = f()
        print(f"{p.name:10s} words {len(p.code):4d}  worst units {p.worst_path():3d}  registers {len(p.regs):3d}")

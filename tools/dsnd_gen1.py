"""Exidy gen-1 audio boards on the discrete sound engine (rtl/rodimus/dsnd_engine/dsnd_engine.sv, assembler tools/dsnd.py).
  targ()    TARG AUDIO PCB 77-3371-11 (targ1.1.pdf p26-27)
  spectar() SPECTAR AUDIO PCB 77-3376-11 (spectar.pdf p23, p25): Spectar, Side Trak, Rallys / Panzer, Phantomas

Primary reference: rtl/boards/exidy_gen1_sound/exidy_gen1snd.sv (HW-confirmed by the user). Its circuit model runs at
176.4 kHz; every constant below is re-derived from that RTL's constants for FS = 27137 Hz (kconv / rate), so the
continuous-time behaviour is the same. Deviations from the RTL are marked DEV.

Sources (tools/dsnd_boards.py): 0 = 5200 latch, 1 = 5201 latch, 2 = tone flip-flop 3D-b box count (phi2 cycles high in
the sample, 0-26), 3 = MUSIC (5200 D0) box count. The latches, tone prescaler / divider / NOTE counter / PROM stay in
RTL; everything analog is here.
5200 Targ: D0 MUSIC, D1 SHOOT, D3 5WARN, D4 5SPEC (low = 556 runs), D5 CRASH, D6 LONG, D7 GAME.
5200 Spectar: D0 MUSIC, D1 SHOOT, D5 CRASH, D7 TONE (D2-D4, D6 n.c.).

Game Audio cap groups: T = C14, C60, C29 (shoot envelope / 566 CV), C35 / C36 (crash envelope); O = C26 (566), C5 / C28,
C15 (556); F = C41 / C44 (tone / music filters), C38 / C39 (Q3 band-pass), C37, output coupling (60 Hz high-pass).
OSD: tone + CPU music x _fM, shoot / crash / Spectar sound x _fE (the RTL's vol/8).
Units: volts. Register names start with "g1".
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dsnd_rate  # noqa: F401,E402  master assembler + this core's FS, before any dsnd import
from dsnd import Board, FS, q  # noqa: E402

FSR = 176400.0                       # old RTL analog sample rate (phi2 / 4)
LAT0, LAT1, TONE, MUS = 0, 1, 2, 3   # engine sources


def kconv(k_rtl):
    """RTL one-pole coefficient (Q24 at 176.4 kHz) -> the same time constant at FS"""
    tau = -1.0 / (FSR * math.log(1.0 - k_rtl / 2 ** 24))
    return 1.0 - math.exp(-1.0 / (FS * tau))


def rate(k_rtl, qbits=24):
    """RTL per-sample linear step (Q<qbits> at 176.4 kHz) -> per sample at FS"""
    return k_rtl / 2 ** qbits * FSR / FS


def tau(k_rtl):
    """RTL one-pole coefficient -> time constant (s)"""
    return -1.0 / (FSR * math.log(1.0 - k_rtl / 2 ** 24))


def v28(x):
    return x / 2 ** 28                # RTL Q28 volts


# ---- RTL constants (exidy_gen1snd.sv), named as there
VBE = v28(174483046)                  # 0.65
NOFS, NMIN, NMAX = v28(1315333734), v28(26843546), v28(2952790016)
VB0, VW, V5MIN, TRI = v28(939790872), v28(2126008812), v28(805306368), v28(322122547)
V3, MCLIP, SQIN = v28(805306368), v28(805306368), v28(442918502)
TC1, TD1, VTH1, VTL1 = v28(1040515285), v28(355757833), v28(894784853), v28(447392427)
V556, VCH, VD, VCMIN, VCOMAX = v28(885837005), v28(3060164198), v28(161061274), v28(53687091), v28(2636036178)
TIDLE = v28(456340275)                # 1.7 V: tone FF high, 10K pot at mid (3.4 V x 0.5)
KS_B, KS_N, RRATIO, VNG = 8336735 / 2 ** 24, 566898 / 2 ** 24, 14795655 / 2 ** 24, 14235214 / 2 ** 24
KATT = 7837412 / 2 ** 20              # MC3340 7.47 octaves per volt above 3 V
G_LP, G_BP, G_DC = 11212423 / 2 ** 20, 5691671 / 2 ** 20, 8276410 / 2 ** 20
SVF_QI = 6200693 / 2 ** 24
SVF_F0 = math.asin(43118 / 2 ** 24 / 2) * FSR / math.pi        # 72.15 Hz Chamberlin fit of the bridged-T stage
OUT_SCALE = 2800.0 / 32768           # RTL: 2800 counts per volt after the mixer; engine 1.0 = 32768
OS566 = 2                             # Targ 566 + MC3340 sub-steps per sample
D556 = 1.5 / FSR                      # RTL 556 comparator delay (see ne556); 0 = ideal circuit

# noise: RTL = +-1 V per 176.4 kHz sample into a 2.5 kHz one-pole (#unverified stand-in). Same LPF output variance at FS
_KNR = 1429382 / 2 ** 24
KN = kconv(1429382)
AN = math.sqrt(_KNR / (2 - _KNR) * (2 - KN) / KN)              # DEV: engine LFSR (other sequence), +-0.40 V per sample


def lin(b, dst, const, terms):
    """dst = const + sum(reg x k) (MACI), acc = dst"""
    b.op("LDI", imm=q(const))
    for r, k in terms:
        b.op("MACI", r, imm=q(k))
    if dst:
        b.op("ST", dst)


def vol(b, g):
    """acc *= OSD volume g ("M" / "E", level / 8). Same as dsnd.Board.gain(g), which is shadowed in tools/dsnd.py by
    the later DST_GAIN node method Board.gain(out, src, k)"""
    b.vols.add(g)
    b.op("MUL", "_f" + g)


def noise(b):
    """WHITE NOISE node (Q4 zener + 72748 + Q5 collector): clipped, band-limited noise, 0.1 .. 11 V"""
    b.noise(0, AN)
    b.op("RC", "g1nl", imm=q(KN))
    b.op("MULI", imm=q(30.0))                                   # RTL NGAIN
    b.op("ADDI", imm=q(NOFS))
    b.op("MINI", imm=q(NMAX))
    b.op("MAXI", imm=q(NMIN))
    b.op("ST", "g1vn")


def shoot_env(b, spectar):
    """SHOOT -> 7407 sinks C14; Q1 base / emitter; ve = MC3340 control (and the Targ 566 CV pull through C29)"""
    if spectar:
        # C60 .47u base node: vb relaxes toward c14 x R/R3 + 12 V share with rate G/C60 (RTL KB14, KB0, KBG)
        b.kreg("g1kg", kconv(5786), "T")
        b.op("LD", "g1c14")
        b.op("MULI", imm=q(2976 / 5786))
        b.op("ADDI", imm=q(v28(335467) / (5786 / 2 ** 24)))
        b.op("RCM", "g1vb", b.r("g1kg"))
        b.kreg("g1k14", kconv(140), "T")                         # R3 68K x C14 10u
    else:
        lin(b, "g1vb", VB0, [("g1c14", KS_B), ("g1vn", KS_N)])  # R3 / R4 / R50 (noise "hiss") divider
        b.kreg("g1k14", kconv(206), "T")                         # R3 68K x C14 6.8u
    b.op("RCM", "g1c14", b.r("g1k14"))                           # acc = vb: C14 charges toward the base node
    b.op("BIT", 0, b.src(LAT0, 1))                               # SHOOT = 1: 7407 output low, C14 = 0
    b.op("LDI", imm=0)
    b.op("STF", "g1c14")
    b.op("LD", "g1vb")
    b.op("ADDI", imm=q(-VBE))
    b.op("MAXI", imm=0)
    b.op("ST", "g1ve")


def mc_gain(b):
    """MC3340 4A gain from the control pin (Q1 emitter): 4.47 x 2^-(7.47 (ve - 3)), 4.47 at or below the 3 V knee.
    DEV: EXP instead of the RTL's 32-entry 1/32-octave LUT; no hard mute at 20 octaves (EXP gives < -120 dB there)"""
    b.op("LD", "g1ve")
    b.op("ADDI", imm=q(-V3))
    b.op("MULI", imm=q(-KATT))
    b.op("MINI", imm=0)
    b.op("MAXI", imm=q(-30.0))
    b.op("EXP")
    b.op("MULI", imm=q(4.47))
    b.op("ST", "g1g")


def mc_out(b, inp):
    """acc = MC3340 output: gain x input, clipped at +-3 V"""
    b.op("LD", inp)
    b.op("MUL", "g1g")
    b.op("MINI", imm=q(MCLIP))
    b.op("MAXI", imm=q(-MCLIP))


def vco566(b):
    """Targ 566 4B: CV = R10 wiper (VW, PRT 500 us) pulled by C29 33u toward the Q1 emitter; triangle +-1.2 V,
    slope = kf x (12 - CV) (R11 6.8K, C26 .05u), reflected at the peaks (exact fold, no phase loss). The triangle and
    the MC3340 clip run OS566 sub-steps per sample, decimated by a [1 2 1] / 4 (OS566 = 2) or box (other) FIR on the
    sub-sample stream: the clipped triangle has harmonics past FS / 2 (the RTL runs at 176.4 kHz)"""
    b.kreg("g1kq", kconv(1135), "T")                             # C29 x (Rpot 2.24K + 0.3K)
    b.kreg("g1kf", -rate(223786) / OS566, "O", clamp=False)      # C26, per sub-step
    b.op("LDI", imm=q(VW))
    b.op("SUB", "g1ve")
    b.op("ST", "g1t")
    b.op("RCM", "g1q", b.r("g1kq"))
    b.op("LD", "g1t")
    b.op("SUB", "g1q")
    b.op("MULI", imm=q(-RRATIO))
    b.op("ADDI", imm=q(VW))
    b.op("MINI", imm=q(12.0))
    b.op("MAXI", imm=q(V5MIN))
    b.op("ADDI", imm=q(-12.0))
    b.op("MUL", "g1kf")                                          # step > 0
    b.op("ST", "g1stp")
    mc_gain(b)
    w = [0.25, 0.5, 0.25] if OS566 == 2 else [1.0 / OS566] * OS566
    for i in range(OS566):
        b.op("LD", "g1stp")
        b.op("MUL", "g1dir")
        b.op("ADD", "g1ph")
        b.op("ST", "g1ph")
        b.op("CMPI", imm=q(TRI))
        at = b.skip_if(False)
        b.op("LDI", imm=q(2 * TRI))
        b.op("SUB", "g1ph")
        b.op("ST", "g1ph")
        b.op("LDI", imm=q(-1.0))
        b.op("ST", "g1dir")
        b.land(at)
        b.op("LD", "g1ph")
        b.op("CMPI", imm=q(-TRI))
        at = b.skip_if(True)
        b.op("LDI", imm=q(-2 * TRI))
        b.op("SUB", "g1ph")
        b.op("ST", "g1ph")
        b.op("LDI", imm=q(1.0))
        b.op("ST", "g1dir")
        b.land(at)
        mc_out(b, "g1ph")
        if OS566 == 1:
            b.op("ST", "g1mc")
            break
        b.op("ST", f"g1y{i}")
    if OS566 > 1:
        if OS566 == 2:
            lin(b, "g1mc", 0.0, [("g1yp", w[0]), ("g1y0", w[1]), ("g1y1", w[2])])
            b.op("LD", "g1y1")
            b.op("ST", "g1yp")
        else:
            lin(b, "g1mc", 0.0, [(f"g1y{i}", w[i]) for i in range(OS566)])


def ne556(b, spectar):
    """556 5A. osc1 (R6 4.7K, R7 2.2K, C5 [+ C28 on Targ 5WARN]): slow ramp v1 = osc2 CV. osc2 (R14 3.3K, R13 1K,
    C15 .47u): v2 between v1 / 2 and v1. RTL Thevenin targets / rates. osc2 crossings are carried exactly: the part of
    the sample after the crossing runs in the other phase (r = overshoot / step, one RCP per crossing), and g1sq is the
    box average of the output over the sample (anti-aliased edges). Targ: /SPEC high (D4 = 1) holds RESET."""
    if spectar:
        b.kreg("g1kc", kconv(4231), "O")
        b.kreg("g1kd", kconv(7175), "O")
    else:
        b.kreg("g1kc3", kconv(1282), "O")                       # C5 33u
        b.kreg("g1kd3", kconv(2175), "O")
        b.kreg("g1kc6", kconv(641), "O")                        # C5 + C28 66u
        b.kreg("g1kd6", kconv(1087), "O")
        # 5WARN rising: C28 bottom grounded again -> charge sharing with C5 (equal caps)
        b.op("LD", "g1wd")
        b.op("CMPI", imm=q(0.5))
        b.op("NOT")
        b.op("FAND", 0, b.src(LAT0, 3))
        at = b.skip_if(False)
        b.op("LD", "g1v1")
        b.op("ADD", "g1v28")
        b.op("MULI", imm=q(0.5))
        b.op("ST", "g1v1")
        b.land(at)
        b.op("BIT", 0, b.src(LAT0, 3))
        b.op("LDI", imm=0)
        b.op("LDIF", imm=q(1.0))
        b.op("ST", "g1wd")
        b.op("LD", "g1v1")                                       # 5WARN = 1: C28 tracks C5
        b.op("STF", "g1v28")
        b.op("LD", "g1kc3")                                      # F = 5WARN still
        b.op("LDF", "g1kc6")
        b.op("ST", "g1kc")
        b.op("LD", "g1kd3")
        b.op("LDF", "g1kd6")
        b.op("ST", "g1kd")
    # osc1
    b.op("LD", "g1c1")
    b.op("CMPI", imm=q(0.5))
    b.op("LD", "g1kd")
    b.op("LDF", "g1kc")
    b.op("ST", "g1k1")
    b.op("LDI", imm=q(TD1))
    b.op("LDIF", imm=q(TC1))
    b.op("RCM", "g1v1", b.r("g1k1"))
    b.op("CMPI", imm=q(VTH1))
    b.op("LDI", imm=0)
    b.op("STF", "g1c1")
    b.op("LD", "g1v1")
    b.op("CMPI", imm=q(VTL1) + 1)
    b.op("LDI", imm=q(1.0))
    b.op("STNF", "g1c1")
    if not spectar:
        b.op("BIT", 0, b.src(LAT0, 4))                          # RESET: osc1 discharging
        b.op("LDI", imm=0)
        b.op("STF", "g1c1")
    # osc2. The RTL's comparator acts 1.5 of its samples (D556 = 8.5 us) after the crossing, which puts its osc2
    # 2-4 % below the ideal circuit; reproduced here as the equivalent threshold shift (DEV knob: D556 = 0 = ideal)
    b.kreg("g1k2c", kconv(46994), "O")
    b.kreg("g1k2d", kconv(201144), "O")
    b.kreg("g1da", D556 / tau(46994), "O", clamp=False)
    b.kreg("g1db", D556 / tau(201144), "O", clamp=False)
    b.op("LDI", imm=q(5.0))                                      # hi = v1 + D (5 - v1) / tau_c
    b.op("SUB", "g1v1")
    b.op("MUL", "g1da")
    b.op("ADD", "g1v1")
    b.op("ST", "g1hi")
    b.op("LD", "g1v1")                                           # lo = v1 / 2 (1 - D / tau_d)
    b.op("MUL", "g1db")
    b.op("ST", "g1t")
    b.op("LD", "g1v1")
    b.op("SUB", "g1t")
    b.op("MULI", imm=q(0.5))
    b.op("ST", "g1lo")
    at_rst = None
    if not spectar:                                              # RESET: output low, osc2 discharging toward 0 V
        b.op("BIT", 0, b.src(LAT0, 4))
        at = b.skip_if(False)
        b.op("LDI", imm=0)
        b.op("RCM", "g1v2", b.r("g1k2d"))
        b.op("LDI", imm=0)
        b.op("ST", "g1c2")
        b.op("ST", "g1sq")
        at_rst = b.jump()
        b.land(at)
    b.op("LD", "g1v2")
    b.op("ST", "g1v2o")
    b.op("LD", "g1c2")
    b.op("CMPI", imm=q(0.5))
    at_dis = b.skip_if(False)
    # charging toward 5 V
    b.op("LDI", imm=q(5.0))
    b.op("RCM", "g1v2", b.r("g1k2c"))
    b.op("SUB", "g1hi")
    b.op("CMPI", imm=0)
    at_x = b.skip_if(True)
    b.op("LDI", imm=q(1.0))
    b.op("ST", "g1sq")
    at_e1 = b.jump()
    b.land(at_x)                                                 # crossed hi: r = (v2 - hi) / step
    b.op("MINI", imm=q(2.0))
    b.op("ST", "g1d")
    b.op("LD", "g1v2")
    b.op("SUB", "g1v2o")
    b.op("MAXI", imm=q(0.02))
    b.op("RCP")
    b.op("MUL", "g1d")
    b.op("MINI", imm=q(1.0))
    b.op("MAXI", imm=0)
    b.op("ST", "g1r")
    b.op("LDI", imm=q(1.0))
    b.op("SUB", "g1r")
    b.op("ST", "g1sq")
    b.op("LD", "g1hi")                                           # discharge for r of the sample from hi
    b.op("MUL", "g1k2d")
    b.op("MUL", "g1r")
    b.op("ST", "g1d")
    b.op("LD", "g1hi")
    b.op("SUB", "g1d")
    b.op("ST", "g1v2")
    b.op("LDI", imm=0)
    b.op("ST", "g1c2")
    at_e2 = b.jump()
    b.land(at_dis)                                               # discharging toward 0 V
    b.op("LDI", imm=0)
    b.op("RCM", "g1v2", b.r("g1k2d"))
    b.op("LD", "g1lo")
    b.op("SUB", "g1v2")
    b.op("CMPI", imm=0)
    at_x = b.skip_if(True)
    b.op("LDI", imm=0)
    b.op("ST", "g1sq")
    at_e3 = b.jump()
    b.land(at_x)                                                 # crossed lo: r = (lo - v2) / step
    b.op("MINI", imm=q(2.0))
    b.op("ST", "g1d")
    b.op("LD", "g1v2o")
    b.op("SUB", "g1v2")
    b.op("MAXI", imm=q(0.02))
    b.op("RCP")
    b.op("MUL", "g1d")
    b.op("MINI", imm=q(1.0))
    b.op("MAXI", imm=0)
    b.op("ST", "g1r")
    b.op("ST", "g1sq")
    b.op("LDI", imm=q(5.0))                                      # charge for r of the sample from lo
    b.op("SUB", "g1lo")
    b.op("MUL", "g1k2c")
    b.op("MUL", "g1r")
    b.op("ADD", "g1lo")
    b.op("ST", "g1v2")
    b.op("LDI", imm=q(1.0))
    b.op("ST", "g1c2")
    for a in (at_e1, at_e2, at_e3) + ((at_rst,) if at_rst is not None else ()):
        b.land(a)


def crash(b, spectar):
    """CRASH: 7407 + R25 1.2K + CR1 charge the envelope cap (C35, Targ + C36 when LONG), R24 / R28 discharge
    (RTL rates fitted to the MAME targ recordings); CR2 clamps the gate node to the white noise; Q3 bridged-T
    band-pass (RTL SVF fit) -> collector -> CR3 / R32 node (rest 9.82 V)"""
    if spectar:
        b.kreg("g1kcc", kconv(11651), "T")                       # C35 6.8u
        b.kreg("g1r24", kconv(64), "T")
        b.kreg("g1r28", kconv(77), "T")
    else:
        for n, ks in (("kcc", (167788, 10898)), ("r24", (300, 60)), ("r28", (360, 72))):
            b.kreg(f"g1{n}s", kconv(ks[0]), "T")                 # C35 .47u
            b.kreg(f"g1{n}l", kconv(ks[1]), "T")                 # C35 + C36 7.27u (LONG)
        b.op("BIT", 0, b.src(LAT0, 6))
        for n in ("kcc", "r24", "r28"):
            b.op("LD", f"g1{n}s")
            b.op("LDF", f"g1{n}l")
            b.op("ST", f"g1{n}")
    b.op("BIT", 0, b.src(LAT0, 5))
    at = b.skip_if(False)
    b.op("LDI", imm=q(VCH))
    b.op("RCM", "g1env", b.r("g1kcc"))
    b.land(at)
    b.op("LD", "g1env")
    b.op("SUB", "g1vnn")
    b.op("MAXI", imm=0)
    b.op("MUL", "g1r28")
    b.op("ST", "g1t")
    b.op("LD", "g1env")
    b.op("MUL", "g1r24")
    b.op("ADD", "g1t")
    b.op("ST", "g1t")
    b.op("LD", "g1env")
    b.op("SUB", "g1t")
    b.op("ST", "g1env")
    # gate node: R28 / R27 divider above one VBE, clamped by CR2 to the noise
    b.op("ADDI", imm=q(-VBE))
    b.op("ST", "g1t")
    b.op("CMPI", imm=0)
    b.op("LD", "g1env")
    at = b.skip_if(False)
    b.op("LD", "g1t")
    b.op("MULI", imm=q(VNG))
    b.op("ADDI", imm=q(VBE))
    b.land(at)
    b.op("ST", "g1vnn")
    b.op("LD", "g1vn")
    b.op("ADDI", imm=q(VD))
    b.op("CMP", "g1vnn")
    b.op("LDF", "g1vnn")
    b.op("ST", "g1vnn")
    # Q3 stage (Chamberlin SVF, f0 72.15 Hz, Q 2.706) + R26 / C37 DC path
    b.kreg("g1svf", 2 * math.sin(math.pi * SVF_F0 / FS), "F", clamp=False)
    b.kreg("g1kdc", kconv(6339), "F")
    b.op("LD", "g1bp")
    b.op("MUL", "g1svf")
    b.op("ADD", "g1lp")
    b.op("ST", "g1lp")
    b.op("LD", "g1vnn")
    b.op("ADDI", imm=q(-VBE))
    b.op("ST", "g1x")
    b.op("SUB", "g1lp")
    b.op("MACI", "g1bp", imm=q(-SVF_QI))
    b.op("MUL", "g1svf")
    b.op("ADD", "g1bp")
    b.op("ST", "g1bp")
    b.op("LD", "g1x")
    b.op("RCM", "g1dc", b.r("g1kdc"))
    # yq3 / 16 (lp, bp can reach tens of volts: keep the sum inside Q24), clamp to the collector swing, x 16
    lin(b, None, 0.0, [("g1lp", G_LP / 16), ("g1bp", G_BP / 16), ("g1dc", -G_DC / 16)])
    b.op("MINI", imm=q((12.0 - VCMIN) / 16))
    b.op("MAXI", imm=0)
    b.op("MULI", imm=q(-16.0))
    b.op("ADDI", imm=q(12.0 + VD))                               # Q3 collector + CR3 drop
    b.op("MINI", imm=q(VCOMAX))
    b.op("ADDI", imm=q(-VCOMAX))                                 # AC part (CR3 / R32 node - rest level)
    b.op("ST", "g1co")


def mixer(b, spectar):
    """tone / CPU music: 10K pot (mid) + .22u (C44 / C41); sources x 0.5 (pots at mid) into the LM324 summer;
    60 Hz output high-pass (22K + .1u), 12 kHz amp roll-off; 2800 counts per volt as the RTL"""
    b.kreg("g1kt", kconv(189370), "F")
    b.kreg("g1khp", kconv(35817), "F")
    k = TIDLE * 256 / 26                                         # count of 26 phi2 high -> 1.7 V at the wiper
    b.op("LDL", 0, b.src(TONE, 0))
    b.op("MULI", imm=q(k))
    b.op("RCM", "g1tl", b.r("g1kt"))
    b.op("LDL", 0, b.src(MUS, 0))
    b.op("MULI", imm=q(k))
    b.op("RCM", "g1ml", b.r("g1kt"))
    b.op("ADD", "g1tl")
    vol(b, "M")
    b.op("ST", "g1mm")
    if spectar:
        b.op("LD", "g1mc")
    else:
        b.op("LD", "g1sq")                                       # 556 output high 3.3 V straight to R29
        b.op("MULI", imm=q(V556))
        b.op("ADD", "g1mc")
    b.op("ADD", "g1co")
    b.op("MULI", imm=q(0.5))
    vol(b, "E")
    b.op("ADD", "g1mm")
    b.op("ST", "g1mix")
    b.op("RCM", "g1hl", b.r("g1khp"))
    b.op("LD", "g1mix")
    b.op("SUB", "g1hl")
    b.op("RC", "g1ol", imm=q(kconv(5835373)))                   # 12 kHz (#unverified in the RTL)
    b.op("MULI", imm=q(OUT_SCALE))
    b.op("OUT")


def _inits(b, spectar):
    for r, v in (("g1vn", NOFS), ("g1c14", v28(1956892000)), ("g1vb", v28(1956892000)), ("g1ve", v28(1782000000)),
                 ("g1v1", TD1), ("g1lp", -VBE), ("g1dc", -VBE), ("g1tl", TIDLE), ("g1mix", TIDLE),
                 ("g1hl", TIDLE)):
        b.init(r, v)
    if not spectar:
        b.init("g1q", VW - v28(1782000000))
        b.init("g1v28", TD1)
        b.init("g1dir", 1.0)


def _board(name, spectar):
    b = Board(name)
    _inits(b, spectar)
    noise(b)
    shoot_env(b, spectar)
    if spectar:
        ne556(b, True)
        b.op("LD", "g1sq")                                       # 556 out AC coupled (C12) into the MC3340
        b.op("MULI", imm=q(2 * SQIN))
        b.op("ADDI", imm=q(-SQIN))
        b.op("ST", "g1in")
        mc_gain(b)
        mc_out(b, "g1in")
        b.op("ST", "g1mc")
    else:
        vco566(b)
        ne556(b, False)
    crash(b, spectar)
    mixer(b, spectar)
    return b.finish()


def targ():
    return _board("targ", False)


def spectar():
    return _board("spectar", True)


if __name__ == "__main__":
    for f in (targ, spectar):
        p = f()
        print(f"{p.name:8s} words {len(p.code):4d}  worst units {p.worst_path():3d}  registers {len(p.regs):3d}")

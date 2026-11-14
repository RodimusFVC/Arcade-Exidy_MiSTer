"""Exidy Circus-family discrete audio as discrete-sound-engine programs (tools/dsnd.py, rtl/rodimus/dsnd_engine/dsnd_engine.sv).

Port of rtl/boards/exidy_circus/circus_snd.sv (HW-confirmed by the user, the primary reference) from its 88.2 kHz
sequencer to the engine's FS = 27137 Hz. Same circuit model, same order of evaluation, same states; every rate
re-derived for FS from the component values in verilator/circussnd/gen_consts.py. Machines (MAME machine config):
  circus()   Circus / Trapeze: Circus audio board (CIRCUS.pdf pp23-24)
  ripcord()  Rip Cord: Circus board + Y7 "whistle" (no schematic, #unverified, as the RTL)
  robotbwl() Robot Bowl: bit-triggered sounds from the same blocks (no schematic, #unverified, as the RTL)
  crash()    Crash audio board CR30-3161-B (CRASH pp26-27, audio-sheet $xx codes)
Sources: 0 = the 8000 output latch (static levels, D7 = /GAME mute, D3-D0 = sprite image), 5 = OSD volumes (music
path x _fM, effects x _fE, as the RTL's vol_music / vol_sfx), 6 / 7 = Game Audio cap groups:
  T = envelope / hold caps (C15, C20, C31, miss node-A 6.8u, 556 mono C18), F = filter / coupling caps (bridged-T
  C11/C19, C12, C37, C44, Robot Bowl footstep RC), O = oscillator caps (566 C25 / C23, phase-shift ladders, 556 C22).
Changes vs the RTL (rate conversion; comparison scripts in verilator/snd/circus/):
  - oscillators are 32-bit wrapping phase accumulators (frequency exact at any FS; same frequency as the RTL's 24-bit
    phase / reflected 566 triangles); the 566 triangles start at 0 going up as in the RTL
  - the noise source and its nonlinear consumers (CR6 clamp + Q6 collector for POP / hit, CR6 clamp for CRASH / roll,
    the rectified noise FM of the SKID 566) run at 3 x FS (81.4 kHz) and are averaged: at 1 x FS the clipped noise
    folds into the audio band (POP +0.5 dB / centroid +15 %, SKID pitch -10 %); LFSR amplitude x sqrt(rate / 88.2k)
  - the POP / hit R23 discharge uses X of the first sub-sample (same expectation as the average)
  - MC3340 gain = exact 2^-att (EXP) instead of the RTL's 1/32-octave table (<= 1.1 % step)
  - 556 beep astable = exact phase timer (1023 Hz as the schematic / MAME; the RTL's 88.2 kHz RC loop rounds the
    period to 87 ticks = 1013.8 Hz), edge samples at their high fraction
  - Robot Bowl only (budget): the bounce hold / drive, demerit node A / emitter / MC3340 gain and reward sweep / gate
    update on alternate samples with rates for 2 / FS
  - the music line (5MUSIC) is point-sampled once per engine sample unless MUSIC_BOX (see below)
  - pos() clamps that cannot act are left out: discharges stay >= 0, bounce DC drop <= 12.5 V < 14.8 V, 566
    collector max (ve <= VESAT), MC3340 output clamp (|out| <= 2.68 V < 3 V)
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dsnd_rate  # noqa: F401,E402  master assembler + this core's FS, before any dsnd import
from dsnd import Board, q, FS, ONE  # noqa: E402

FS_RTL = 705600 / 8                    # circus_snd.sv model rate
# The RTL box-averages the music line over 8 phi2; the engine sees only the latch, sampled once per sample. With
# MUSIC_BOX the programs read src 1 = phi2 cycles (26 per sample) with the music line active (Circus / Rip Cord /
# Crash: latch[6:4] == 3'b001, Robot Bowl: latch[3]), supplied by rtl/exidy_dispatcher.sv (c_mus); point-sampled music
# has inharmonic products at about -20 dB, box-averaged about -45 dB
MUSIC_BOX = True                 # rtl/exidy_dispatcher.sv supplies src 1 (c_mus box average)
DT = 1.0 / FS


def kexp(tau):
    return 1.0 - math.exp(-DT / tau)


def kf(fc):
    return 1.0 - math.exp(-2.0 * math.pi * fc * DT)


def par(*r):
    return 1.0 / sum(1.0 / x for x in r)


PH = 2.0 ** 32 / FS / 2.0 ** 24        # phase-register units (2^32 = one cycle) per Hz, as a Q24 multiplier
SHR7 = 1 << 17                         # MULI by 2^17 / 2^24 = arithmetic >> 7: 32-bit phase -> x in [-1, 1) Q24

# ---------------------------------------------------------------- constants (gen_consts.py, values unchanged)
BETA = 150.0
VBE = 0.65
VD = 0.6
VCH = 15.0 - 0.6
VNG = 560 / 660
KQ6 = 1.1
VOP = 15 * 100 / 122
VBO = 5.0 - 0.6
VOB = 15 * 100 / 147
KB = 200 * 11e3 / 660e3
VDMAX = 14.8
VDIE = 0.9
KG, VGX = 1.6, 2.5
F0_BT, Q_BT = 72.153, 2.7057
G_LP, G_BP, G_DC = 10.693, 5.428, 7.893
TRI = 1.2
VX1, KV1 = 12.62, 77.8                 # 566 U4: f = 77.8 Hz/V x (12.62 - Vc)
VK1, S1 = 3.92, 25 / 6.0206
VK2, S2 = 4.25, 45 / 6.0206
MC_G = 4.47 / 2                        # MC3340 4.47 x 0.5 (triangle via C26)
VESAT = (15 - 0.2) * 1.2e3 / 3.0e3
GXM = 1.5
VQ12KQ = (5.0 - VBE) * BETA * 11e3 / 560e3      # Crash Q12 collector drop (12.82 V)
V5L, V5H = 15 * 47 / 51.7, 15 * 56 / 60.7
KF2HZ = 2 / (2.2e3 * 0.47e-6 * 15)     # U10 Hz per volt below 15 V
VTH, VTL = 10 / 3, 5 / 3
GA, GB, GH, GL, GM, G2M, G2W, GBP, GMU = 1.0, 1.0, 0.8, 0.5, 3.6, 4.0, 5.0, 3.0, 3.6
OSC = 1600.0 / 32768                   # RTL 1600 counts per volt -> engine full scale
LIM1, LIM2 = 20000 / 32768, 52000 / 32768
WARM = round(8192 / FS_RTL * FS)       # RTL: output held 0 for 8192 ticks, bus HPF fast meanwhile


def _miss_consts():
    """gen_consts.py VCO1 node A / base divider (Circus miss, Robot Bowl demerit, Crash skid)"""
    rin = (BETA + 1) * 1.2e3

    def bnode(ra, extra):
        g = 1 / ra + 1 / rin + extra
        return (1 / ra) / g, (VBE / rin) / g
    gbi, obi = bnode(39e3, 0)
    gba, oba = bnode(39e3, 1 / 68e3)
    bsat = VESAT + VBE
    tsc = 0.47 / 0.319
    tai = (15 / 100e3 + bsat / 39e3) / (1 / 100e3 + 1 / 39e3)
    taui = tsc * 6.8e-6 * par(100e3, 39e3)
    ga_ = (1 - gba) / 39e3
    oa_ = oba / 39e3
    taa = (15 / 100e3 + oa_) / (1 / 100e3 + ga_)
    taua = tsc * 6.8e-6 * par(100e3, 1 / ga_)
    gki, oki = bnode(120e3, 0)
    gka, oka = bnode(120e3, 1 / 68e3)
    return dict(tai=tai, taui=taui, taa=taa, taua=taua, gbi=gbi, obi=obi, gba=gba, oba=oba,
                vski=min(15 * gki + oki - VBE, VESAT), vska=min(15 * gka + oka - VBE, VESAT))


MC = _miss_consts()


# ---------------------------------------------------------------- helpers
def kreg1m(b, reg, k, g):
    """reg = 1 - k x group factor (change block): the keep factor of an Euler discharge"""
    body, b.code = b.code, b.kcode
    b.groups.add(g)
    b.op("LDI", imm=q(-k))
    b.op("MUL", "_f" + g)
    b.op("ADDI", imm=ONE)
    b.op("MAXI", imm=0)
    b.op("ST", reg)
    b.kcode, b.code = b.code, body


def kreg_ph(b, reg, hz, g="O"):
    """phase step for hz (phase register units), scaled by the group (f ~ 1 / C)"""
    b.kreg(reg, hz * PH, g, clamp=False)


def vol(b, g):
    """acc *= OSD volume ("M" / "E"): level / 8 (dsnd.Board.vol)"""
    b.vol(g)


def flag(b, *terms):
    """F = AND of latch bits: terms (bit, value)"""
    for i, (bit, val) in enumerate(terms):
        b.op("BIT" if i == 0 else "FAND", 0 if val else 1, b.src(0, bit))


def circus_code(h):
    """Circus 74S138: A = D6, B = D5, C = D4 -> index h = D4*4 + D5*2 + D6 (static one-of-8 level)"""
    return ((6, h & 1), (5, (h >> 1) & 1), (4, (h >> 2) & 1))


def crash_code(c):
    """Crash 14E: code = D6..D4 (audio-sheet $xx annotations)"""
    return ((6, (c >> 2) & 1), (5, (c >> 1) & 1), (4, c & 1))


def flag_reg(b, reg, *terms):
    """reg = 1.0 if the latch matches else 0; leaves F"""
    flag(b, *terms)
    b.op("LDI", imm=0)
    b.op("LDIF", imm=ONE)
    b.op("ST", reg)


def reg_flag(b, reg):
    """F = reg >= 0.5"""
    b.op("LD", reg)
    b.op("CMPI", imm=q(0.5))


# ---------------------------------------------------------------- circuit blocks (order = circus_snd.sv ops)
NOISE_OS = 3                           # noise and its nonlinear consumers run at 3 x FS (81.4 kHz, near the RTL's 88.2)


def nos(b):
    return getattr(b, "nos", NOISE_OS)


def acc_into(b, reg, j):
    """sub-sample accumulator: j = 0 stores, later sub-samples add"""
    if j:
        b.op("ADD", reg)
    b.op("ST", reg)


def noise_loop(b, subs):
    """Q2 junction + uA748 + Q3 at nos(b) sub-samples per sample: LFSR (amplitude x sqrt(rate / 88.2k): the RTL's
    spectral density), 800 Hz one-pole, Q3 gain 37 around 1 V, clamp 0.1 .. 14.8; cn_vnd = WHITE NOISE + VD. Each
    consumer sub(j) runs on every sub-sample (acc = cn_vnd on entry for the first one)"""
    fso = nos(b) * FS
    a = math.sqrt(fso / FS_RTL)
    k = 1.0 - math.exp(-2.0 * math.pi * 800 / fso)
    b.init("cn_vnd", 1.0 + VD)
    for j in range(nos(b)):
        b.op("NOISE", 0, 0)                        # filter state kept x 37 (Q3 gain folded in)
        b.op("LDI", imm=q(-37.0 * a))
        b.op("LDIF", imm=q(37.0 * a))
        b.op("RC", "cn_nl", imm=q(k))
        b.op("ADDI", imm=q(1.0 + VD))
        b.op("MAXI", imm=q(0.1 + VD))
        b.op("MINI", imm=q(14.8 + VD))
        b.op("ST", "cn_vnd")
        for i, sub in enumerate(subs):
            if i:
                b.op("LD", "cn_vnd")
            sub(j)


def envelope(b, p, trig, c, r24):
    """7407 / R20 / CR7 charge of C (1.2K), discharge via R24 and via R23 100K into X (X = sub-sample average of the
    previous sample); p+"c" = min(P, VBE + (P - VBE) R21 / (R21 + R23)): X before the CR6 clamp to the noise.
    p = register prefix, trig() sets F"""
    b.kreg(p + "kc", kexp(1.2e3 * c), "T")
    kreg1m(b, p + "kd", DT / (r24 * c), "T")
    b.kreg(p + "kx", -DT / (100e3 * c), "T", clamp=False)
    trig()
    at = b.skip_if(False)
    b.op("LDI", imm=q(VCH))
    b.op("RCM", p + "p", b.r(p + "kc"))
    b.land(at)
    b.op("LD", p + "p")
    b.op("SUB", p + "x")
    b.op("MAXI", imm=0)
    b.op("MUL", p + "kx")
    b.op("ST", "cn_t")
    b.op("LD", p + "p")
    b.op("MUL", p + "kd")
    b.op("ADD", "cn_t")
    b.op("ST", p + "p")
    b.op("MULI", imm=q(VNG))
    b.op("ADDI", imm=q(VBE * (1 - VNG)))
    b.op("CMP", p + "p")
    b.op("LDF", p + "p")
    b.op("ST", p + "c")


def x_sub(b, p, j):
    """acc = noise + VD -> X = min(c, noise + VD) (CR6); returns with acc = X"""
    b.op("CMP", p + "c")
    b.op("LDF", p + "c")


def pop_sub(b, j):
    """EnvA X and the Q6 collector node (rel. idle) per sub-sample, summed into ea_os. The R23 discharge uses X of
    the first sub-sample (same expectation as the average; the C15 time constant averages it)"""
    x_sub(b, "ea_", j)
    if j == 0:
        b.op("ST", "ea_x")
    b.op("MULI", imm=q(-KQ6))
    b.op("ADDI", imm=q(15 + KQ6 * VBE + VD - VOP))
    b.op("MAXI", imm=q(0.2 + VD - VOP))
    b.op("MINI", imm=0)
    acc_into(b, "ea_os", j)


def pop_post(b):
    b.op("LD", "ea_os")
    b.op("MULI", imm=q(1.0 / nos(b)))
    b.op("ST", "ea_o")


def crash_sub(b, j):
    x_sub(b, "eb_", j)
    acc_into(b, "eb_xs", j)


def crash_post(b):
    """EnvB X average through the bridged-T C11/C19 .01 R11 33K (SVF fit 72.15 Hz Q 2.71) + R61 150K / C12 .1u;
    out eb_o = Q6 collector node rel. idle"""
    b.kreg("eb_f", 2 * math.sin(math.pi * F0_BT / FS), "F", clamp=False)
    b.kreg("eb_kdc", kexp(150e3 * 0.1e-6), "F")
    b.init("eb_lp", -VBE)
    b.init("eb_dc", -VBE)
    b.op("LD", "eb_xs")
    b.op("MULI", imm=q(1.0 / nos(b)))
    b.op("ST", "eb_x")
    b.op("LD", "eb_bp")                            # lp += f bp
    b.op("MUL", "eb_f")
    b.op("ADD", "eb_lp")
    b.op("ST", "eb_lp")
    b.op("LD", "eb_x")                             # hp = (X - VBE) - lp - bp / Q; bp += f hp
    b.op("SUB", "eb_lp")
    b.op("MACI", "eb_bp", imm=q(-1 / Q_BT))
    b.op("ADDI", imm=q(-VBE))
    b.op("MUL", "eb_f")
    b.op("ADD", "eb_bp")
    b.op("ST", "eb_bp")
    b.op("LD", "eb_x")
    b.op("ADDI", imm=q(-VBE))
    b.op("RCM", "eb_dc", b.r("eb_kdc"))
    b.op("LD", "eb_lp")                            # collector = 15 - (lp G_LP + bp G_BP - dc G_DC), CR5 / R28-R29 node
    b.op("MULI", imm=q(-G_LP))
    b.op("MACI", "eb_bp", imm=q(-G_BP))
    b.op("MACI", "eb_dc", imm=q(G_DC))
    b.op("ADDI", imm=q(15 + VD - VOP))
    b.op("MAXI", imm=q(0.2 + VD - VOP))
    b.op("MINI", imm=0)
    b.op("ST", "eb_o")


def sine_out(b, p, amp_reg, dc_reg=None, dc_const=None):
    """acc = 32-bit phase -> parabolic sine s = 4x(1-|x|); out p+"o" = min(VOB, 15 - clamp(dc + s amp, 0, VDMAX) + VD)
    - VOB (R38 / R39 node behind CR11 / CR18)"""
    b.op("MULI", imm=SHR7)
    b.op("ST", "cn_t")
    b.op("ABS")
    b.op("MULI", imm=q(4.0))
    b.op("ADDI", imm=q(-4.0))
    b.op("MUL", "cn_t")                           # -s
    b.op("MUL", amp_reg)
    if dc_reg:
        b.op("SUB", dc_reg)
    else:
        b.op("ADDI", imm=q(-dc_const))
    b.op("MINI", imm=0)
    b.op("MAXI", imm=q(-VDMAX))
    b.op("ADDI", imm=q(15 + VD - VOB))
    b.op("MINI", imm=0)
    b.op("ST", p + "o")


def alternate(b, fa, fb):
    """fa() on odd samples, fb() on even ones (slow parts at FS / 2, rates derived for 2 / FS)"""
    b.op("LD", "cn_alt")
    b.op("MULI", imm=q(-1.0))
    b.op("ADDI", imm=ONE)
    b.op("ST", "cn_alt")
    b.op("CMPI", imm=q(0.5))
    at = b.skip_if(False)
    fa()
    at2 = b.jump()
    b.land(at)
    fb()
    b.land(at2)


def bounce_slow(b, p, trig, c, r34, kae_tau, dt=DT):
    """Phase-shift oscillator hold / drive (Q7 high bounce C20 1u R34 270K / Q12 low bounce C31 2.2u R53 470K): hold
    cap charged via R30 330 + CR10 / CR17, discharged via R34 and the base path 660K (stays >= 0, <= VBO); DC
    collector drop p+"d" = pos(h - VBE) KB (<= 12.5 V < VDMAX), amplitude build-up p+"ae" toward
    d x clamp((h - VDIE) KG, 0, VGX). dt = update interval"""
    b.kreg(p + "kc", 1 - math.exp(-dt / (330 * c)), "T")
    kreg1m(b, p + "kd", dt / (r34 * c), "T")
    b.kreg(p + "kb", -dt / (660e3 * c), "T", clamp=False)
    trig()
    at = b.skip_if(False)
    b.op("LDI", imm=q(VBO))
    b.op("RCM", p + "h", b.r(p + "kc"))
    b.land(at)
    b.op("LD", p + "h")
    b.op("ADDI", imm=q(-VBE))
    b.op("MAXI", imm=0)
    b.op("MUL", p + "kb")
    b.op("ST", "cn_t")
    b.op("LD", p + "h")
    b.op("MUL", p + "kd")
    b.op("ADD", "cn_t")
    b.op("ST", p + "h")
    b.op("ADDI", imm=q(-VBE))
    b.op("MAXI", imm=0)
    b.op("MULI", imm=q(KB))
    b.op("ST", p + "d")
    b.op("LD", p + "h")
    b.op("ADDI", imm=q(-VDIE))
    b.op("MULI", imm=q(KG))
    b.op("MAXI", imm=0)
    b.op("MINI", imm=q(VGX))
    b.op("MUL", p + "d")
    b.op("RC", p + "ae", imm=q(1 - math.exp(-dt / kae_tau)))


def bounce_fast(b, p, f0, f1):
    """phase += f0 + f1 x hold voltage (ladder caps: group O), parabolic sine -> p+"o" """
    kreg_ph(b, p + "f0", f0)
    kreg_ph(b, p + "f1", f1)
    b.op("LD", p + "h")
    b.op("MUL", p + "f1")
    b.op("ADD", p + "f0")
    b.op("ADD", p + "ph")
    b.op("ST", p + "ph")
    sine_out(b, p, p + "ae", dc_reg=p + "d")


def bounce(b, p, trig, c, r34, kae_tau, f0, f1):
    bounce_slow(b, p, trig, c, r34, kae_tau)
    bounce_fast(b, p, f0, f1)


def miss_slow(b, trig, crash=False, dt=DT):
    """Q11 + NE566 U4 + MC3340 U5 drive: Circus MISS / Robot Bowl demerit (node A 6.8u via 100K / 39K, 68K to the
    7407), Crash SKID (R43 120K / R41 68K, no node-A cap). vc_g = MC3340 gain 2^-att, vc_k0 = VX1 - vc"""
    b.init("vc_ve", VESAT)
    if not crash:
        b.init("vc_a", MC["tai"])
        b.kreg("vc_ki", 1 - math.exp(-dt / MC["taui"]), "T")
        b.kreg("vc_ka", 1 - math.exp(-dt / MC["taua"]), "T")
        trig()
        b.op("LD", "vc_ki")
        b.op("LDF", "vc_ka")
        b.op("ST", "vc_k")
        b.op("LDI", imm=q(MC["tai"]))
        b.op("LDIF", imm=q(MC["taa"]))
        b.op("RCM", "vc_a", b.r("vc_k"))
        b.op("LDI", imm=q(MC["gbi"]))
        b.op("LDIF", imm=q(MC["gba"]))
        b.op("MUL", "vc_a")
        b.op("ST", "cn_t")
        b.op("LDI", imm=q(MC["obi"] - VBE))
        b.op("LDIF", imm=q(MC["oba"] - VBE))
        b.op("ADD", "cn_t")
        b.op("MINI", imm=q(VESAT))
    else:
        trig()
        b.op("LDI", imm=q(MC["vski"]))
        b.op("LDIF", imm=q(MC["vska"]))
    b.op("RC", "vc_ve", imm=q(1 - math.exp(-dt / 0.0005)))   # emitter (KVE); ve stays <= VESAT: vc = 15 - 1.5 ve
    b.op("ADDI", imm=q(-VK1))                      # MC3340 gain 2^-att, att = S1 pos(ve - VK1) + S2 pos(ve - VK2)
    b.op("MAXI", imm=0)
    b.op("MULI", imm=q(-S1))
    b.op("ST", "cn_t")
    b.op("LD", "vc_ve")
    b.op("ADDI", imm=q(-VK2))
    b.op("MAXI", imm=0)
    b.op("MULI", imm=q(-S2))
    b.op("ADD", "cn_t")
    b.op("EXP")
    b.op("ST", "vc_g")
    b.op("LD", "vc_ve")                            # f = 77.8 x pos(VX1 - vc [- noise])
    b.op("MULI", imm=q(1.5))
    b.op("ADDI", imm=q(VX1 - 15))
    b.op("ST", "vc_k0")


def miss_fast(b):
    """no noise into pin 5 (Circus / Robot Bowl)"""
    b.op("LD", "vc_k0")
    b.op("MAXI", imm=0)
    kreg_ph(b, "vc_kf", KV1)
    _vco_out(b)


def miss_vco(b, trig):
    miss_slow(b, trig)
    miss_fast(b)


def vco_sub(b, j):
    """Crash skid: noise HPF (C37 .02u into R45 1.8K) x 2.5 into pin 5, rectified frequency per sub-sample (sum)"""
    b.init("vc_hn", 1.0 + VD)
    b.kreg("vc_khn", 1.0 - math.exp(-1.0 / (1.8e3 * 0.02e-6) / (nos(b) * FS)), "F")
    b.op("RCM", "vc_hn", b.r("vc_khn"))
    b.op("SUB", "cn_vnd")
    b.op("MULI", imm=q(2.5))
    b.op("ADD", "vc_k0")
    b.op("MAXI", imm=0)
    acc_into(b, "vc_ss", j)


def vco_post(b):
    kreg_ph(b, "vc_kf", KV1 / nos(b))
    b.op("LD", "vc_ss")
    _vco_out(b)


def _vco_out(b):
    """acc = pos(VX1 - vc) -> 566 phase (C25: group O), triangle +-TRI x MC3340 4.47 / 2 x 2^-att -> vc_o"""
    b.init("vc_ph", -0.5 * 2 ** 31 / ONE)         # triangle starts at 0 going up (RTL)
    b.op("MUL", "vc_kf")
    b.op("ADD", "vc_ph")
    b.op("ST", "vc_ph")
    b.op("MULI", imm=SHR7)
    b.op("ABS")
    b.op("MULI", imm=q(-2 * TRI * MC_G))
    b.op("ADDI", imm=q(TRI * MC_G))
    b.op("MUL", "vc_g")
    b.op("ST", "vc_o")


def tri_out(b, reg, gain_reg=None):
    """acc = 32-bit phase -> triangle +-TRI [x gain_reg] -> reg"""
    b.op("MULI", imm=SHR7)
    b.op("ABS")
    b.op("MULI", imm=q(-2 * TRI))
    b.op("ADDI", imm=q(TRI))
    if gain_reg:
        b.op("MUL", gain_reg)
    b.op("ST", reg)


def sweep_slow(b, trig_reg, ts, tga, tgr, dt=DT):
    """Rip Cord whistle / Robot Bowl reward drive (no schematic, #unverified as the RTL): a new trigger restarts the
    sweep m 0 -> 1 (tau ts, held when released), gate g attack tga / release tgr"""
    b.op("LD", trig_reg)                           # rising edge: m = 0
    b.op("SUB", "v2_w")
    b.op("CMPI", imm=q(0.5))
    b.op("LDI", imm=0)
    b.op("STF", "v2_m")
    b.op("LD", trig_reg)
    b.op("ST", "v2_w")
    b.op("CMPI", imm=q(0.5))
    b.op("LDI", imm=q(1 - math.exp(-dt / tgr)))
    b.op("LDIF", imm=q(1 - math.exp(-dt / tga)))
    b.op("ST", "v2_kg")
    at = b.skip_if(False)
    b.op("LDI", imm=ONE)
    b.op("RC", "v2_m", imm=q(1 - math.exp(-dt / ts)))
    b.land(at)
    b.op("LD", trig_reg)
    b.op("RCM", "v2_g", b.r("v2_kg"))


def sweep_fast(b, w0, w1):
    """f = 1 kHz/V x (15 - (w0 + w1 m)), triangle x g -> v2_o"""
    b.op("LD", "v2_m")
    b.op("MULI", imm=q(-w1))
    b.op("ADDI", imm=q(15 - w0))
    b.op("MAXI", imm=0)
    b.op("MULI", imm=q(1000 * PH))
    b.op("ADD", "v2_ph")
    b.op("ST", "v2_ph")
    tri_out(b, "v2_o", "v2_g")


def sweep_vco(b, trig_reg, w0, w1, ts, tga, tgr):
    sweep_slow(b, trig_reg, ts, tga, tgr)
    sweep_fast(b, w0, w1)


def mixer(b, terms, music_reg, mus_gain=GMU):
    """sfx sum x _fE + music x GMU x _fM, /GAME (D7) shorts the bus; bus HPF 50 Hz (400 Hz while warming up), LPF
    6 kHz, 1600 counts / V, RTL soft limiter (slope 1/4 above 20000, 1/16 above 52000); output held 0 ~93 ms"""
    b.op("LD", "cn_wc")                            # warm-up counter (samples)
    b.op("ADDI", imm=1)
    b.op("MINI", imm=WARM)
    b.op("ST", "cn_wc")
    b.op("CMPI", imm=WARM)
    b.op("LDI", imm=q(kf(400)))
    b.op("LDIF", imm=q(kf(50)))
    b.op("ST", "cn_hk")
    (r0, g0), rest = terms[0], terms[1:]
    b.op("LD", r0)
    b.op("MULI", imm=q(g0))
    for r, g in rest:
        b.op("MACI", r, imm=q(g))
    vol(b, "E")
    b.op("ST", "cn_t")
    b.op("LD", music_reg)
    b.op("MULI", imm=q(mus_gain))
    vol(b, "M")
    b.op("ADD", "cn_t")
    b.op("BIT", 0, b.src(0, 7))                    # /GAME
    b.op("LDIF", imm=0)
    b.op("ST", "cn_mx")
    b.op("RCM", "cn_hp", b.r("cn_hk"))
    b.op("MULI", imm=q(-1.0))
    b.op("ADD", "cn_mx")
    b.op("RC", "cn_lp", imm=q(kf(6000)))
    b.op("MULI", imm=q(OSC))
    b.op("ST", "cn_t")                             # = min(x, x/4 + 3 L1/4) then slope 1/16 above L2 (odd):
    b.op("MAXI", imm=q(-LIM1))                     # x/16 + 3/4 clamp(x, L1) + 3/16 clamp(x, L2)
    b.op("MINI", imm=q(LIM1))
    b.op("MULI", imm=q(0.75))
    b.op("MACI", "cn_t", imm=q(1 / 16))
    b.op("ST", "cn_t2")
    b.op("LD", "cn_t")
    b.op("MAXI", imm=q(-LIM2))
    b.op("MINI", imm=q(LIM2))
    b.op("MULI", imm=q(3 / 16))
    b.op("ADD", "cn_t2")
    b.op("ST", "cn_t")
    b.op("LD", "cn_wc")
    b.op("CMPI", imm=WARM)
    b.op("LDI", imm=0)
    b.op("LDF", "cn_t")
    b.op("OUT")


def music_level(b, terms, level, box, reg="cm_l"):
    """music node level while the music line is active (latch decode terms): point-sampled from src 0, or with
    box=True the box average from src 1 (phi2 cycles active in the sample, 0 .. 26: needs the RTL source, see
    MUSIC_BOX)"""
    if box:
        b.op("LDLM", 0, b.src(1, 0), imm=0xFF | (16 << 8))
        b.op("MULI", imm=q(level * 256 / 26))
    else:
        flag(b, *terms)
        b.op("LDI", imm=0)
        b.op("LDIF", imm=q(level))
    b.op("ST", reg)


# ---------------------------------------------------------------- machines
def _circus_board(name, whistle, box):
    b = Board(name)
    envelope(b, "ea_", lambda: flag(b, *circus_code(2)), 1e-6, 510e3)          # Y2 5POP
    noise_loop(b, [lambda j: pop_sub(b, j)])
    pop_post(b)
    bnc = lambda: flag(b, *circus_code(3))                                      # Y3 5BOUNCE (high + low)
    bounce(b, "bh_", bnc, 1e-6, 270e3, 0.008, 353.7, 4.4)
    bounce(b, "bl_", bnc, 2.2e-6, 470e3, 0.025, 77.2, 1.67)
    miss_vco(b, lambda: flag(b, *circus_code(1)))                               # Y1 5MISS
    terms = [("ea_o", GA), ("bh_o", GH), ("bl_o", GL), ("vc_o", GM)]
    if whistle:                                                                 # Y7 whistle #unverified
        flag_reg(b, "cw_on", *circus_code(7))
        sweep_vco(b, "cw_on", 15 - 2.2, 2.2 - 0.9, 0.6, 0.005, 0.06)
        terms.append(("v2_o", G2W))
    music_level(b, circus_code(4), -(3.4 - 0.7), box)                         # Y4 5MUSIC low: 0.7 V vs 3.4 V
    mixer(b, terms, "cm_l")
    return b.finish()


def circus(box=MUSIC_BOX):
    """Circus / Trapeze (circus_snd game 0)"""
    return _circus_board("circus", False, box)


def ripcord(box=MUSIC_BOX):
    """Rip Cord (circus_snd game 1): Circus board + Y7 whistle"""
    return _circus_board("ripcord", True, box)


def robotbwl(box=MUSIC_BOX):
    """Robot Bowl (circus_snd game 2): rising edge of a latch bit starts a fixed drive pulse (#unverified, no
    schematic): D6 hit 20 ms (EnvA, C 2.2u), D5 roll 30 ms (EnvB, C 10u R24 510K), D4 drop 20 ms (both bounce
    oscillators), D1 demerit 500 ms (miss VCO), D0 reward 350 ms (sweep VCO); D3 = footsteps level (RC 10K / .47u)"""
    b = Board("robotbwl")
    for bit, ms in ((6, 20), (5, 30), (4, 20), (1, 500), (0, 350)):
        p = f"rb{bit}_"
        b.op("BIT", 0, b.src(0, bit))
        b.op("LDI", imm=0)
        b.op("LDIF", imm=ONE)
        b.op("ST", "cn_t")
        b.op("SUB", p + "q")
        b.op("CMPI", imm=q(0.5))                   # F = rising edge
        b.op("LD", "cn_t")
        b.op("ST", p + "q")
        b.op("LD", p + "t")
        b.op("ADDI", imm=-1)
        b.op("MAXI", imm=0)
        b.op("LDIF", imm=round(ms * 1e-3 * FS))    # samples
        b.op("ST", p + "t")
    tm = lambda bit: (lambda: (b.op("LD", f"rb{bit}_t"), b.op("CMPI", imm=1)))
    envelope(b, "ea_", tm(6), 2.2e-6, 510e3)
    envelope(b, "eb_", tm(5), 10e-6, 510e3)
    noise_loop(b, [lambda j: pop_sub(b, j), lambda j: crash_sub(b, j)])
    pop_post(b)
    crash_post(b)
    b.op("LD", "rb0_t")
    b.op("CMPI", imm=1)
    b.op("LDI", imm=0)
    b.op("LDIF", imm=ONE)
    b.op("ST", "rw_on")
    dt2 = 2 * DT                                   # budget: slow drive parts alternate at FS / 2
    alternate(b, lambda: (bounce_slow(b, "bh_", tm(4), 1e-6, 270e3, 0.008, dt2),
                          bounce_slow(b, "bl_", tm(4), 2.2e-6, 470e3, 0.025, dt2)),
              lambda: (miss_slow(b, tm(1), dt=dt2), sweep_slow(b, "rw_on", 0.12, 0.005, 0.08, dt2)))
    bounce_fast(b, "bh_", 353.7, 4.4)
    bounce_fast(b, "bl_", 77.2, 1.67)
    miss_fast(b)
    sweep_fast(b, 15 - 0.7, 0.7 - 1.6)
    b.kreg("rf_k", kexp(10e3 * 0.47e-6), "F")
    music_level(b, ((3, 1),), 3.4, box, "cn_t")
    b.op("RCM", "rf_l", b.r("rf_k"))
    mixer(b, [("ea_o", GA), ("eb_o", GB), ("bh_o", GH), ("bl_o", GL), ("vc_o", GM), ("v2_o", G2W)], "rf_l")
    return b.finish()


def crash(box=MUSIC_BOX):
    """Crash (circus_snd game 3): CRASH ($20), speed beep ($30 / $50, 556), SKID latch (set $40, cleared $10),
    motor ($60 LOW / $70 HI: Q12 phase shift FM-ing NE566 U10), music ($10)"""
    b = Board("crash")
    # skid latch U2A (/PRE = $40, /CLR = $10), motor HI / LOW memory, U10 pin 5 DC per code
    flag(b, *crash_code(4))
    b.op("LDI", imm=ONE)
    b.op("STF", "kk_skid")
    flag(b, *crash_code(1))
    b.op("LDI", imm=0)
    b.op("STF", "kk_skid")
    flag(b, (6, 1), (5, 1))                        # $60 / $70: motor oscillator gate
    b.op("LDI", imm=0)
    b.op("LDIF", imm=q(GXM))
    b.op("ST", "kk_mg")
    b.op("LDI", imm=0)
    b.op("LDIF", imm=q(15 - V5L))
    b.op("ST", "kk_v5")
    flag(b, *crash_code(7))
    b.op("LDI", imm=q(15 - V5H))
    b.op("STF", "kk_v5")
    b.op("LDI", imm=ONE)
    b.op("STF", "kk_mh")
    flag(b, *crash_code(6))
    b.op("LDI", imm=0)
    b.op("STF", "kk_mh")
    envelope(b, "eb_", lambda: flag(b, *crash_code(2)), 6.8e-6, 120e3)
    miss_slow(b, lambda: reg_flag(b, "kk_skid"), crash=True)
    noise_loop(b, [lambda j: crash_sub(b, j), lambda j: vco_sub(b, j)])
    crash_post(b)
    # Q12 motor oscillator: gated build-up (#unverified), DC drop 12.8 V, ladder f 50 / 60 Hz (pots mid, #unverified)
    kreg_ph(b, "mo_fl", 50.0)
    kreg_ph(b, "mo_fh", 60.0)
    b.op("LD", "kk_mg")
    b.op("RC", "mo_h", imm=q(kexp(0.02)))
    b.op("MULI", imm=q(VQ12KQ))
    b.op("RC", "mo_ae", imm=q(kexp(0.025)))
    reg_flag(b, "kk_mh")
    b.op("LD", "mo_fl")
    b.op("LDF", "mo_fh")
    b.op("ADD", "mo_ph")
    b.op("ST", "mo_ph")
    sine_out(b, "mo_", "mo_ae", dc_const=VQ12KQ)
    vco_post(b)
    # NE566 U10: node M via C44 (m tracks it), pin 5 = DC per code + 0.2 x (M - m)
    kreg_ph(b, "u10_kf", KF2HZ)
    b.kreg("u10_km", kexp(3.6e-3), "F")
    b.op("LD", "mo_o")
    b.op("RCM", "u10_m", b.r("u10_km"))
    b.op("SUB", "mo_o")
    b.op("MULI", imm=q(0.2))
    b.op("ADD", "kk_v5")
    b.op("MAXI", imm=0)
    b.op("MUL", "u10_kf")
    b.op("ADD", "u10_ph")
    b.op("ST", "u10_ph")
    tri_out(b, "u10_o")
    # 556 speed beep: U11A mono (trigger held while $30 / $50 latched, 22K / .47u), U11B astable (4.7K / 4.7K / .1u)
    flag(b, *crash_code(3))
    b.op("LDI", imm=0)
    b.op("LDIF", imm=ONE)
    b.op("ST", "sb_kb")
    flag(b, *crash_code(5))
    b.op("LDI", imm=ONE)
    b.op("STF", "sb_kb")
    b.kreg("sb_km", kexp(22e3 * 0.47e-6), "T")
    b.op("LD", "sb_kb")
    b.op("ADD", "sb_mq")
    b.op("CMPI", imm=q(0.5))                       # F = mono running or triggered
    b.op("LDI", imm=q(5.0))
    b.op("RCM", "sb_cm", b.r("sb_km"))
    b.op("LDI", imm=0)
    b.op("STNF", "sb_cm")
    b.op("LD", "sb_cm")
    b.op("CMPI", imm=q(VTH))
    b.op("LDI", imm=0)
    b.op("STF", "sb_mq")
    reg_flag(b, "sb_kb")
    b.op("LDI", imm=ONE)
    b.op("STF", "sb_mq")
    tau_c, tau_d = (4.7e3 + 4.7e3) * 0.1e-6, 4.7e3 * 0.1e-6
    th, tl, t1 = tau_c * math.log(2) * FS, tau_d * math.log(2) * FS, tau_c * math.log(3) * FS   # samples
    per = th + tl
    b.kreg("sb_dt", 1.0, "O", clamp=False)         # phase: [0, th) high, [th, per) low; out of reset th - t1 (< 0)
    b.init("sb_ap", th - t1)
    b.op("LD", "sb_ap")
    b.op("ADD", "sb_dt")
    b.op("ST", "sb_ap")
    b.op("CMPI", imm=q(per))
    b.op("ADDI", imm=q(-per))
    b.op("STF", "sb_ap")
    reg_flag(b, "sb_mq")
    b.op("LDI", imm=q(th - t1))
    b.op("STNF", "sb_ap")
    b.op("LD", "sb_ap")                            # high fraction of this sample: rising at the wrap (ap in [0, 1)),
    b.op("CMPI", imm=0)                            # falling at th; negative (first cycle) = high
    b.op("LDI", imm=ONE)
    b.op("LDF", "sb_ap")
    b.op("MINI", imm=ONE)
    b.op("ST", "cn_t")
    b.op("LDI", imm=q(th + 1))
    b.op("SUB", "sb_ap")
    b.op("MAXI", imm=0)
    b.op("CMP", "cn_t")
    b.op("LDF", "cn_t")
    b.op("MUL", "sb_mq")
    b.op("MULI", imm=q(3.3))
    b.op("ST", "sb_o")
    music_level(b, crash_code(1), -(3.4 - 0.7), box)                          # $10 = 5MUSIC low
    mixer(b, [("eb_o", GB), ("vc_o", GM), ("u10_o", G2M), ("sb_o", GBP)], "cm_l")
    return b.finish()


MACHINES = {"circus": circus, "ripcord": ripcord, "robotbwl": robotbwl, "crash": crash}

if __name__ == "__main__":
    for m, f in MACHINES.items():
        p = f()
        print(f"{m:9s} words {len(p.code):4d}  worst units {p.worst_path():3d}  registers {len(p.regs):3d}")

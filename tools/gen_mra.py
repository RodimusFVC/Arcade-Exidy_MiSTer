#!/usr/bin/env python3
"""Generate MRAs for the Exidy core straight from the MAME drivers exidy.cpp, circus.cpp, carpolo.cpp, starfire.cpp and
victory.cpp (Useful Information/mame/). Engine: tools/mra_lib.py of the Rodimus master (fleet MRA generator).

Region placement matches rtl/exidy_dispatcher.sv; images are copied as dumped.
DIP switches and the input map come from the set's MAME INPUT_PORTS.

    gen_mra.py <releases_dir> [set ...]     MRAs (no sets: every supported, working set)
    gen_mra.py --check                      every GAME() in the drivers: supported?, ROM_START parses?, regions mapped?
    gen_mra.py --rom-budget                 block-RAM footprint vs max-game packing (passaudit 5c)

Release layout: a parent set (MAME parent 0) goes to <releases>/<Title>.mra with the
trailing parentheses dropped; a clone goes to
<releases>/_alternatives/_<Parent Title>/<Full Title>.mra. A set whose zip (or its parent's) is in games/mame-artwork/ also
gets the same tree under <releases>/_artwork/ with the MAME artwork block (MRA index 6, rtl/art/artwork.sv).

Game-ID block (MRA index 1, layout v2, 151 bytes): 0 variant, 1 flags, 2 cfg2, 3 cfg, 4-11 port idle bytes, 12-19 DIP
selectors, 20-83 input map (control id per port bit), 84-147 DIP bit permutation (port bit -> DIP byte bit),
148-150 colour latches (R, G, B).
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "RodimusCoresMaster_MiSTer" / "tools"))
import mra_lib                                          # noqa: E402  fleet MRA generator engine
import mra_tidy                                         # noqa: E402  fleet MRA comment format

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dsnd_boards / dsnd

# MAME artwork (rtl/art/artwork.sv; generator code copied from the Universal core's gen_mra.py, = Irem1's):
# a set with games/mame-artwork/<set>.zip, else its parent's, gets an _artwork/ MRA. The MRA sends a 2048-byte layout
# table (from the zip's default.lay) then each PNG behind an "AWI"+id marker on ioctl index 6 (5 = discrete sound).
# OSD Game Options: View Off / 1-15 (the n-th kept view of default.lay, named in the MRA).
# game picture = the board's displayed raster (hblank / vblank window; board sim, snapshot size) = native plane
ART_NATIVE_MACHINE = {**{m: (256, 256) for m in ("venture", "mtrap", "pepper2", "teetert", "fax", "targ", "spectar", "sidetrac",
                                                 "rallys", "phantoma", "victory")},   # exidy_dispatcher blanking = MAME visarea
                      **{m: (248, 256) for m in ("circus", "ripcord", "robotbwl", "crash")},   # H 8-255
                      **{m: (256, 224) for m in ("starfire", "fireone")},                     # lines 32-255
                      "carpolo": (240, 256)}

# hiscore.v header after START_WAIT: CHECK_WAIT 00FF, CHECK_HOLD 2, WRITE_HOLD 2, WRITE_REPEATCOUNT 2,
# WRITE_REPEATWAIT FFFF (2.9 ms), PAUSEPAD 4 (Star Fire hands its scratch RAM port over 2 clocks into the pause), CHANGEMASK 0.
# The second write: gen-2 sets copy their default table end-first (0.68 ms, MAME), so the end byte matches mid-copy and
# the first restore is overwritten; the CPU then runs 2.9 ms before the dump is written again.
# START_WAIT = last boot-time write to the hiscore.dat ranges, measured per set in MAME 0.289 (write taps from frame 1,
# 45 s), + 2 frames. Later writes that fill a cleared table (gen-2 sets, 13-38 s) are gated by the end byte instead.
# fax / fax2 have none: the game clears the whole 02B4-0411 range itself ~55 s into attract mode.
# victory / victorba keep their scores in CMOS RAM (NVRAM_BY_MACHINE).
FRAME_HZ_BY_MACHINE = {"starfire": 5_000_000 / (320 * 262), "fireone": 5_000_000 / (320 * 262)}

# Fax: program 8000-FFFF at 0x00000, question ROM banks (maincpu 0x10000-0x3FFFF) at 0x20000 (rtl/exidy_dispatcher.sv)
# Side Trak: character ROM (maincpu 0x4800) at 0x15000, preloaded into the character RAM
_CIRCUS_REGIONS = {"gfx1": (0, 0x15800, 0x800), "gfx2": (0, 0x14000, 0x200), "proms": (0, 0x16000, 0x400)}
# address mask applied to a region's offset (8000-FFFF program lands at 0x0000; Targ-era 0800-3FFF in place)
REGION_MASK = {"maincpu": 0x7FFF}

# machine -> index 1 byte 3 board config (rtl/boards/exidy6502/exidy_main.sv): IRQ sources and the 8E latch wiring
# read from the schematics; [5] = Pepper II plane board / character RAM at 6000
# [6] = Fax map (work RAM 0000-07FF, IN3 / IN4, question ROM banks); Teeter Torture / Fax have no schematic: board
# wiring of their parents (Venture / Pepper II)
CFG_BY_MACHINE = {"venture": 0x0B, "mtrap": 0x17, "pepper2": 0x2B, "teetert": 0x0B, "fax": 0x6B,
                  # gen-1: collisions jumpered off, 8E D2 = /MO1 video (Targ / Spectar schematics)
                  "targ": 0x08, "sidetrac": 0x08, "spectar": 0x08, "rallys": 0x08, "phantoma": 0x08,
                  # Circus family (circus_main.sv cfg): [0] line PROMs, [1] C000.7 vblank active high, [2] vblank IRQ,
                  # [3] collision IRQ, [4] object data inverted, [5] 32-byte object PROM, [6] Rip Cord border
                  "circus": 0x09, "robotbwl": 0x33, "crash": 0x0E, "ripcord": 0x49,
                  "starfire": 0x00, "fireone": 0x00, "victory": 0x00, "carpolo": 0x00}
CFG_BY_STATE = {"trapeze_state": 0x08}   # Trapeze: no line PROMs (MAME draws none)
# machine -> index 1 byte 2 (exidy_main.sv cfg2): [0] ROM 0800-3FFF, [1] FFxx -> 3Fxx, [2] image A10/A9 grounded,
# [3] Rallys object registers, [4] 5103 coin bits active low, [5] character ROM
# Circus family: [2:0] circus_snd game, [5:4] colour overlay (exidy_dispatcher.sv: 1 circus.lay, 2 crash.lay, 3 crasha.lay)
OVERLAY_BY_LAYOUT = {"layout_circus": 0x10, "layout_crash": 0x20, "layout_crasha": 0x30}
CFG2_BY_MACHINE = {"circus": 0, "ripcord": 1, "robotbwl": 2, "crash": 3,
                   "targ": 0x07, "spectar": 0x07, "sidetrac": 0x27, "rallys": 0x1F,
                   "phantoma": 0x19}   # Phantomas: ROM high at F800 (no FFxx fold), 2K image ROM with MO2 at +0x400
# init -> colour latches (R, G, B): gen-1 colour shunts, values from MAME init_*
COLORS_BY_INIT = {"init_targ": (0x54, 0xEE, 0x6B), "init_spectar": (0xDA, 0xEE, 0x61),
                  "init_sidetrac": (0xF8, 0xDC, 0xB8)}

F_PADREV, F_PADDLE = 0x20, 0x40
PADDLE_REVERSED = {"ripcord"}
# IPT_OTHER inputs by name -> pad control (Robot Bowl hooks)
OTHER_MAP = {"Hook Right": ("BUTTON3", 1), "Hook Left": ("BUTTON4", 1)}
# analog fields the board feeds itself (exidy_stick / exidy_paddle / exidy_dial)
ANALOG_TYPES = {"PADDLE", "PADDLE_V", "AD_STICK_X", "AD_STICK_Y", "AD_STICK_Z", "DIAL", "DIAL_V"}
# extra pad-button names (not MAME buttons): Star Fire throttle on Btn 2 / Btn 3 (Arcade-Exidy.sv exidy_stick)
# Victory: MAME leaves the buttons unnamed; names follow the lamp bits on the same lines #unverified
BUTTON_NAMES = {"starfire": {2: "Throttle Up", 3: "Throttle Down"},
                "victory": {1: "Thrust", 2: "Fire", 3: "Shields", 4: "Doomsday"},
                "carpolo": {1: "Gas", 2: "Gas (Full)", 3: "Reverse"}}
# machine -> MRA header fields that differ from the 2-player joystick default. Car Polo: 4 at once, steered by each
# player's spinner / D-pad left-right (Arcade-Exidy.sv dials), no start button (a coin joins); the Start slots stay
# reserved as "-" so the pad mapping does not move
MRA_META = {"carpolo": {"players": "4 (simultaneous)", "joystick": "2-way", "special_controls": "spinner", "no_start": True}}
# machine -> {MAME button number: pad button number} (pad Btn 1-4 = A, B, X, Y)
BUTTON_REMAP = {"mtrap": {1: 3, 3: 4, 4: 1}}   # Blue A, Yellow B, Dog X, Red Y
# battery-backed CMOS RAM saved through MiSTer NVRAM (ioctl index 4; such sets have no hiscore.dat entry)
NVRAM_BY_MACHINE = {"victory": 0x800}   # F000-F7FF (rtl/boards/exidy_victory/victory_main.sv)


def coin_port(ports):
    """The coin lines also preset the IRQ flip-flop and feed 5103 bits 6 / 5 (board COIN port, active high)."""
    ports = dict(ports)
    ports["COIN"] = [dict(mask=m, kind="input", default=0, type=t, player=0, name=None, settings=[], fourway=False)
                     for m, t in ((0x01, "COIN1"), (0x02, "COIN2"))]
    return ports


def pext(v, mask):
    """bits of v under mask, packed from bit 0 (lowest mask bit first)"""
    out, i = 0, 0
    for b in range(8):
        if mask >> b & 1:
            out |= (v >> b & 1) << i
            i += 1
    return out


def osd_layout(fields):
    """port bit -> DIP-byte bit: each DIP field packed contiguous (MiSTer bits="lo,hi"), other bits after."""
    pos, nxt = {}, 0
    for f in sorted((f for f in fields if f["kind"] == "dip"), key=lambda f: f["mask"] & -f["mask"]):
        for b in range(8):
            if f["mask"] >> b & 1:
                pos[b], nxt = nxt, nxt + 1
    for b in range(8):
        if b not in pos:
            pos[b], nxt = nxt, nxt + 1
    return pos


class Exidy(mra_lib.Core):
    RBF = "Exidy"
    MRA_TIMESTAMP = "20261016000000"
    DRIVERS = ["exidy.cpp", "circus.cpp", "carpolo.cpp", "starfire.cpp", "victory.cpp"]

    # hiscore
    HISCORE_HEADER_TAIL = "00 FF 00 02 00 02 00 02 FF FF 04 00"
    HISCORE_OWN_FIRST = True
    HISCORE_INIT_FRAME = {
        "circus": 1, "circuso": 1, "springbd": 1, "crash": 1, "crasha": 1, "smash": 1, "ripcord": 1, "sidetrac": 1,
        "targ": 2, "spectar": 173, "spectarrf": 173, "spectar1": 1, "panzer": 1, "phantom": 1, "phantoma": 1,
        "rallys": 1, "rallysa": 1,
        "mtrap": 150, "mtrap2": 150, "mtrap3": 150, "mtrap4": 150, "mtrap4g": 150, "mtrapb": 150, "mtrapb2": 150,
        "venture": 39, "venture4": 1, "venture5a": 39, "venture5b": 39,
        "hardhat": 152, "pepper2": 150, "pepper27": 150,
        "starfire": 5, "starfirea": 5, "starfir2": 5, "fireone": 2,
    }
    CLK_HZ, FRAME_HZ = 22_578_000, 5_644_500 / (336 * 280)

    # artwork
    ART_INDEX = 6
    ART_NATIVE = (256, 256)
    ART_NATIVE_BY = {**{z: (248, 256) for z in ("circus", "crash", "smash", "ripcord")},   # per zip, checked against the
                     **{z: (256, 224) for z in ("starfire", "fireone")}}                       # machine in mra()

    FILE_NAME = {"victory": "Victory (Exidy)"}   # kept release name (saved .nvm / .cfg follow the MRA file name)
    PORT_OVERLAP_SPLIT = True   # Trapeze: a PORT_BIT over part of an older input field keeps that field's other bits

    # ROM budget (passaudit 5c): every index-0 window is its own dpram_dc, read in the same clock as the others
    # (rtl/exidy_dispatcher.sv load_* decodes); index0() labels each segment with the block it lands in. Anything
    # outside these windows is a 32-byte register PROM in a board or a load nothing decodes ("regs").
    ROM_BLOCKS = [(0x20000, 0x50000, "faxq"),            # Fax question banks (fax machine only), DDR3
                  (0x00000, 0x08000, "rom_main"), (0x0C000, 0x10000, "rom_snd"), (0x10000, 0x14000, "rom_cvsd"),
                  (0x14000, 0x14800, "rom_spr"), (0x15800, 0x16000, "rom_cp0"), (0x16000, 0x16400, "rom_cp1")]
    ROM_PARALLEL = {b: "own dpram_dc" for b in ("rom_main", "rom_snd", "rom_cvsd", "rom_spr", "rom_cp0", "rom_cp1")}
    ROM_OFFCHIP = {"faxq": "DDR3 through ddr_rom (q_byte_addr = 0x20000 + qrom_a)"}

    def index0(self, segs, g, variant):
        segs, extra = super().index0(segs, g, variant)
        def block(s):
            return next((n for lo, hi, n in self.ROM_BLOCKS
                         if lo <= s["addr"] < hi and (n != "faxq" or g["machine"] == "fax")), "regs")
        return [dict(s, region=block(s)) for s in segs], extra

    # region -> (base in ioctl index 0, size taken)
    REGIONS = {
        "maincpu":          (0x00000, 0x08000),
        "soundbd:audiocpu": (0x08000, 0x08000),
        "soundbd:cvsdcpu":  (0x10000, 0x04000),
        "gfx1":             (0x14000, 0x00800),
        "proms":            (0x14800, 0x00140),
        "targ":             (0x14A00, 0x00020),    # Targ audio tone PROM
    }
    # Victory: ROM 0000-7FFF at 0x00000, 8000-BFFF at 0x10000 (rom_cvsd: no CVSD on Victory), sound C000-FFFF at 0x0C000 (snd_rom)
    REGION_OVERRIDE = {"fax": {"maincpu": "split"}, "sidetrac": {"maincpu": "split"},
                       "victory": {"maincpu": "split", "soundbd:audiocpu": "split", "proms": (0, 0x17000, 0x200)},
                       # Car Polo: goal 0x15800, alpha 0x16000, sprite remap 0x16800 (rtl/boards/exidy_carpolo)
                       "carpolo": {"gfx2": (0, 0x15800, 0x100), "gfx3": (0, 0x16000, 0x200), "user1": (0, 0x16800, 0x20)},
                       **{m: dict(_CIRCUS_REGIONS) for m in ("circus", "robotbwl", "crash", "ripcord")}}
    REGION_SPLIT = {"fax": {"maincpu": [(0x08000, 0x08000, 0x00000), (0x10000, 0x30000, 0x20000)]},
                    "sidetrac": {"maincpu": [(0x00000, 0x04000, 0x00000), (0x04800, 0x00800, 0x15000)]},
                    "victory": {"maincpu": [(0x00000, 0x08000, 0x00000), (0x08000, 0x04000, 0x10000)],
                                "soundbd:audiocpu": [(0x0C000, 0x04000, 0x0C000)]}}

    # (machine config, init) pairs the board implements, -> board variant byte (rtl/exidy_dispatcher.sv)
    SUPPORTED = {
        ("venture", "empty_init"): 0,
        ("mtrap", "empty_init"): 1,
        ("pepper2", "empty_init"): 2,
        ("teetert", "empty_init"): 3,
        ("fax", "empty_init"): 4,
        ("targ", "init_targ"): 5,
        ("sidetrac", "init_sidetrac"): 6,
        ("spectar", "init_spectar"): 6,
        ("rallys", "init_spectar"): 6,
        ("phantoma", "init_spectar"): 6,
        ("circus", "empty_init"): 7,
        ("robotbwl", "empty_init"): 7,
        ("crash", "empty_init"): 7,
        ("ripcord", "empty_init"): 7,
        ("starfire", "empty_init"): 8,
        ("fireone", "empty_init"): 9,
        ("victory", "empty_init"): 10,
        ("carpolo", "empty_init"): 11,
    }

    # port order on the board: index 1 idle bytes 4-11, DIP selectors 12-19, input map bytes 20-83, DIP bit
    # permutation 84-147.
    # Only ports carrying DIPs go in <switches> (bytes 0.., in port order): Main_MiSTer builds the default with
    # 32-bit int shifts (mra_loader.cpp: binary[i] << (i * 8)), so only bytes 0-2 (and a byte 3 < 0x80) survive.
    PORTS = [("IN0", "INPUTS", "SYSTEM", "BUTTONS"), ("DSW", "SW2", "IN1"), ("IN2", "P1"), ("INTSOURCE", "PEDALS"),
             ("IN3", "P2"), ("COIN",), ("IN4",), ("UNUSED",)]   # first name present wins
    PORT_REWRITE = {m: coin_port for m in ("venture", "mtrap", "pepper2", "teetert", "fax",
                                           "targ", "sidetrac", "spectar", "rallys", "phantoma")}

    # control ids (Arcade-Exidy.sv)
    CTL = {**mra_lib.Core.CTL,
           ("BUTTON1", 3): 46, ("BUTTON2", 3): 47, ("BUTTON3", 3): 48, ("BUTTON1", 4): 49, ("BUTTON2", 4): 50,
           ("BUTTON3", 4): 51, ("COIN4", 0): 52}
    TWIN_IDS = range(38, 46)    # ids 46-52 are players 3 / 4 buttons and Coin 4

    SERIES_BY_PARENT = {"venture": ("Venture", "Maze"), "mtrap": ("Mouse Trap", "Maze"),
                        "pepper2": ("Pepper II", "Maze"), "hardhat": ("Hard Hat", "Maze"),
                        "teetert": ("Teeter Torture", "Shooter"), "fax": ("Fax", "Quiz"),
                        "circus": ("Circus", "Action"), "robotbwl": ("Robot Bowl", "Sports"), "trapeze": ("Trapeze", "Action"),
                        "crash": ("Crash", "Driving"), "ripcord": ("Rip Cord", "Action"),
                        "starfire": ("Star Fire", "Shooter"), "fireone": ("Fire One", "Shooter"),
                        "victory": ("Victory", "Shooter"), "carpolo": ("Car Polo", "Sports"),
                        "targ": ("Targ", "Maze"), "spectar": ("Spectar", "Maze"), "sidetrac": ("Side Trak", "Maze")}

    # ------------------------------------------------------------ overrides

    def parse_games(self, src=None):
        """the engine's games plus each GAME()'s flags field (OVERLAY_BY_LAYOUT reads the layout name)"""
        games = super().parse_games(src)
        for m in mra_lib.GAME_RE.finditer(src or self.src):
            games[m.group(2)]["flags"] = m.group(11)
        return games

    def load_source(self, files=None):
        """the engine's driver source without PORT_CENTERDELTA (analog centring: nothing in an MRA)"""
        return re.sub(r"\bPORT_CENTERDELTA\s*\([^()]*\)", "", super().load_source(files))

    def dsnd_xml(self, g):
        """index 5 block laid out as the Exidy MRAs have it: no blank line before it, one after"""
        text = super().dsnd_xml(g)
        return text.lstrip("\n") + "\n" if text else ""

    def pre_place(self, segs, g, variant):
        """REGION_MASK: a region placed through REGIONS keeps its offset modulo the mask (8000-FFFF program at 0)"""
        over = self.REGION_OVERRIDE.get(g["machine"], {})
        out = []
        for s in segs:
            mask = REGION_MASK.get(s["region"])
            if mask is not None and s["region"] not in over:
                if s["dst"] >= 0x10000:
                    raise SystemExit(f"{g['name']}: {s['name']} beyond the 64K CPU space (banked ROM not implemented)")
                s = dict(s, dst=s["dst"] & mask)
            out.append(s)
        return out

    def dsnd_program(self, g):
        import dsnd_boards
        return dsnd_boards.program(g["machine"])

    def input_config(self, g, ports):
        """-> (idle bytes, dip list, input map, 4-way, P1 button names, trackball reverse flags, coin impulse).
        8 ports x 8 bits of input map; DIP fields packed contiguous (osd_layout), the bit permutation kept in
        self.perm / self.osd_idle for the game-ID block and <switches>."""
        idle, dips, imap, fourway, buttons, tb_rev, impulse = [], [], [0] * 64, False, {}, 0, False
        perm, osd_idle = [list(range(8)) for _ in range(8)], {}
        port_list = self.PORTS_BY_MACHINE.get(g["machine"], self.PORTS)
        tags = [next((n for n in names if n in ports), names[0]) for names in port_list]
        dip_ports = [p for p, t in enumerate(tags) if any(f["kind"] == "dip" for f in ports.get(t, []))]
        if len(dip_ports) > 3:
            raise SystemExit(f'{g["name"]}: {len(dip_ports)} DIP ports; Main_MiSTer only keeps 3 default bytes reliably')
        for p, names in enumerate(port_list):
            tag = next((n for n in names if n in ports), names[0])
            fields = ports.get(tag)
            if fields is None:
                idle.append(0xFF)
                continue
            level = 0xFF
            pos = osd_layout(fields) if p in dip_ports else {b: b for b in range(8)}
            perm[p] = [pos[b] for b in range(8)]
            for f in fields:
                level = (level & ~f["mask"]) | (f["default"] & f["mask"])
                if f["kind"] == "dip":
                    obits = sorted(pos[b] for b in range(8) if f["mask"] >> b & 1)
                    lo, hi = obits[0], obits[-1]
                    assert obits == list(range(lo, hi + 1)), f'{g["name"]}: DIP {f["name"]} not packed'
                    sets = [(v, n) for i, (v, n) in enumerate(f["settings"])            # PORT_CONDITION alternatives:
                            if all(v != w for w, _ in f["settings"][:i])]              # keep the first per value
                    vals = [pext(v, f["mask"]) for v, _ in sets]
                    ids = ",".join(n.replace(",", ";") for _, n in sets)
                    d = dip_ports.index(p) * 8
                    bits = f"{d + lo}" if lo == hi else f"{d + lo},{d + hi}"
                    seq = vals == list(range(len(vals))) and len(vals) == 1 << (hi - lo + 1)
                    dips.append((f["name"], bits, ids, None if seq else ",".join(str(v) for v in vals)))
                    if f["name"].startswith("Rack Test") and lo == hi:
                        imap[p * 8 + lo] = self.RACK_TOGGLE if f.get("toggle") else self.RACK_HOLD   # button flips the DIP
                elif f["kind"] == "input":
                    t, pl = f["type"], f["player"]
                    if t.startswith("BUTTON") and t[6:].isdigit():
                        t = f"BUTTON{BUTTON_REMAP.get(g['machine'], {}).get(int(t[6:]), int(t[6:]))}"
                    if t == "CUSTOM":
                        continue                           # no handler: a fixed level, already in the idle byte
                    if t in self.TRACKBALL:
                        if f["mask"] != 0x0F:
                            raise SystemExit(f'{g["name"]}: trackball mask {f["mask"]:#x} in {tag}')
                        for b in range(4):
                            imap[p * 8 + b] = self.TRACKBALL[t] + b
                        tb_rev |= (1 if t == "TRACKBALL_X" else 2) if f.get("reverse") else 0
                        continue
                    if t in ANALOG_TYPES:
                        continue
                    if t == "OTHER" and f["name"] in OTHER_MAP:
                        t, pl = OTHER_MAP[f["name"]]
                        buttons[int(t[6:])] = f["name"]
                    key = (t, pl if t.startswith(("JOYSTICK", "BUTTON")) else 0)
                    if key not in self.CTL:
                        raise SystemExit(f'{g["name"]}: unmapped input {t} player {pl} in {tag}')
                    if f["mask"] & (f["mask"] - 1):
                        raise SystemExit(f'{g["name"]}: multi-bit input {t} in {tag}')
                    imap[p * 8 + f["mask"].bit_length() - 1] = self.CTL[key]
                    impulse |= t.startswith("COIN") and f.get("impulse", False)
                    fourway |= f["fourway"]
                    if t.startswith("BUTTON") and pl == 1:
                        buttons[int(t[6:])] = f["name"] or ("Fire" if t == "BUTTON1" else f"Button {t[6:]}")
            idle.append(level & 0xFF)
            osd_idle[p] = sum(((level >> b) & 1) << pos[b] for b in range(8))
        buttons.update(BUTTON_NAMES.get(g["machine"], {}))
        self.dip_ports, self.perm, self.osd_idle = dip_ports, perm, osd_idle
        return idle, dips, imap, fourway, buttons, tb_rev, impulse

    def setup(self, g):
        """the engine's setup with the Exidy game-ID block: always coin impulse, paddle flags, cfg2 / overlay byte,
        DIP bit permutation and colour latches after the input map; <switches> in the permuted DIP bit order."""
        s = super().setup(g)
        ports, cfg = s["ports"], s["cfg"]
        flags = s["flags"] | mra_lib.F_IMPULSE | (F_PADREV if g["machine"] in PADDLE_REVERSED else 0) | \
            (F_PADDLE if any(f.get("type") == "PADDLE" for fields in ports.values() for f in fields) else 0)
        rom_dec = CFG2_BY_MACHINE.get(g["machine"], 0) | \
            next((v for k, v in OVERLAY_BY_LAYOUT.items() if k in re.findall(r"\w+", g.get("flags", ""))), 0)
        n = len(self.PORTS)
        s["cfg"] = [cfg[0], flags, rom_dec, cfg[3]] + cfg[4:4 + 2 * n] + s["imap"] + [b for row in self.perm for b in row] + \
            list(COLORS_BY_INIT.get(g["init"], (0, 0, 0)))
        s["flags"] = flags
        s["switches"] = [self.osd_idle[p] for p in self.dip_ports]
        return s

    def flags2(self, g):
        return CFG_BY_STATE.get(g["state"], CFG_BY_MACHINE[g["machine"]])

    def hiscore_xml(self, g):
        """hiscore.dat sets with a measured init frame; victory keeps its scores in CMOS RAM (NVRAM)"""
        name = g["name"]
        if self.hiscores.get(name):
            if g["machine"] in NVRAM_BY_MACHINE or name not in self.HISCORE_INIT_FRAME:
                print(f'{name}: no measured hiscore init frame, hiscore omitted')
                return self.nvram_xml(g)
            self.FRAME_HZ = FRAME_HZ_BY_MACHINE.get(g["machine"], type(self).FRAME_HZ)
            return super().hiscore_xml(g)
        return self.nvram_xml(g)

    @staticmethod
    def nvram_xml(g):
        size = NVRAM_BY_MACHINE.get(g["machine"])
        if not size:
            return ""
        return f"""
    <!-- Index 4: battery-backed CMOS RAM -->
    <rom index="4"></rom>
    <nvram index="4" size="{size}"></nvram>
"""

    def mra(self, g, games, with_art=False):
        if with_art:
            art = self.art_zip(g)
            native = self.ART_NATIVE_BY.get(art, self.ART_NATIVE)
            if native != ART_NATIVE_MACHINE[g["machine"]]:
                raise SystemExit(f'{g["name"]}: artwork {art} native size {native} != board '
                                 f'raster {ART_NATIVE_MACHINE[g["machine"]]}')
        text = super().mra(g, games, with_art)
        meta = MRA_META.get(g["machine"])
        if not meta:
            return text

        def buttons(m):
            names = m.group(1).split(",")
            if meta.get("no_start"):
                names[5] = names[6] = "-"
            nm = ",".join(names)
            return f'<buttons names="{nm}" default="{mra_tidy.button_defaults(nm)}"/>'
        for tag, key in (("players", "players"), ("joystick", "joystick"), ("special_controls", "special_controls")):
            if key in meta:
                text = re.sub(rf"<{tag}>[^<]*</{tag}>", f"<{tag}>{meta[key]}</{tag}>", text, count=1)
        return re.sub(r'<buttons names="([^"]*)" default="[^"]*"/>', buttons, text, count=1)


if __name__ == "__main__":
    Exidy().main(sys.argv)

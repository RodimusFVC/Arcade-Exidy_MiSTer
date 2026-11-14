#!/usr/bin/env python3
"""Generate MRAs for the Exidy core straight from MAME exidy/exidy.cpp.

Region placement matches rtl/exidy_dispatcher.sv; images are copied as dumped.
DIP switches and the input map come from the set's MAME INPUT_PORTS.

Release layout: a parent set (MAME parent 0) goes to <releases>/<Title>.mra with the
trailing parentheses dropped; a clone goes to
<releases>/_alternatives/_<Parent Title>/<Full Title>.mra. A set whose zip (or its parent's) is in games/mame-artwork/ also
gets the same tree under <releases>/_artwork/ with the MAME artwork block (MRA index 6, rtl/art/artwork.sv).

Usage:
    gen_mra.py <driver.cpp[,driver.cpp...]> <releases_dir> [set ...]      (no sets: every supported set)
"""
import copy
import xml.etree.ElementTree as ET
import re
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "RodimusCoresMaster_MiSTer" / "tools"))
import mra_tidy                                     # noqa: E402  fleet MRA comment format

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dsnd_boards / dsnd

# MAME artwork (rtl/art/artwork.sv, ART-2026-10-26; generator code copied from the Universal core's gen_mra.py, = Irem1's):
# a set with games/mame-artwork/<set>.zip, else its parent's, gets an _artwork/ MRA. The MRA sends a 2048-byte layout
# table (from the zip's default.lay) then each PNG behind an "AWI"+id marker on ioctl index 6 (5 = discrete sound).
# OSD Game Options: View Off / 1-15 (the n-th kept view of default.lay, named in the MRA).
ART_IDX = 6
ART_DIR = Path(__file__).resolve().parent.parent / "games" / "mame-artwork"
ART_SCREEN_W = 512          # canvas pixels across the game screen (HDMI framebuffer); 2x native fits the DDR budget
ART_SCREEN_H = 512          # vertical games: canvas pixels down the (portrait) screen, same per-frame load as 512 across
ART_MAX_W = 1400            # widest canvas line: the HDMI scaler fetches one per output line; >~1450 shimmers at 1080p (HW 2026-10-24)
ART_BLOB_MAX = (1 << 26)    # PNG bytes + markers after the table: artwork.sv boff is 26 bits (64 MB DDR window)
ART_VIEWS = 15              # OSD View entry is 4 bits (Off, View 1-15) = the table's view limit
ART_ROT = {"ROT0": 0, "ROT270": 1, "ROT90": 2}   # layout table byte 10
# game picture = the board's displayed raster (hblank / vblank window; board sim 2026-10-26, snapshot size) = native plane
ART_NATIVE_MACHINE = {**{m: (256, 256) for m in ("venture", "mtrap", "pepper2", "teetert", "fax", "targ", "spectar", "sidetrac",
                                                 "rallys", "phantoma", "victory")},   # exidy_dispatcher blanking = MAME visarea
                      **{m: (248, 256) for m in ("circus", "ripcord", "robotbwl", "crash")},   # H 8-255
                      **{m: (256, 224) for m in ("starfire", "fireone")},                     # lines 32-255
                      "carpolo": (240, 256)}
ART_NATIVE = (256, 256)
ART_NATIVE_BY = {**{z: (248, 256) for z in ("circus", "crash", "smash", "ripcord")},   # per zip, checked against the
                 **{z: (256, 224) for z in ("starfire", "fireone")}}                       # machine in mra()

MAME_VERSION = "0289"
RBF = "Exidy"
HISCORE_DAT = Path("/CybertronMD/Mame/plugins/hiscore/hiscore.dat")   # current file (user, 2026-09-27)
# hiscore.v header after START_WAIT: CHECK_WAIT 00FF, CHECK_HOLD 2, WRITE_HOLD 2, WRITE_REPEATCOUNT 2,
# WRITE_REPEATWAIT FFFF (2.9 ms), PAUSEPAD 4 (Star Fire hands its scratch RAM port over 2 clocks into the pause), CHANGEMASK 0.
# The second write: gen-2 sets copy their default table end-first (0.68 ms, MAME), so the end byte matches mid-copy and
# the first restore is overwritten; the CPU then runs 2.9 ms before the dump is written again.
HISCORE_HEADER_TAIL = "00 FF 00 02 00 02 00 02 FF FF 04 00"
# START_WAIT = last boot-time write to the hiscore.dat ranges, measured per set in MAME 0.289 (write taps from frame 1,
# 45 s), + 2 frames. Later writes that fill a cleared table (gen-2 sets, 13-38 s) are gated by the end byte instead.
# fax / fax2 have none: the game clears the whole 02B4-0411 range itself ~55 s into attract mode.
# victory / victorba keep their scores in CMOS RAM (NVRAM_BY_MACHINE).
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
FRAME_HZ_BY_MACHINE = {"starfire": 5_000_000 / (320 * 262), "fireone": 5_000_000 / (320 * 262)}

# region -> (base in ioctl index 0, size taken[, address mask applied to the region offset])
REGIONS = {
    "maincpu":          (0x00000, 0x08000, 0x7FFF),  # 8000-FFFF program lands at 0x0000; Targ-era 0800-3FFF in place
    "soundbd:audiocpu": (0x08000, 0x08000),
    "soundbd:cvsdcpu":  (0x10000, 0x04000),
    "gfx1":             (0x14000, 0x00800),
    "proms":            (0x14800, 0x00140),
    "targ":             (0x14A00, 0x00020),    # Targ audio tone PROM
}
# Fax: program 8000-FFFF at 0x00000, question ROM banks (maincpu 0x10000-0x3FFFF) at 0x20000 (rtl/exidy_dispatcher.sv)
# Side Trak: character ROM (maincpu 0x4800) at 0x15000, preloaded into the character RAM
_CIRCUS_REGIONS = {"gfx1": (0, 0x15800, 0x800), "gfx2": (0, 0x14000, 0x200), "proms": (0, 0x16000, 0x400)}
# Victory: ROM 0000-7FFF at 0x00000, 8000-BFFF at 0x40000 (Fax's qrom1), sound C000-FFFF at 0x0C000 (snd_rom)
REGION_OVERRIDE = {"fax": {"maincpu": "split"}, "sidetrac": {"maincpu": "split"},
                   "victory": {"maincpu": "split", "soundbd:audiocpu": "split", "proms": (0, 0x17000, 0x200)},
                   # Car Polo: goal 0x15800, alpha 0x16000, sprite remap 0x16800 (rtl/boards/exidy_carpolo)
                   "carpolo": {"gfx2": (0, 0x15800, 0x100), "gfx3": (0, 0x16000, 0x200), "user1": (0, 0x16800, 0x20)},
                   **{m: dict(_CIRCUS_REGIONS) for m in ("circus", "robotbwl", "crash", "ripcord")}}
REGION_SPLIT = {"fax": {"maincpu": [(0x08000, 0x08000, 0x00000), (0x10000, 0x30000, 0x20000)]},
                "sidetrac": {"maincpu": [(0x00000, 0x04000, 0x00000), (0x04800, 0x00800, 0x15000)]},
                "victory": {"maincpu": [(0x00000, 0x08000, 0x00000), (0x08000, 0x04000, 0x40000)],
                            "soundbd:audiocpu": [(0x0C000, 0x04000, 0x0C000)]}}
IGNORED_REGIONS = set()

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


F_4WAY, F_WIDE, F_IMPULSE, F_VERT, F_PADREV, F_PADDLE, F_ROT90 = 0x01, 0x02, 0x04, 0x10, 0x20, 0x40, 0x80
PADDLE_REVERSED = {"ripcord"}
# IPT_OTHER inputs by name -> pad control (Robot Bowl hooks)
OTHER_MAP = {"Hook Right": ("BUTTON3", 1), "Hook Left": ("BUTTON4", 1)}
WIDE_INITS, WIDE_MACHINES = set(), set()
# PORT_CUSTOM_MEMBER handler -> port whose bits it returns
CUSTOM_PORTS = {}
STATE_VARIANT = {}
# port order on the board: index 1 idle bytes 4-11, DIP selectors 12-19, input map bytes 20-83, DIP bit
# permutation 84-147.
# Only ports carrying DIPs go in <switches> (bytes 0.., in port order): Main_MiSTer builds the default with
# 32-bit int shifts (mra_loader.cpp: binary[i] << (i * 8)), so only bytes 0-2 (and a byte 3 < 0x80) survive.
PORTS = [("IN0", "INPUTS", "SYSTEM", "BUTTONS"), ("DSW", "SW2", "IN1"), ("IN2", "P1"), ("INTSOURCE", "PEDALS"), ("IN3", "P2"), ("COIN",), ("IN4",), ("UNUSED",)]   # first name present wins
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
PORTS_BY_MACHINE = {}


def coin_port(ports):
    """The coin lines also preset the IRQ flip-flop and feed 5103 bits 6 / 5 (board COIN port, active high)."""
    ports = dict(ports)
    ports["COIN"] = [dict(mask=m, kind="input", default=0, type=t, player=0, name=None, settings=[], fourway=False)
                     for m, t in ((0x01, "COIN1"), (0x02, "COIN2"))]
    return ports


PORT_REWRITE = {m: coin_port for m in ("venture", "mtrap", "pepper2", "teetert", "fax",
                                       "targ", "sidetrac", "spectar", "rallys", "phantoma")}

# control ids (Arcade-Exidy.sv)
CTL = {("JOYSTICK_UP", 1): 1, ("JOYSTICK_DOWN", 1): 2, ("JOYSTICK_LEFT", 1): 3, ("JOYSTICK_RIGHT", 1): 4,
       ("BUTTON1", 1): 5, ("BUTTON2", 1): 6, ("BUTTON3", 1): 7, ("BUTTON4", 1): 8,
       ("JOYSTICK_UP", 2): 9, ("JOYSTICK_DOWN", 2): 10, ("JOYSTICK_LEFT", 2): 11, ("JOYSTICK_RIGHT", 2): 12,
       ("BUTTON1", 2): 13, ("BUTTON2", 2): 14, ("BUTTON3", 2): 15, ("BUTTON4", 2): 16,
       ("BUTTON5", 1): 32, ("BUTTON6", 1): 33, ("BUTTON5", 2): 34, ("BUTTON6", 2): 35,
       ("COIN1", 0): 17, ("COIN2", 0): 18, ("START1", 0): 19, ("START2", 0): 20,
       ("TILT", 0): 21, ("SERVICE1", 0): 22, ("SERVICE2", 0): 22, ("SERVICE", 0): 22, ("COIN3", 0): 23,
       ("BUTTON1", 3): 46, ("BUTTON2", 3): 47, ("BUTTON3", 3): 48, ("BUTTON1", 4): 49, ("BUTTON2", 4): 50,
       ("BUTTON3", 4): 51, ("COIN4", 0): 52,
       # twin stick: left stick = movement ids, right stick = right analog stick or Btn 3-6 (Arcade-Exidy.sv)
       **{(f"JOYSTICKLEFT_{d}", pl): b + o for pl, b in ((1, 0), (2, 8)) for d, o in (("UP", 1), ("DOWN", 2), ("LEFT", 3), ("RIGHT", 4))},
       **{(f"JOYSTICKRIGHT_{d}", pl): b + o for pl, b in ((1, 38), (2, 42)) for d, o in (("RIGHT", 0), ("LEFT", 1), ("DOWN", 2), ("UP", 3))}}
TWIN_IDS = range(38, 46)
# machine -> {MAME button number: pad button number} (pad Btn 1-4 = A, B, X, Y); user's layout requests
BUTTON_REMAP = {"mtrap": {1: 3, 3: 4, 4: 1}}   # Blue A, Yellow B, Dog X, Red Y (user 2026-10-17)
TRACKBALL = {"TRACKBALL_X": 24, "TRACKBALL_Y": 28}   # ids 24-27 / 28-31 = counter bits 0-3
IGNORED_TYPES = {"UNUSED", "UNKNOWN"}
WORKING_HERE = set()
RACK_HOLD, RACK_TOGGLE = 36, 37                     # Rack Test cheat button (no default pad mapping)

SERIES_BY_PARENT = {"venture": ("Venture", "Maze"), "mtrap": ("Mouse Trap", "Maze"),
                    "pepper2": ("Pepper II", "Maze"), "hardhat": ("Hard Hat", "Maze"),
                    "teetert": ("Teeter Torture", "Shooter"), "fax": ("Fax", "Quiz"),
                    "circus": ("Circus", "Action"), "robotbwl": ("Robot Bowl", "Sports"), "trapeze": ("Trapeze", "Action"),
                    "crash": ("Crash", "Driving"), "ripcord": ("Rip Cord", "Action"),
                    "starfire": ("Star Fire", "Shooter"), "fireone": ("Fire One", "Shooter"),
                    "victory": ("Victory", "Shooter"), "carpolo": ("Car Polo", "Sports"),
                    "targ": ("Targ", "Maze"), "spectar": ("Spectar", "Maze"), "sidetrac": ("Side Trak", "Maze")}
REGION_WORDS = [("US", "US"), ("Japan", "Japan"), ("Spanish", "Spain"), ("Italian", "Italy"), ("French", "France"),
                ("Brazil", "Brazil"), ("Argentina", "Argentina"), ("Greek", "Greece"), ("Hungarian", "Hungary")]

# ---------------------------------------------------------------- parsing

GAME_RE = re.compile(r'^GAMEL?\(\s*([\w?]+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(ROT\d+),\s*"([^"]*)",\s*"([^"]*)",\s*([^)]*)\)', re.M)
LOAD16_RE = re.compile(r'ROM_LOAD16_BYTE\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*CRC\(([0-9a-fA-F]+)\)')
LOAD_RE = re.compile(r'ROM_LOAD\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(?:BAD_DUMP\s+)?CRC\(([0-9a-fA-F]+)\)')
CONT_RE = re.compile(r'ROM_CONTINUE\(\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
NIB_RE = re.compile(r'ROM_LOAD_NIB_(LOW|HIGH)\s*\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*CRC\(([0-9a-fA-F]+)\)')
RELOAD_RE = re.compile(r'ROM_RELOAD\(\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
FILL_RE = re.compile(r'ROM_FILL\(\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
COPY_RE = re.compile(r'ROM_COPY\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
REGION_RE = re.compile(r'ROM_REGION(?:16_BE)?\(\s*(0x[0-9a-fA-F]+),\s*"([^"]+)"')
MACRO_RE = re.compile(r'\b(PORT_\w+|INPUT_PORTS_\w+)\b(\s*\(((?:[^()"]|"[^"]*"|\([^()]*\))*)\))?')


def parse_games(src):
    games = {}
    for m in GAME_RE.finditer(src):
        year, name, parent, machine, inputs, state, init, rot, manuf, desc, flags = m.groups()
        games[name] = dict(year=year, name=name, parent=None if parent == "0" else parent,
                           machine=machine, inputs=inputs, state=state, init=init, rot=rot, manuf=manuf, desc=desc,
                           working="MACHINE_NOT_WORKING" not in flags, flags=flags)
    return games


def parse_roms(src, setname):
    m = re.search(r'ROM_START\(\s*%s\s*\)(.*?)ROM_END' % re.escape(setname), src, re.S)
    if not m:
        raise SystemExit(f"ROM_START({setname}) not found")
    segs, region, rsize, last = [], None, 0, None
    for line in m.group(1).splitlines():
        line = line.split("//")[0]
        if "NO_DUMP" in line:
            continue                                   # never dumped; MAME runs without it
        if (r := REGION_RE.search(line)):
            region, rsize, last = r.group(2), int(r.group(1), 16), None
        elif (l := LOAD_RE.search(line)):
            name, off, length, crc = l.group(1), int(l.group(2), 16), int(l.group(3), 16), l.group(4).lower()
            last = dict(name=name, crc=crc, src=0, dst=off, len=length, flen=length, region=region, rsize=rsize)
            segs.append(last)
        elif (l := LOAD16_RE.search(line)):
            # ROM_LOAD16_BYTE (big-endian region): even offsets = high byte plane, odd = low byte plane
            name, off, length, crc = l.group(1), int(l.group(2), 16), int(l.group(3), 16), l.group(4).lower()
            last = dict(name=name, crc=crc, src=0, dst=off >> 1, len=length, flen=length,
                        region=f"{region}_{'lo' if off & 1 else 'hi'}", rsize=rsize // 2)
            segs.append(last)
        elif (c := CONT_RE.search(line)):
            off, length = int(c.group(1), 16), int(c.group(2), 16)
            nxt = dict(last, src=last["src"] + last["len"], dst=off, len=length)
            segs.append(nxt)
            last = nxt
        elif (n := NIB_RE.search(line)):
            # ROM_LOAD_NIB_LOW / _HIGH: two 4-bit PROMs sharing one byte; each gets its own slot, merged in the core
            half, name, off, length, crc = n.group(1), n.group(2), int(n.group(3), 16), int(n.group(4), 16), n.group(5).lower()
            last = dict(name=name, crc=crc, src=0, dst=off, len=length, flen=length,
                        region=f"{region}_n{'lo' if half == 'LOW' else 'hi'}", rsize=length)
            segs.append(last)
        elif (r := RELOAD_RE.search(line)):
            # ROM_RELOAD: the previous file loaded again at another offset
            base = next(s for s in reversed(segs) if s["name"] == last["name"] and s["src"] == 0)
            last = dict(base, dst=int(r.group(1), 16), len=int(r.group(2), 16))
            segs.append(last)
        elif (f := FILL_RE.search(line)):
            off, length, val = int(f.group(1), 16), int(f.group(2), 16), int(f.group(3), 16)
            segs.append(dict(name=None, crc=None, fill=val, src=0, dst=off, len=length, region=region, rsize=rsize))
            last = None
        elif (c := COPY_RE.search(line)):
            # ROM_COPY re-reads bytes already loaded into a region: slice the file loads that cover the source range
            sreg, sofs, dofs, length = c.group(1), int(c.group(2), 16), int(c.group(3), 16), int(c.group(4), 16)
            covered = 0
            for s in [s for s in segs if s["region"] == sreg]:
                lo, hi = max(s["dst"], sofs), min(s["dst"] + s["len"], sofs + length)
                if lo < hi:
                    segs.append(dict(s, src=s["src"] + lo - s["dst"], dst=dofs + lo - sofs, len=hi - lo,
                                     region=region, rsize=rsize))
                    covered += hi - lo
            if covered != length:
                raise SystemExit(f"{setname}: ROM_COPY source not fully loaded: {line.strip()}")
            last = None
        elif "ROM_" in line and any(k in line for k in ("ROM_LOAD", "ROM_COPY", "ROM_FILL", "ROM_RELOAD")):
            raise SystemExit(f"{setname}: unhandled ROM statement: {line.strip()}")
    return segs


def def_str(s):
    s = s.strip()
    m = re.fullmatch(r'DEF_STR\(\s*(\w+)\s*\)', s)
    if not m:
        return s.strip('"')
    w = m.group(1)
    c = re.fullmatch(r'(\d+)C_(\d+)C', w)
    if c:
        return f"{c.group(1)}C/{c.group(2)}C"
    return w.replace("_", " ")


def idle_level(arg, mask):
    """Released level from an IP_ACTIVE_LOW / IP_ACTIVE_HIGH keyword or a numeric default."""
    if arg == "IP_ACTIVE_LOW":
        return mask
    if arg == "IP_ACTIVE_HIGH":
        return 0
    return int(arg, 0) & mask


def split_args(a):
    out, depth, cur, q = [], 0, "", False
    for ch in a:
        if ch == '"':
            q = not q
        if not q and ch == "(":
            depth += 1
        elif not q and ch == ")":
            depth -= 1
        if ch == "," and depth == 0 and not q:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_inputs(src):
    """INPUT_PORTS name -> {tag: [field]}; field = dict(mask, kind, default, type, player, name, settings, fourway)."""
    blocks = {m.group(1): m.group(2) for m in re.finditer(
        r'INPUT_PORTS_START\(\s*(\w+)\s*\)(.*?)INPUT_PORTS_END', src, re.S)}
    cache = {}

    def build(name):
        if name in cache:
            return copy.deepcopy(cache[name])
        ports, cur, fld = {}, None, None
        body = "\n".join(l.split("//")[0] for l in blocks[name].splitlines())
        for m in MACRO_RE.finditer(body):
            mac, args = m.group(1), split_args(m.group(3) or "")
            if mac == "PORT_INCLUDE":
                ports.update(build(args[0]))
            elif mac in ("PORT_START", "PORT_MODIFY"):
                cur = args[0].strip('"')
                if mac == "PORT_START":
                    ports[cur] = []
                fld = None
            elif mac in ("PORT_BIT", "PORT_DIPNAME", "PORT_CONFNAME", "PORT_SERVICE", "PORT_SERVICE_DIPLOC", "PORT_SERVICE_NO_TOGGLE",
                         "PORT_DIPUNUSED", "PORT_DIPUNUSED_DIPLOC", "PORT_DIPUNKNOWN", "PORT_DIPUNKNOWN_DIPLOC"):
                mask = int(args[0], 0)
                # MAME splits an overlapped field: the older one keeps its other bits (DIP fields are replaced whole)
                kept = []
                for f in ports[cur]:
                    if not (f["mask"] & mask):
                        kept.append(f)
                    elif f["kind"] != "dip" and f["mask"] & ~mask:
                        kept.append(dict(f, mask=f["mask"] & ~mask, default=f["default"] & ~mask))
                ports[cur] = kept
                if mac == "PORT_BIT":
                    low = args[1] == "IP_ACTIVE_LOW"
                    t = args[2].replace("IPT_", "")
                    if t in TRACKBALL:
                        low = False
                    fld = dict(mask=mask, kind="unused" if t in IGNORED_TYPES else "input",
                               default=mask if low else 0, type=t, player=1, name=None, settings=[], fourway=False)
                elif mac in ("PORT_DIPNAME", "PORT_CONFNAME"):
                    fld = dict(mask=mask, kind="dip", default=int(args[1], 0), name=def_str(args[2]), settings=[])
                elif mac in ("PORT_SERVICE", "PORT_SERVICE_DIPLOC"):
                    off = idle_level(args[1], mask)
                    on = off ^ mask
                    fld = dict(mask=mask, kind="dip", default=off, name="Service Mode", settings=[(off, "Off"), (on, "On")])
                elif mac == "PORT_SERVICE_NO_TOGGLE":
                    fld = dict(mask=mask, kind="input", default=idle_level(args[1], mask), type="SERVICE", player=0,
                               name=None, settings=[], fourway=False)
                else:
                    d = {"IP_ACTIVE_LOW": mask, "IP_ACTIVE_HIGH": 0}.get(args[1])
                    fld = dict(mask=mask, kind="unused", default=int(args[1], 0) if d is None else d)
                ports[cur].append(fld)
            elif mac in ("PORT_DIPSETTING", "PORT_CONFSETTING"):
                fld["settings"].append((int(args[0], 0), def_str(args[1])))
            elif mac == "PORT_PLAYER":
                fld["player"] = int(args[0])
            elif mac == "PORT_COCKTAIL":
                fld["player"] = 2
            elif mac == "PORT_4WAY":
                fld["fourway"] = True
            elif mac == "PORT_REVERSE":
                fld["reverse"] = True
            elif mac == "PORT_NAME":
                fld["name"] = args[0].strip('"')
            elif mac == "PORT_IMPULSE":
                fld["impulse"] = True
            elif mac == "PORT_TOGGLE":
                fld["toggle"] = True
            elif mac == "PORT_2WAY":
                fld["twoway"] = True
            elif mac in ("PORT_DIPLOCATION", "PORT_CODE", "PORT_8WAY", "PORT_CONDITION",
                         "PORT_SENSITIVITY", "PORT_KEYDELTA", "PORT_MINMAX", "PORT_READ_LINE_DEVICE_MEMBER",
                         "PORT_CHANGED_MEMBER", "PORT_WRITE_LINE_DEVICE_MEMBER", "PORT_CENTERDELTA",
                         "PORT_ADJUSTER"):
                pass
            elif mac == "PORT_CUSTOM_MEMBER":
                fld["custom"] = re.sub(r".*::", "", args[0]).rstrip(")")
            else:
                raise SystemExit(f"INPUT_PORTS({name}): unhandled {mac}")
        cache[name] = ports
        return copy.deepcopy(ports)

    return build


def place(segs, setname, machine):
    """-> {ioctl index: [segment with addr]}"""
    over = REGION_OVERRIDE.get(machine, {})
    out = {}
    for s in segs:
        if s["region"] in over:
            if over[s["region"]] is None:
                continue
            if over[s["region"]] == "split":
                lo, ln, bs = next(t for t in REGION_SPLIT[machine][s["region"]] if t[0] <= s["dst"] < t[0] + t[1])
                if s["dst"] + s["len"] > lo + ln:
                    raise SystemExit(f"{setname}: {s['name']} crosses a split of {s['region']}")
                s = dict(s, dst=s["dst"] - lo)
                idx, base, size = 0, bs, ln
            else:
                idx, base, size = over[s["region"]]
        elif s["region"] in IGNORED_REGIONS:
            continue
        elif s["region"] not in REGIONS:
            raise SystemExit(f"{setname}: unmapped region {s['region']}")
        else:
            idx, (base, size, *mask) = 0, REGIONS[s["region"]]
            if mask:
                if s["dst"] >= 0x10000:
                    raise SystemExit(f"{setname}: {s['name']} beyond the 64K CPU space (banked ROM not implemented)")
                s = dict(s, dst=s["dst"] & mask[0])
        if s["dst"] >= size:
            continue                                   # e.g. the namco timing PROM
        if s["dst"] + s["len"] > size:
            raise SystemExit(f"{setname}: {s['name']} overruns {s['region']}")
        a, e = base + s["dst"], base + s["dst"] + s["len"]
        kept = []
        for o in out.get(idx, []):                                  # later loads, copies and fills overwrite earlier bytes
            oe = o["addr"] + o["len"]
            if oe <= a or o["addr"] >= e:
                kept.append(o)
                continue
            if o["addr"] < a:
                kept.append(dict(o, len=a - o["addr"]))
            if oe > e:
                kept.append(dict(o, addr=e, src=o["src"] + e - o["addr"], len=oe - e))
        out[idx] = kept + [dict(s, addr=a)]
    for idx in out:
        out[idx].sort(key=lambda s: s["addr"])
        for a, b in zip(out[idx], out[idx][1:]):
            assert a["addr"] + a["len"] <= b["addr"], f"{setname}: overlap {a['name']} / {b['name']}"
    return out


def whole_file(seg, segs):
    """True when this segment is the file's only load (no ROM_CONTINUE pieces)."""
    return (sum(1 for s in segs if s["name"] == seg["name"] and s["crc"] == seg["crc"]) == 1 and seg["src"] == 0
            and seg["len"] == seg["flen"])

# ---------------------------------------------------------------- inputs -> MRA

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


def input_config(g, ports):
    """-> (idle bytes, dip list, input map, 4-way, P1 button names, trackball reverse flags, coin impulse)."""
    idle, dips, imap, fourway, buttons, tb_rev, impulse = [], [], [0] * 64, False, {}, 0, False
    perm, osd_idle = [list(range(8)) for _ in range(8)], {}
    port_list = PORTS_BY_MACHINE.get(g["machine"], PORTS)
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
                    imap[p * 8 + lo] = RACK_TOGGLE if f.get("toggle") else RACK_HOLD   # button flips the DIP
            elif f["kind"] == "input":
                t, pl = f["type"], f["player"]
                if t.startswith("BUTTON") and t[6:].isdigit():
                    t = f"BUTTON{BUTTON_REMAP.get(g['machine'], {}).get(int(t[6:]), int(t[6:]))}"
                if t == "CUSTOM" and f["mask"] == 0x0F and tag in ("IN0", "IN1") and ports.get("P1"):
                    # Club Pac-Man: P1 / P2 joysticks multiplexed onto bits 0-3 by latch Q5 / Q4 (the board gates them)
                    for pf in ports["P1" if tag == "IN0" else "P2"]:
                        if pf["kind"] == "input":
                            imap[p * 8 + pf["mask"].bit_length() - 1] = CTL[(pf["type"], pf["player"])]
                            fourway |= pf["fourway"]
                    continue
                if t == "CUSTOM" and f.get("custom") in CUSTOM_PORTS:
                    # handler returns another port's bits: map them in place, with that port's idle levels
                    for sf in ports[CUSTOM_PORTS[f["custom"]]]:
                        bits = sf["mask"] & f["mask"]
                        if not bits:
                            continue
                        level = (level & ~bits) | (sf["default"] & bits)
                        if sf["kind"] == "input":
                            imap[p * 8 + sf["mask"].bit_length() - 1] = CTL[(sf["type"], sf["player"])]
                            fourway |= sf["fourway"]
                    continue
                if t == "CUSTOM":
                    continue                           # no handler: a fixed level, already in the idle byte
                if t in TRACKBALL:
                    if f["mask"] != 0x0F:
                        raise SystemExit(f'{g["name"]}: trackball mask {f["mask"]:#x} in {tag}')
                    for b in range(4):
                        imap[p * 8 + b] = TRACKBALL[t] + b
                    tb_rev |= (1 if t == "TRACKBALL_X" else 2) if f.get("reverse") else 0
                    continue
                if t in ANALOG_TYPES:
                    continue
                if t == "OTHER" and f["name"] in OTHER_MAP:
                    t, pl = OTHER_MAP[f["name"]]
                    buttons[int(t[6:])] = f["name"]
                key = (t, pl if t.startswith(("JOYSTICK", "BUTTON")) else 0)
                if key not in CTL:
                    raise SystemExit(f'{g["name"]}: unmapped input {t} player {pl} in {tag}')
                if f["mask"] & (f["mask"] - 1):
                    raise SystemExit(f'{g["name"]}: multi-bit input {t} in {tag}')
                imap[p * 8 + f["mask"].bit_length() - 1] = CTL[key]
                impulse |= t.startswith("COIN") and f.get("impulse", False)
                fourway |= f["fourway"]
                if t.startswith("BUTTON") and pl == 1:
                    buttons[int(t[6:])] = f["name"] or ("Fire" if t == "BUTTON1" else f"Button {t[6:]}")
        idle.append(level & 0xFF)
        osd_idle[p] = sum(((level >> b) & 1) << pos[b] for b in range(8))
    input_config.dip_ports = dip_ports
    input_config.perm, input_config.osd_idle = perm, osd_idle
    return idle, dips, imap, fourway, buttons, tb_rev, impulse


def port_default(fields):
    """Port value with every field at its default (conditional fields left idle): artwork element states."""
    level = 0xFF
    for f in fields:
        if "cond" not in f:
            level = (level & ~f["mask"]) | (f["default"] & f["mask"])
    return level



def parse_hiscores(path):
    """hiscore.dat -> {set: [entry lines]}; sets listed together share the entry lines below them."""
    out, names, body = {}, [], False
    for line in path.read_text(encoding="latin-1").splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            names, body = ([], False) if not line else (names, body)
            continue
        if line.endswith(":"):
            if body:
                names, body = [], False
            names.append(line[:-1])
        elif line.startswith("@"):
            for n in names:
                out.setdefault(n, []).append(line)
            body = True
    return out


HISCORES = parse_hiscores(HISCORE_DAT) if HISCORE_DAT.exists() else {}


# battery-backed CMOS RAM saved through MiSTer NVRAM (ioctl index 4; such sets have no hiscore.dat entry)
NVRAM_BY_MACHINE = {"victory": 0x800}   # F000-F7FF (rtl/boards/exidy_victory/victory_main.sv)


def nvram_xml(g):
    size = NVRAM_BY_MACHINE.get(g["machine"])
    if not size:
        return ""
    return f"""
    <!-- Index 4: battery-backed CMOS RAM -->
    <rom index="4"></rom>
    <nvram index="4" size="{size}"></nvram>
"""


def dsnd_xml(g):
    """discrete sound engine program (tools/dsnd_boards.py) as ioctl index 5; must follow index 1"""
    import dsnd_boards
    prog = dsnd_boards.program(g["machine"])
    if not prog:
        return ""
    rows = "\n".join("            " + " ".join(f"{b:02X}" for b in prog[i:i + 16]) for i in range(0, len(prog), 16))
    return f"""
    <!-- Index 5: discrete sound program for rtl/sound/dsnd_engine.sv (tools/dsnd_boards.py) -->
    <rom index="5">
        <part>
{rows}
        </part>
    </rom>"""


def hiscore_xml(g):
    lines = HISCORES.get(g["name"])
    if not lines:
        return ""
    ents = []
    for line in lines:
        if line.startswith("@delay="):
            continue                                   # load delay directive: START_WAIT is measured instead
        f = line.split(",")
        if f[0] != "@:maincpu" or f[1] != "program":
            raise SystemExit(f'{g["name"]}: unsupported hiscore.dat line {line}')
        ents.append((int(f[2], 16), int(f[3], 16), int(f[4], 16), int(f[5], 16)))
    rows = "\n".join(f"            {a >> 24 & 0xFF:02X} {a >> 16 & 0xFF:02X} {a >> 8 & 0xFF:02X} {a & 0xFF:02X} "
                      f"{n >> 8:02X} {n & 0xFF:02X} {s:02X} {e:02X}" for a, n, s, e in ents)
    total = sum(n for _, n, _, _ in ents)
    frame = HISCORE_INIT_FRAME.get(g["name"])
    if frame is None or g["machine"] in NVRAM_BY_MACHINE:
        print(f'{g["name"]}: no measured hiscore init frame, hiscore omitted')
        return ""
    wait = round((frame + 2) / FRAME_HZ_BY_MACHINE.get(g["machine"], FRAME_HZ) * CLK_HZ)
    header = " ".join(f"{b:02X}" for b in wait.to_bytes(4, "big")) + " " + HISCORE_HEADER_TAIL
    return f"""
    <!-- Index 3: hiscore config (MAME hiscore.dat), index 4: saved scores -->
    <rom index="3" md5="none">
        <part>
            {header}
{rows}
        </part>
    </rom>
    <rom index="4"></rom>
    <nvram index="4" size="{total}"></nvram>
"""


def art_table(zipname, rot="ROT0", port_defaults=None):
    """MAME default.lay -> (2048-byte table, [png names], [view names]); see rtl/art/artwork.sv for the format.
    rot = the set's orientation: the layout is in screen orientation (portrait for ROT90 / ROT270), the core's
    picture is the unrotated raster (ART_NATIVE). Views keep the screen and canvas on even pixels both
    ways, so the core can also draw them turned 90 (OSD Orientation Horz). port_defaults = {port tag: default value}
    for input-driven elements.
    Layer record: op, image (rect: R), flags, colour alpha, X, Y, W, H, X2 (rect: G, B), W2.
    Flags: [0] flipx, [1] alpha from mask, [3:2] kind (OSD toggle: 0 backdrop, 1 overlay, 2 bezel, 3 control panel /
    marquee), [4] bezel-off rect, [5] side art, [6] rect. A mask layer's colour alpha scales the mask (MAME alphafile)."""
    import struct, zipfile
    z = zipfile.ZipFile(ART_DIR / f"{zipname}.zip")
    native = ART_NATIVE_BY.get(zipname, ART_NATIVE)
    lay = ET.fromstring(z.read("default.lay"))

    def png_size(name):
        d = z.read(name)
        return struct.unpack(">II", d[16:24])

    def rgba(c):
        return [float(c.get(k, "1")) if c is not None else 1.0 for k in ("red", "green", "blue", "alpha")]

    def _bounds(e):
        b = e.find("bounds")
        if b is None:
            return None
        if b.get("left") is not None:
            return tuple(float(b.get(k)) for k in ("left", "top", "right", "bottom"))
        x, y = float(b.get("x", "0")), float(b.get("y", "0"))
        return x, y, x + float(b.get("width")), y + float(b.get("height"))

    def bounds(n):
        b = _bounds(n)
        return None if b is None else (b[0], b[1], b[2] - b[0], b[3] - b[1])

    # element -> ("img", [image nodes], defstate) | ("rects", [(x0, y0, x1, y1 in element units 0-1, rgba)])
    elems = {}
    for e in lay.findall("element"):
        name, kids = e.get("name"), list(e)
        imgs = [k for k in kids if k.tag == "image"]
        rects = [k for k in kids if k.tag == "rect"]
        if imgs and len(imgs) == len(kids):
            elems[name] = ("img", imgs, e.get("defstate", "0"))
        elif rects and len(rects) == len(kids):
            ib = [_bounds(r) or (0.0, 0.0, 1.0, 1.0) for r in rects]     # MAME default: the unit square
            ix0, iy0 = min(b[0] for b in ib), min(b[1] for b in ib)
            ix1, iy1 = max(b[2] for b in ib), max(b[3] for b in ib)
            elems[name] = ("rects", [((b[0] - ix0) / (ix1 - ix0), (b[1] - iy0) / (iy1 - iy0), (b[2] - ix0) / (ix1 - ix0),
                                      (b[3] - iy0) / (iy1 - iy0), rgba(r.find("color"))) for r, b in zip(rects, ib)])
        else:
            print(f"artwork {zipname}: element {name} is not plain images or rects, skipped")

    images, views, layers = [], [], []

    def img_id(name):
        if name not in images:
            images.append(name)
        return images.index(name)

    OP_MUL, OP_ADD, OP_ALPHA, OP_UNDER, OP_MASK = 0, 1, 2, 3, 4
    groups = {g.get("name"): g for g in lay.findall("group")}

    def flatten(node):
        # <group ref>: the group's items mapped from its bounds (or the union of its items) into the reference's bounds
        out = []
        for it in node:
            if it.tag == "group" and it.get("ref") in groups:
                inner = flatten(groups[it.get("ref")])
                if not inner:       # ART-2026-10-24: v2 group holding only a <collection> (ladybug): no legacy items
                    continue
                gb = bounds(groups[it.get("ref")])
                if gb is None:
                    bs = [bounds(i) for i in inner]
                    x0, y0 = min(b[0] for b in bs), min(b[1] for b in bs)
                    gb = (x0, y0, max(b[0] + b[2] for b in bs) - x0, max(b[1] + b[3] for b in bs) - y0)
                tb = bounds(it) or gb
                kx, ky = tb[2] / gb[2], tb[3] / gb[3]
                for i in inner:
                    b = bounds(i)
                    c = copy.deepcopy(i)
                    for old_b in c.findall("bounds"):
                        c.remove(old_b)
                    ET.SubElement(c, "bounds", x=str(tb[0] + (b[0] - gb[0]) * kx), y=str(tb[1] + (b[1] - gb[1]) * ky),
                                  width=str(b[2] * kx), height=str(b[3] * ky))
                    out.append(c)
            elif it.tag != "group" and bounds(it) is not None:
                out.append(it)
        return out

    def state_of(it, el):
        """Element state as MAME shows it with the set's default inputs: inputraw = (port & mask) >> lsb,
        other input items 0 (not pressed), else the element's defstate (outputs are not driven)."""
        tag = it.get("inputtag")
        if not tag:
            return el[2]
        mask = int(it.get("inputmask", "0"), 0)
        if it.get("inputraw") not in ("1", "yes"):
            return "0"
        if port_defaults is None or tag.lstrip(":") not in port_defaults:
            print(f"artwork {zipname}: {it.get('ref')} input {tag} has no default here, defstate used")
            return el[2]
        return str((port_defaults[tag.lstrip(":")] & mask) >> ((mask & -mask).bit_length() - 1 if mask else 0))

    def flatten_v2(node, tr, col, coll):
        """MAME rendlay.cpp add_items: <element ref> / <screen> in document order; <group ref> mapped from the group's
        bounds onto the item's bounds, colour multiplied (a group's blend attribute is ignored by MAME); hidden
        collections dropped (MAME default visibility). -> [(tag, item node, (x0, y0, x1, y1), rgba, collection)]"""
        out = []
        for it in node:
            if it.tag == "collection":
                if it.get("visible", "yes") not in ("no", "0", "false"):
                    out += flatten_v2(it, tr, col, coll or it.get("name"))
            elif it.tag == "group":
                gn = groups[it.get("ref")]
                gb = _bounds(gn)
                if gb is None:
                    bs = [b for _, _, b, _, _ in flatten_v2(gn, lambda b: b, [1.0] * 4, None)]
                    gb = (min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs))
                ib = _bounds(it)
                if it.find("orientation") is not None:
                    print(f"artwork {zipname}: group {it.get('ref')} orientation not supported, drawn unrotated")

                def gtr(b, gb=gb, ib=ib, tr=tr):
                    if ib is None:
                        return tr(b)
                    sx, sy = (ib[2] - ib[0]) / (gb[2] - gb[0]), (ib[3] - ib[1]) / (gb[3] - gb[1])
                    return tr((ib[0] + (b[0] - gb[0]) * sx, ib[1] + (b[1] - gb[1]) * sy,
                               ib[0] + (b[2] - gb[0]) * sx, ib[1] + (b[3] - gb[1]) * sy))
                out += flatten_v2(gn, gtr, [a * b for a, b in zip(col, rgba(it.find("color")))], coll)
            elif it.tag in ("screen", "element") and _bounds(it) is not None:
                out.append((it.tag, it, tr(_bounds(it)), [a * b for a, b in zip(col, rgba(it.find("color")))], coll))
            elif it.tag in ("repeat", "param"):
                print(f"artwork {zipname}: view {v.get('name')}: <{it.tag}> not supported, skipped")
        return out

    LEGACY = ("backdrop", "overlay", "bezel", "cpanel", "marquee")
    for v in lay.findall("view"):
        # layer list: (op, kind, element name, (x, y, w, h), rgba, orientation node, state)
        fv = flatten(v)                 # <group ref> resolved
        if any(it.tag in LEGACY for it in fv):
            items = {k: [] for k in ("backdrop", "screen", "overlay", "bezel", "cpanel", "marquee")}
            for it in fv:
                if it.tag in items:
                    items[it.tag].append(it)
            if len(items["screen"]) != 1:
                print(f"artwork {zipname}: view {v.get('name')} needs exactly one screen, skipped")
                continue
            vb = bounds(v)
            if vb is None:      # union of every item
                bs = [bounds(i) for k in items for i in items[k]]
                x0, y0 = min(b[0] for b in bs), min(b[1] for b in bs)
                vb = (x0, y0, max(b[0] + b[2] for b in bs) - x0, max(b[1] + b[3] for b in bs) - y0)
            sb = bounds(items["screen"][0])
            if items["overlay"] or len(items["backdrop"]) <= 1:
                order = [(OP_MUL, "overlay"), (OP_ADD, "backdrop"), (OP_ALPHA, "bezel"), (OP_ALPHA, "cpanel"), (OP_ALPHA, "marquee")]
            else:
                order = [(OP_UNDER, "backdrop"), (OP_ALPHA, "bezel"), (OP_ALPHA, "cpanel"), (OP_ALPHA, "marquee")]
            seq = [(op, kind, it.get("element"), bounds(it), rgba(it.find("color")), it.find("orientation"), None)
                   for op, kind in order for it in items[kind]]
        else:
            # modern layout (element ref / collection / group): draw order = document order, element blend default
            # alpha; the screen draws opaque (BLENDMODE_NONE) unless blend="add". Before the screen: alpha = UNDER,
            # add = ADD; after it: alpha = ALPHA, add = ADD, multiply = MUL. OSD toggle kind from the collection name.
            flat = flatten_v2(v, lambda b: b, [1.0] * 4, None)
            scr = [i for i, f in enumerate(flat) if f[0] == "screen"]
            if len(scr) != 1:
                print(f"artwork {zipname}: view {v.get('name')} needs exactly one screen, skipped")
                continue
            si = scr[0]
            s0 = flat[si][2]
            sb = (s0[0], s0[1], s0[2] - s0[0], s0[3] - s0[1])
            vb = bounds(v)
            if vb is None:
                bs = [f[2] for f in flat]
                x0, y0 = min(b[0] for b in bs), min(b[1] for b in bs)
                vb = (x0, y0, max(b[2] for b in bs) - x0, max(b[3] for b in bs) - y0)
            if flat[si][1].get("blend") not in (None, "none", "alpha", "add"):
                print(f"artwork {zipname}: view {v.get('name')}: screen blend {flat[si][1].get('blend')} not supported")
            opaque = flat[si][1].get("blend") != "add"
            seq = []
            for i, (tag, it, b, col, coll) in enumerate(flat):
                if tag == "screen":
                    continue
                blend = it.get("blend", "alpha")
                if blend == "multiply" and i < si:
                    print(f"artwork {zipname}: {it.get('ref')} multiply under the screen not supported, skipped")
                    continue
                op = {"multiply": OP_MUL, "add": OP_ADD}.get(blend, OP_UNDER if i < si else OP_ALPHA)
                if i < si and opaque and b[0] < s0[2] and s0[0] < b[2] and b[1] < s0[3] and s0[1] < b[3]:
                    print(f"artwork {zipname}: {it.get('ref')} under an opaque screen: drawn under the game")
                cn = (coll or "").lower()
                kind = ("overlay" if "overlay" in cn else "backdrop" if "backdrop" in cn or "background" in cn else
                        "bezel" if "bezel" in cn else "cpanel" if "panel" in cn or "marquee" in cn else "side" if "side" in cn else "art" if cn else
                        "overlay" if op == OP_MUL else "backdrop" if i < si or op == OP_ADD else "art")
                el = elems.get(it.get("ref"))
                seq.append((op, kind, it.get("ref"), (b[0], b[1], b[2] - b[0], b[3] - b[1]), col,
                            it.find("orientation"), state_of(it, el) if el and el[0] == "img" else None))
        vert = rot != "ROT0"
        sc = ART_SCREEN_H / sb[3] if vert else ART_SCREEN_W / sb[2]
        cap = ART_MAX_W / max(vb[2], vb[3])                 # height too: Orientation Horz turns it into the line width
        if sc > cap:
            gq = native[::-1] if vert else native
            sc = max(cap, (gq[0] + 2) / sb[2], (gq[1] + 2) / sb[3])  # never below the game's native size + 2
            print(f"artwork {zipname}: view {v.get('name')} shrunk to the {ART_MAX_W} px line cap (scale {sc:.3f})")
        cw, ch = (round(vb[2] * sc) + 1) & ~1, round(vb[3] * sc)
        ox = round((sb[0] - vb[0]) * sc) & 1        # shift the view so the screen starts on an even pixel
        oy = round((sb[1] - vb[1]) * sc) & 1        # and an even row (the view turned 90)
        sx = round((sb[0] - vb[0]) * sc) - ox
        sy = round((sb[1] - vb[1]) * sc) - oy
        sw, sh = round(sb[2] * sc / 2) * 2, round(sb[3] * sc / 2) * 2   # = (512 down / across) when not capped
        ch = (ch + 1) & ~1
        gw, gh = native[::-1] if vert else native        # game picture as the layout shows it
        assert cw <= 2048 and ch <= 2048 and sw >= gw and sh >= gh, v.get("name")
        KIND = {"backdrop": 0, "overlay": 1, "bezel": 2, "cpanel": 3, "marquee": 3, "art": 2, "side": 0}   # OSD toggle per layer
        first, nimg = len(layers), len(images)
        qimg = 1                # this view: smallest q / 256 keeping every PNG within the resampler's 15x downscale
        for op, kind, ename, b, col, o, state in seq:
            if ename not in elems:
                continue
            el = elems[ename]
            if el[0] == "img":    # images visible in this state (no state attribute = every state)
                st = el[2] if state is None else state
                # ART-2026-10-24: states compared as numbers (MAME reads "0xfd" and "253" alike; ladybug's joystick)
                # pick = [i for i in el[1] if i.get("state", st) == st]
                num = lambda x: int(x.strip(), 16) if x.strip().lower().startswith("0x") else int(x.strip())
                pick = [i for i in el[1] if num(i.get("state", st)) == num(st)]
                if not pick:          # a lamp: no image in its default state (outputs are not driven yet)
                    print(f"artwork {zipname}: element {ename} has no image for state {st}, skipped")
                    continue
                el = ("img", pick[0].get("file"), pick[0].get("alphafile"))
            flipx = o is not None and o.get("flipx") == "yes"
            if o is not None and (o.get("rotate", "0") != "0" or o.get("flipy") == "yes"):
                print(f"artwork {zipname}: {ename} rotate / flipy not supported, drawn unrotated")

            def place(x0, y0, x1, y1):
                x = round((x0 - vb[0]) * sc); y = round((y0 - vb[1]) * sc)
                return x - ox, y - oy, round((x1 - vb[0]) * sc) - x, round((y1 - vb[1]) * sc) - y

            k = KIND[kind] << 2
            if el[0] == "rects":      # one solid-colour layer per rect, item colour x rect colour
                for rx0, ry0, rx1, ry1, rc in el[1]:
                    x, y, w, h = place(b[0] + rx0 * b[2], b[1] + ry0 * b[3], b[0] + rx1 * b[2], b[1] + ry1 * b[3])
                    if w <= 0 or h <= 0:
                        continue
                    r, gr, bl, a = (round(255 * rc[i] * col[i]) for i in range(4))
                    side = kind != "bezel" and (x + w <= sx or x >= sx + sw)
                    layers.append((op, r, 64 | ((k & ~12) if side and KIND[kind] == 2 else k) | (32 if side else 0), a, x, y, w, h, gr | bl << 8, 0))
                continue
            if col[:3] != [1.0] * 3:
                print(f"artwork {zipname}: {ename} colour tint not supported, drawn untinted")
            _, f, af = el
            x, y, w, h = place(b[0], b[1], b[0] + b[2], b[1] + b[3])
            ca = round(255 * col[3])
            assert w <= 2048, f
            for name in [n for n in (af, f) if n]:
                pw, ph = png_size(name)
                assert pw <= 15 * w and ph <= 15 * h, f"{name}: downscale factor over 15"
                qimg = max(qimg, -(-pw * 256 // (15 * max(1, w - 1))), -(-ph * 256 // (15 * max(1, h - 1))))   # view L0 high byte (1 px margin: RTL rounding)
            # side art beside the screen and taller than it: with bezels off it is scaled to the screen's height
            # (flag bit 4, alternate x / width; y / height = the screen's), so the game can fill the display
            alt, x2, w2 = 0, 0, 0
            side = kind != "bezel" and (x + w <= sx or x >= sx + sw)     # side art: OSD Side Art toggle (flag bit 5)
            if side:   # side art never follows the Bezel toggle (bezel off = side art at the screen's height)
                k = ((k & ~12) if KIND[kind] == 2 else k) | 32
            if side and h > sh:
                w2 = max(1, round(w * sh / h))
                x2 = x + w - w2 if x + w <= sx else x
                alt = 16
                for name in [n for n in (af, f) if n]:
                    pw, ph = png_size(name)
                    assert pw <= 15 * w2 and ph <= 15 * sh, f"{name}: downscale factor over 15 (bezel off)"
                    qimg = max(qimg, -(-pw * 256 // (15 * max(1, w2 - 1))), -(-ph * 256 // (15 * max(1, sh - 1))))
            if af:
                layers.append((OP_MASK, img_id(af), k | alt, ca, x, y, w, h, x2, w2))
            layers.append((op, img_id(f), (1 if flipx else 0) | (2 if af else 0) | k | alt, 255 if af else ca, x, y, w, h, x2, w2))
        blob = sum(4 + z.getinfo(n).file_size for n in images)
        if len(views) >= ART_VIEWS or len(layers) > 112 or len(images) > 32 or blob > ART_BLOB_MAX:   # full: drop, try the next
            print(f"artwork {zipname}: view {v.get('name')} dropped, table full "
                  f"(views {len(views) + 1}/{ART_VIEWS}, layers {len(layers)}/112, images {len(images)}/32, "
                  f"PNG bytes {blob}/{ART_BLOB_MAX})")
            del layers[first:], images[nimg:]
            continue
        # L0 high byte = qimg - 1 (artwork.sv floor for the HDMI fit; L0 itself is 7 bits)
        views.append((v.get("name"), (cw, ch, sx, sy, sw, sh, first | (min(qimg, 256) - 1) << 8, len(layers) - first)))
    t = bytearray(2048)
    struct.pack_into("<2sHHHHB", t, 0, b"AW", len(views), len(images), *native, ART_ROT[rot])
    for i, (_, rec) in enumerate(views):
        struct.pack_into("<8H", t, 16 + 16 * i, *rec)
    for i, (op, img, fl, ca, x, y, w, h, x2, w2) in enumerate(layers):
        struct.pack_into("<BBBBhhHHHH" if fl & 64 else "<BBBBhhHHhH", t, 256 + 16 * i, op, img, fl, ca, x, y, w, h, x2, w2)
    return bytes(t), images, [n for n, _ in views]


def art_xml(zipname, rot, port_defaults=None):
    table, images, views = art_table(zipname, rot, port_defaults)
    names = ", ".join(f"View {i + 1} = {n.replace('_', ' ')}" for i, n in enumerate(views))
    rows = "\n".join("            " + " ".join(f"{b:02X}" for b in table[i:i + 32]) for i in range(0, 2048, 32))
    parts = "\n".join(f'        <part>41 57 49 {i:02X}</part>\n        <part name="{n}"/>' for i, n in enumerate(images))
    return f"""
    <!-- Index {ART_IDX}: MAME artwork, layout table (from default.lay) + PNGs from the artwork zip, as-is -->
    <!-- OSD Artwork: {names} -->
    <rom index="{ART_IDX}" md5="none" zip="/mame-artwork/{zipname}.zip">
        <part>
{rows}
        </part>
{parts}
    </rom>
"""


def art_name(g):
    """Artwork zip for this set: its own, else its parent's (None: no artwork)."""
    for n in (g["name"], g["parent"]):
        if n and (ART_DIR / f"{n}.zip").exists():
            return n
    return None


def mra(g, games, segs, build_inputs, with_art=False):
    variant = STATE_VARIANT.get(g["state"], SUPPORTED[(g["machine"], g["init"])])
    ports = PORT_REWRITE.get(g["machine"], lambda p: p)(build_inputs(g["inputs"]))
    idle, dips, imap, fourway, buttons, tb_rev, impulse = input_config(g, ports)
    twoway = any(f.get("twoway") for fields in ports.values() for f in fields)
    flags = (F_4WAY if fourway else 0) | F_IMPULSE | (F_WIDE if g["init"] in WIDE_INITS or g["machine"] in WIDE_MACHINES else 0) | \
            (F_VERT if g["rot"] in ("ROT90", "ROT270") else 0) | \
            (F_ROT90 if g["rot"] == "ROT90" else 0) | \
            (F_PADREV if g["machine"] in PADDLE_REVERSED else 0) | \
            (F_PADDLE if any(f.get("type") == "PADDLE" for fields in ports.values() for f in fields) else 0)
    buttons.update(BUTTON_NAMES.get(g["machine"], {}))
    nbtn = max(buttons) if buttons else 0
    twin = any(i in TWIN_IDS for i in imap)
    if twin:                                           # Btn 3-6 carry the right-hand stick
        buttons.update({3: "R Right", 4: "R Left", 5: "R Down", 6: "R Up"})
        nbtn = 6
    meta = MRA_META.get(g["machine"], {})
    starts = ["-", "-"] if meta.get("no_start") else ["Start 1P", "Start 2P"]
    names = ",".join([buttons.get(i, "-") for i in range(1, 5)] + ["Coin"] + starts + ["Pause"] +
                     [buttons.get(i, "-") for i in (5, 6)] +
                     ["Rack Test" if RACK_HOLD in imap or RACK_TOGGLE in imap else "-"])
    parent = g["parent"] or g["name"]
    zipname = f'{g["name"]}.zip' + (f'|{g["parent"]}.zip' if g["parent"] else "")
    rotation = {"ROT0": "horizontal", "ROT270": "vertical (ccw)", "ROT90": "vertical (cw)"}[g["rot"]]
    bootleg = "yes" if "bootleg" in g["manuf"].lower() or "hack" in g["desc"].lower() else "no"
    top = games.get(parent, g)                         # parent may live in another driver (suprglob: epos)
    series, category = SERIES_BY_PARENT.get(parent, (title_case(clean_title(top["desc"])), "Maze"))
    region = next((r for w, r in REGION_WORDS if w in g["desc"]), "World")

    def part_lines(isegs):
        lines, pos = [], 0
        for s in isegs:
            if s["addr"] > pos:
                lines.append(f'        <part repeat="0x{s["addr"] - pos:X}">00</part>')
            if s.get("fill") is not None:
                lines.append(f'        <part repeat="0x{s["len"]:X}">{s["fill"]:02X}</part>')
            elif whole_file(s, isegs):
                lines.append(f'        <part crc="{s["crc"]}" name="{s["name"]}"/>')
            else:
                lines.append(f'        <part crc="{s["crc"]}" name="{s["name"]}" offset="0x{s["src"]:X}" length="0x{s["len"]:X}"/>')
            pos = s["addr"] + s["len"]
        return "\n".join(lines)

    sdram = ""
    if 2 in segs:
        sdram = f"""
    <!-- Index 2: SDRAM (large banked ROM regions) -->
    <rom index="2" md5="none" zip="{zipname}">
{part_lines(segs[2])}
    </rom>
"""

    dip_lines = "\n".join(f'        <dip name="{n}" bits="{b}" ids="{i}"' + (f' values="{v}"' if v else "") + "/>"
                          for n, b, i, v in dips)
    rom_dec = CFG2_BY_MACHINE.get(g["machine"], 0) | \
              next((v for k, v in OVERLAY_BY_LAYOUT.items() if k in re.findall(r"\w+", g.get("flags", ""))), 0)
    flags2 = CFG_BY_STATE.get(g["state"], CFG_BY_MACHINE[g["machine"]])
    dip_ports = input_config.dip_ports
    dipsel = [dip_ports.index(p) if p in dip_ports else 0x80 for p in range(len(PORTS))]
    cfg = [variant, flags, rom_dec, flags2] + idle + dipsel + imap + [b for row in input_config.perm for b in row] + \
          list(COLORS_BY_INIT.get(g["init"], (0, 0, 0)))
    cfg_rows = "\n".join("            " + " ".join(f"{b:02X}" for b in cfg[i:i + 16]) for i in range(0, len(cfg), 16))
    art_block = ""
    if with_art:                                       # ART-2026-10-26
        art = art_name(g)
        if ART_NATIVE_BY.get(art, ART_NATIVE) != ART_NATIVE_MACHINE[g["machine"]]:
            raise SystemExit(f'{g["name"]}: artwork {art} native size {ART_NATIVE_BY.get(art, ART_NATIVE)} != board '
                             f'raster {ART_NATIVE_MACHINE[g["machine"]]}')
        art_block = art_xml(art, g["rot"], {t: port_default(f) for t, f in ports.items()})
    return f"""<misterromdescription>
    <name>{display_name(g)}</name>
    <region>{region}</region>
    <homebrew>no</homebrew>
    <bootleg>{bootleg}</bootleg>
    <version></version>
    <alternative></alternative>
    <platform></platform>
    <series>{series}</series>
    <year>{g["year"]}</year>
    <manufacturer>{g["manuf"]}</manufacturer>
    <category>{category}</category>

    <setname>{g["name"]}</setname>
    <parent>{parent}</parent>
    <mameversion>{MAME_VERSION}</mameversion>
    <rbf>{RBF}</rbf>
    <about></about>

    <resolution>15kHz</resolution>
    <rotation>{rotation}</rotation>
    <flip>yes</flip>

    <players>{meta.get("players", "2 (alternating)")}</players>
    <joystick>{meta.get("joystick", "2-way" if twoway else "4-way" if fourway else "8-way")}</joystick>
    <special_controls>{meta.get("special_controls", "trackball" if any(24 <= i < 32 for i in imap) else "twin stick" if twin else "")}</special_controls>
    <num_buttons>{nbtn}</num_buttons>
    <buttons names="{names}" default="{mra_tidy.button_defaults(names)}"/>

    <switches default="{",".join(f"{input_config.osd_idle[p]:02X}" for p in dip_ports)}">
{dip_lines}
    </switches>

    <!-- Index 0: MAME regions, layout in rtl/exidy_dispatcher.sv -->
    <rom index="0" md5="none" zip="{zipname}">
{part_lines(segs.get(0, []))}
    </rom>
{sdram}
    <!-- Index 1: board variant, flags, board config, input map (see Arcade-Exidy.sv) -->
    <rom index="1">
        <part>
{cfg_rows}
        </part>
    </rom>{dsnd_xml(g)}
{hiscore_xml(g) or nvram_xml(g)}{art_block}
    <remark>{remark(g)}</remark>
    <mratimestamp>20261016000000</mratimestamp>
</misterromdescription>
"""


def title_case(text):
    """Capitalise every word, small words included; acronyms (US, II, PCB) stay as written."""
    out = []
    for word in re.split(r"(\s+|[()/,-])", text):
        if word and word[0].isalpha():
            word = word[0].upper() + word[1:]
        out.append(word)
    return "".join(out)


def clean_title(desc):
    """Parent title: the description without its trailing parenthesised qualifiers."""
    return re.sub(r"(\s*\([^()]*\))+$", "", desc).strip()


def display_name(g):
    return title_case(clean_title(g["desc"]) if g["parent"] is None else g["desc"])


def remark(g):
    """'Title (Maker)', without repeating a maker the title already names."""
    m = re.fullmatch(r'bootleg \((.+)\)', g["manuf"])
    maker = f"{m.group(1)} bootleg" if m else g["manuf"]
    desc = title_case(g["desc"])
    return desc if maker.lower() in g["desc"].lower() else f"{desc} ({title_case(maker)})"


def safe(name):
    return re.sub(r'\s*/\s*', " - ", re.sub(r'[\\:*"<>|]', "-", name.replace("?", "")))


# release file names kept from earlier releases (saved .nvm / .cfg follow the MRA file name; Victory has CMOS NVRAM)
FILE_NAME = {"victory": "Victory (Exidy)"}


def out_path(root, g, games):
    if g["parent"] is None:
        return root / f"{safe(FILE_NAME.get(g['name'], display_name(g)))}.mra"
    parent_title = display_name(games[g["parent"]]) if g["parent"] in games else title_case(clean_title(g["desc"]))
    return root / "_alternatives" / f"_{safe(parent_title)}" / f"{safe(display_name(g))}.mra"


def main():
    src = "\n".join(Path(f).read_text() for f in sys.argv[1].split(","))
    out_dir = Path(sys.argv[2])
    games = parse_games(src)
    build_inputs = parse_inputs(src)
    names = sys.argv[3:] or [n for n, g in games.items()
                             if (g["machine"], g["init"]) in SUPPORTED and (g["working"] or n in WORKING_HERE)]
    for name in names:
        g = games[name]
        if (g["machine"], g["init"]) not in SUPPORTED:
            raise SystemExit(f'{name}: board {g["machine"]} / {g["init"]} not implemented')
        segs = place(parse_roms(src, name), name, g["machine"])
        # ART-2026-10-26: plus the same tree under _artwork/ when the set (or its parent) has a MAME artwork zip
        for root, with_art in [(out_dir, False)] + ([(out_dir / "_artwork", True)] if art_name(g) else []):
            path = out_path(root, g, games)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(mra_tidy.tidy(mra(g, games, segs, build_inputs, with_art)))
            print(f'{name:12s} {path.relative_to(out_dir)}')


if __name__ == "__main__":
    main()

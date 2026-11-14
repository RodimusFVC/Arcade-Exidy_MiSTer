"""Discrete sound engine programs for the Exidy boards (rtl/rodimus/dsnd_engine/dsnd_engine.sv, assembler tools/dsnd.py).

BOARDS maps a MAME machine config name to a function returning a finished dsnd.Board. gen_mra.py emits the program as
MRA ioctl index 5 (after index 1); a set with no entry keeps its dedicated sound RTL.

Engine: 832 clocks of 22.578 MHz per sample (FS = 27137 Hz), 410 budget units, OUT = left, OUTR = right (a program
with no OUTR is mono). Source bytes (rtl/exidy_dispatcher.sv "Discrete sound engine", sampled live; box averages are
registered at the sample strobe):
  gen-1 (targ, spectar, sidetrac, rallys, panzer, phantoma): 0 = 5200 latch, 1 = 5201 latch, 2 = tone flip-flop 3D-b
        box average, 3 = MUSIC (5200 D0) box average (both = phi2 cycles high in the sample, 0-26)
  Circus family (circus, ripcord, robotbwl, crash): 0 = 8000 output latch (D7 /GAME mute, D3-D0 sprite image),
        1 = music line box average (phi2 cycles active in the sample, 0-26; Robot Bowl D3, others D6-D4 = 001)
  Star Fire / Fire One: 0 = Star Fire latch / Fire One offset 0 latch, 1 = Fire One offset 1 latch,
        2 / 3 / 4 = Fire One 8253 OUT0 / OUT1 / OUT2 box average (Z80 enables high in the sample, about 92 of 92)
  Car Polo: 0 = {PA7 ball hit, PA5 score (idle 1, pulsed 0), 0, 0, CRASH P4..P1 (1 = sounding, pulse-extended)},
        1 = {0, 0, speed P2[2:0], speed P1[2:0]}, 2 = {0, 0, speed P4, speed P3} (74173 Q, before the 7406
        inverters), 3 = {0000, ACTIVE P4..P1} (bit 0 = P1)
  all: 5 = OSD volumes {music[3:0], effects[3:0]} (Board.vol("M"/"E")), 6 / 7 = Game Audio caps (tools/dsnd.py)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dsnd_carpolo
import dsnd_circus
import dsnd_gen1
import dsnd_starfire

BOARDS = {
    "starfire": dsnd_starfire.starfire,     # Star Fire, Star Fire 2
    "fireone": dsnd_starfire.fireone,
    "carpolo": dsnd_carpolo.carpolo,
    "circus": dsnd_circus.circus,           # Circus, Trapeze
    "ripcord": dsnd_circus.ripcord,
    "robotbwl": dsnd_circus.robotbwl,
    "crash": dsnd_circus.crash,
    "targ": dsnd_gen1.targ,                 # Targ audio board
    "spectar": dsnd_gen1.spectar,           # Spectar-type audio board
    "sidetrac": dsnd_gen1.spectar,
    "rallys": dsnd_gen1.spectar,            # Rallys, Panzer
    "phantoma": dsnd_gen1.spectar,
}


def program(machine):
    """program bytes for a machine, or None"""
    f = BOARDS.get(machine)
    return f().binary() if f else None


if __name__ == "__main__":
    for m, f in BOARDS.items():
        p = f()
        print(f"{m:10s} words {len(p.code):4d}  worst units {p.worst_path():3d}  registers {len(p.regs):3d}")

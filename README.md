# Sparkr

A NES homebrew game built with ca65 and GNU Make.

You play as **Sparky** — a sentient static charge accidentally discharged from a
massive power plant's main capacitor. Navigate 20 levels across 5 zones of the
city's electrical infrastructure to reach the **Grand Transformer** and restore
power to the metropolis.

---

## Gameplay

### Core Mechanics

| Mechanic | Description |
|---|---|
| **Static Dash** | Hold **B** to become a pure bolt of energy: 1.5× speed, auto-crosses 1-block gaps |
| **Conductivity** | Sparky clings to metal surfaces. Press **A** on a vertical pipe to zip up/down instantly |
| **Overload** | Collect a Battery to glow white and throw short-range sparks at enemies. Taking a hit reverts to Dim mode |

### Zones

| Zone | Levels | Theme | Key Hazard |
|---|---|---|---|
| **1 – The Suburbs** | 1–4 | Power lines, wooden fences, brick chimneys | Birds-on-a-wire |
| **2 – The Underground** | 5–8 | Damp sewers, copper piping | Water droplets (instant short-out) |
| **3 – The Neon District** | 9–12 | City skylines, flickering neon signs | Neon Bats (sine-wave flight), Flicker Platforms |
| **4 – The Automated Factory** | 13–16 | Conveyor belts, magnets, pistons | Stomper pistons; Magnetic Pull mechanic |
| **5 – The Grand Transformer** | 17–20 | Circuit boards, plasma cores | Rising Dead Current (Level 19 vertical climb) |

**Final Boss:** The Blackout — a cloud of sentient smog that tries to smother your spark.

### The NES Secret

Every 4th level (end of each zone) hides a **Hidden Capacitor**. Collect all five
to unlock the true ending: Sparky becomes the sun of a new digital world.

---

## Technical

| Feature | Detail |
|---|---|
| **Graphics** | High-contrast sprites; bright yellow/cyan Sparky against dark industrial backgrounds |
| **Music** | Fast-paced syncopated chiptune with buzzing triangle-wave basslines |
| **Physics** | Low-friction momentum model (`Vf = Vi + at`); Sparky slides when stopping |
| **Mapper** | NROM |

---

## Building

### Prerequisites

- [cc65](https://cc65.github.io) (ca65 assembler + ld65 linker)
- GNU Make
- *(Optional)* [GIMP](https://www.gimp.org) for rebuilding CHR data from XCF source assets

### Setup

Edit the `Makefile` to point `CC65DIR` at your local cc65 installation and
set emulator paths if you want the `make mesen` / `make fceux` etc. targets.

### Build

```bash
make          # produces dist/sparkr.nes
make mesen    # build and launch in Mesen
make clean    # remove all generated files
```

### Adding new modules

Add the `.o` filename to the `OBJECTS` variable in the `Makefile`, then create
the corresponding `.s` source file in `asm/`. The autodep tool will automatically
track `.include` and `.incbin` dependencies.

---

## Project Layout

```
asm/        Assembly source modules
chr/        Sprite / background assets (XCF → PNG → CHR pipeline)
inc/        Shared include files and macros
ldcfg/      ld65 linker configuration (NROM)
bin/        Build tools (autodep, bmp2nes, xcf2png)
```

---

## License

BSD 3-Clause. See [LICENSE.md](LICENSE.md).

## ☕ Support

If you found this useful, consider [buying me a ko-fi](https://ko-fi.com/ewancroft)!

The `bin/bmp2nes` tool is by Damian Yerrick (see copyright notice within).  
The random number module (`asm/random.s`) is adapted from Damian Yerrick's code
(see copyright notice within).

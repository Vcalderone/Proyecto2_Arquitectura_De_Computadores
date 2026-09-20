# Pochoco SoC & Espino Core

> Meet Pochoco SoC and Espino Core. Inspired by the native flora of the Pochoco trails, it is an entry-level, highly efficient architecture designed to flourish in resource-constrained environments.

![Pochoco SoC Architecture](pochoco_soc.svg)

Welcome to the repository! This project contains the RTL for a custom 32-bit processor and its surrounding System-on-Chip (SoC) designed for FPGA deployment. The design is kept straightforward to help explore and understand computer architecture fundamentals.

This is meant to be forked, not just cloned. You'll be poking around the RTL, so make it your own, we won't judge (we might even be a little proud).

## Repository Structure

The hardware is written in Verilog and divided into these main categories:

* **The Espino Core**: The central processing unit. It includes all standard pipeline stages like instruction fetch, instruction decode, an ALU for execution, a register file, a load/store unit for memory operations, and a pipeline controller. It implements [RV32E](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html) with a catch you might want to check out the code for.
* **The Pochoco SoC**: The top-level system wrapper. It connects the CPU core to a unified instruction/data RAM, physical board peripherals (like LEDs, switches, and displays), and an external SPI slave interface.
* **Build Files**: Constraints to map the design to the physical FPGA pins, and automation scripts for synthesis, routing, and flashing using an open-source toolchain.

## Memory Map

The SoC routes memory and data requests using a hardcoded address decoding scheme based on the highest bits of the 32-bit address.

* **`0x0000_0000` - Unified RAM**: The shared memory space for both instructions and data.
* **`0x8000_0000` - Board Peripherals**: Memory-mapped I/O for the physical board.
  * `Offset 0x00`: 7-Segment Displays
  * `Offset 0x04`: LEDs
  * `Offset 0x08`: Button Inputs
* **`0x8001_0000` - SPI Slave**: Custom SPI interface routing.
  * `Offset 0x00`: SPI Status (Chip Select state, New Data flag)
  * `Offset 0x04`: Received "Price" byte (from external master)
  * `Offset 0x08`: "Decision" byte (written by CPU to transmit)

Dive into the source code to see exactly how these components and connections are built under the hood!

## How to Build

To synthesize and build the project, you will need the open-source FPGA toolchain.

1. Install the tools by following the instructions at the [oss-cad-suite-build repository](https://github.com/yosyshq/oss-cad-suite-build).
2. Once installed, ~~blindly copy-paste~~ (we strongly encourage reading the Makefile first to make sure we aren't deleting your home directory) the following command in the project root to generate and program the final bitstream:

```bash
make all
```

## Software

The `sw/` folder holds the RV32E assembly programs that run on the Espino Core: the reflex game itself (`game.s`) plus the three examples that ship with the SoC (`blink.s`, `7seg.s`, `buttons_leds.s`). They are assembled into the `.hex` files the RTL loads at boot via `$readmemh`.

**No external RISC-V toolchain is ever invoked.** Assembling is done by our own assembler, `assembler/asm.py`, driven from the root `Makefile`. (The old `sw/Makefile` called `riscv64-unknown-elf-as`, and its `%.hex: %.s` rule also matched `game.s` -- so a stray `make` inside `sw/` would have rebuilt the game firmware with the very tool the assignment forbids. It was removed; our assembler reproduces all three example `.hex` files byte for byte, which `assembler/tests/test_golden.py` checks.)

```bash
make asm        # sw/game.s   -> sw/game.hex   (the firmware baked into the bitstream)
make asm-all    # every sw/*.s -> its .hex
make test       # assembler test suite, golden .hex comparisons included
make sim        # both testbenches + the RONDAS=4 regression run
make check      # test + sim
```

Drop a new `<name>.s` file in `sw/` and the generic `sw/%.hex: sw/%.s` rule picks it up automatically, no `Makefile` changes needed. Don't forget to change the MemFile in pochoco_soc.v.

`make sim` needs `iverilog` and the iCE40 cell models (`ice40/cells_sim.v`) that ship with yosys, because `espino_register_file.v` instantiates `SB_RAM40_4K`. The Makefile looks for them under `yosys-config --datdir`, then `/usr/share/yosys`, then `/usr/local/share/yosys`; if yosys came from somewhere else, point at them directly with `make sim CELLS_SIM=/path/to/ice40/cells_sim.v`.

**CATCH:** The core implements [RV32E](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html), with one thing worth knowing: shift instructions (`SLL`/`SRL`/`SRA`/`SLLI`/`SRLI`/`SRAI`) are decoded correctly but disabled in the ALU to save LUTs on the target FPGA, so they currently execute as `ADD` instead. Avoid shifts in your assembly, or design your own shifter...

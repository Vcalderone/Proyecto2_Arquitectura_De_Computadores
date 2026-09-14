# Copyright 2026 Universidad de los Andes.
# Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: SHL-0.51
#
# Course: Arquitectura de Computadores (2026)
# 
# Authors:
# - Nicolás Villegas <navillegas@miuandes.cl>

# Configuration
TOP  := game_top
PCF  := goboard.pcf

# RTL Sources
SRC  := $(wildcard ./rtl/*.v ./rtl/**/*.v)

# Firmware: game_top's default MemFile parameter points here. $readmemh
# bakes sw/game.hex into the bitstream at synth time, so the .hex must be
# a prerequisite of the synthesis step -- changing the program without
# re-synthesizing would silently leave the board running stale code.
ASMSRC := sw/game.s
HEX    := sw/game.hex

# Our own assembler (no external RISC-V toolchain is ever invoked -- see
# docs/assembler.md section 1). Listing its sources as prerequisites means
# a fix in the assembler also regenerates the firmware.
PYTHON ?= python3
ASM    := assembler/asm.py
ASMDEP := $(wildcard assembler/*.py)

# Build Targets
JSON := $(TOP).json
ASC  := $(TOP).asc
BIN  := $(TOP).bin

.PHONY: all prog asm test clean stats

# Default target
all: prog

# Step 0: Assemble the game. This is the link between the two fronts:
# sw/game.s is written by hand, assembler/ translates it, and the rest of
# the flow bakes the result into the bitstream. `make asm` regenerates the
# firmware alone, which is what you want after editing a .equ constant.
$(HEX): $(ASMSRC) $(ASMDEP)
	$(PYTHON) $(ASM) $(ASMSRC) -o $(HEX)

asm: $(HEX)

# Assembler test suite (70 tests, includes the golden .hex comparisons)
test:
	cd assembler && $(PYTHON) -m unittest discover -s tests -t .

# Step 1: Synthesis using Yosys
$(JSON): $(SRC) $(HEX)
	yosys -p "read_verilog $(SRC); synth_ice40 -top $(TOP) -json ${TOP}.json; stat"

# Step 2: Place and Route using NextPNR
$(ASC): $(JSON) $(PCF)
	nextpnr-ice40 --hx1k --package vq100 --freq 25 --json $(JSON) --pcf $(PCF) --asc $(ASC)

# Step 3: Bitstream Generation
$(BIN): $(ASC)
	icepack $(ASC) $(BIN)

# Step 4: Flash the Board
prog: $(BIN)
	iceprog $(BIN)

# Clean up generated files. $(HEX) is regenerable from $(ASMSRC), so it
# goes too -- a stale .hex is exactly the failure mode this Makefile is
# built to avoid.
clean:
	rm -f $(JSON) $(ASC) $(BIN) $(HEX)
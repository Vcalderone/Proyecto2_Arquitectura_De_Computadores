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

# Simulación
#
# Los .hex de simulación son el MISMO sw/game.s con constantes pisadas
# desde la línea de comandos (opción -D del assembler), no una copia del
# programa que se pueda desincronizar del original.
#
#   sw/game_sim.hex     CYCLES_PER_TENTH=2500  -- décima 1000x más corta,
#                       para que las diez rondas corran en segundos de
#                       simulación en vez de minutos.
#   sw/game_sim_r4.hex  además RONDAS=4        -- regresión del bug del
#                       divisor: el promedio se calcula con una división
#                       genérica por RONDAS, no con un /10 clavado.
IVERILOG ?= iverilog
VVP      ?= vvp
BUILD    := build

SIM_CPT    := 2500
SIM_RONDAS := 4
SIM_HEX    := sw/game_sim.hex
SIM_HEX_R4 := sw/game_sim_r4.hex

# espino_register_file.v instancia SB_RAM40_4K, así que la simulación
# necesita el modelo de comportamiento de las celdas iCE40 que trae yosys.
# yosys-config existe en oss-cad-suite pero no si yosys vino del gestor de
# paquetes, así que se prueban también las rutas habituales de instalación.
YOSYS_DATDIR := $(shell yosys-config --datdir 2>/dev/null)
CELLS_SIM_TRY := $(YOSYS_DATDIR)/ice40/cells_sim.v \
                 /usr/share/yosys/ice40/cells_sim.v \
                 /usr/local/share/yosys/ice40/cells_sim.v
CELLS_SIM ?= $(firstword $(wildcard $(CELLS_SIM_TRY)))

.PHONY: all prog asm asm-all test sim check clean stats

# Default target
all: prog

# Step 0: Assemble. Esta es la unión de los dos frentes: sw/*.s se escribe
# a mano, assembler/ lo traduce, y el resto del flujo hornea el resultado
# en el bitstream. `make asm` regenera solo el firmware del juego, que es
# lo que uno quiere tras cambiar un .equ.
#
# La regla es genérica para que `make asm-all` pueda regenerar TODOS los
# .hex de sw/ con el assembler del grupo. Antes había un sw/Makefile que
# llamaba a riscv64-unknown-elf-as; su regla "%.hex: %.s" también alcanzaba
# a game.s, o sea que un `make` dentro de sw/ habría regenerado el firmware
# del juego con la herramienta que el enunciado prohíbe.
sw/%.hex: sw/%.s $(ASMDEP)
	$(PYTHON) $(ASM) $< -o $@

asm: $(HEX)

ASM_ALL := $(patsubst sw/%.s,sw/%.hex,$(wildcard sw/*.s))

asm-all: $(ASM_ALL)

# Los .hex de simulación salen de sw/game.s, no de un .s propio, así que
# necesitan reglas explícitas (que le ganan a la regla genérica de arriba).
$(SIM_HEX): $(ASMSRC) $(ASMDEP)
	$(PYTHON) $(ASM) $< -o $@ -D CYCLES_PER_TENTH=$(SIM_CPT)

$(SIM_HEX_R4): $(ASMSRC) $(ASMDEP)
	$(PYTHON) $(ASM) $< -o $@ -D CYCLES_PER_TENTH=$(SIM_CPT) -D RONDAS=$(SIM_RONDAS)

# Assembler test suite (70 tests, includes the golden .hex comparisons)
test:
	cd assembler && $(PYTHON) -m unittest discover -s tests -t .

# Simulación: los dos testbenches más una tercera corrida del testbench del
# juego con RONDAS=4. Esa tercera corrida es la regresión del divisor: el
# tiempo de reacción inyectado es el mismo (12 décimas), así que el promedio
# tiene que seguir dando 12. Con un div10 fijo daría 48/10 = 4.
#
# Los testbenches llaman a $fatal si algún check falla, así que vvp devuelve
# un código de salida distinto de cero y make se detiene.
sim: $(SIM_HEX) $(SIM_HEX_R4) | $(BUILD)
	@if [ -z "$(CELLS_SIM)" ]; then \
	  echo "error: no se encontro ice40/cells_sim.v, que la simulacion necesita"; \
	  echo "       porque rtl/espino_core/espino_register_file.v instancia SB_RAM40_4K."; \
	  echo "       Se probo, en este orden:"; \
	  for p in $(CELLS_SIM_TRY); do echo "         $$p"; done; \
	  echo "       Pasalo a mano con:  make sim CELLS_SIM=/ruta/a/ice40/cells_sim.v"; \
	  exit 1; \
	fi
	$(IVERILOG) -g2012 -o $(BUILD)/game_top_tb tb/game_top_tb.v $(SRC) $(CELLS_SIM)
	$(VVP) $(BUILD)/game_top_tb
	$(IVERILOG) -g2012 -o $(BUILD)/game_tb tb/game_tb.v $(SRC) $(CELLS_SIM)
	$(VVP) $(BUILD)/game_tb
	$(IVERILOG) -g2012 -DMEMFILE=\"$(SIM_HEX_R4)\" -DRONDAS_N=$(SIM_RONDAS) \
	            -o $(BUILD)/game_tb_r$(SIM_RONDAS) tb/game_tb.v $(SRC) $(CELLS_SIM)
	$(VVP) $(BUILD)/game_tb_r$(SIM_RONDAS)

$(BUILD):
	mkdir -p $(BUILD)

# Todo lo verificable de una: los tests del assembler y los testbenches.
check: test sim

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

# Clean up generated files.
#
# $(HEX) NO se borra: sw/game.hex está versionado y es parte de la entrega
# (es lo que $readmemh hornea en el bitstream). Los .hex de simulación sí,
# que son artefactos derivados y están en .gitignore.
clean:
	rm -f $(JSON) $(ASC) $(BIN) $(SIM_HEX) $(SIM_HEX_R4) *.vcd
	rm -rf $(BUILD)

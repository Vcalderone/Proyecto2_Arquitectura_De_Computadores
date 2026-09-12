#!/usr/bin/env python3
"""CLI entry point: translates a .s file into a $readmemh-style .hex file.

    python asm.py sw/game.s -o sw/game.hex

No external RISC-V assembler is invoked anywhere in this tool -- see
docs/assembler.md section 1 for why that matters.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from core import assemble_file  # noqa: E402
from errors import AssemblerError  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Assembler propio para el Espino Core (RV32E) del Pochoco SoC."
    )
    parser.add_argument("input", help="archivo .s de entrada")
    parser.add_argument(
        "-o",
        "--output",
        help="archivo .hex de salida (por defecto: la entrada con extensión .hex)",
    )
    parser.add_argument(
        "--allow-shifts",
        action="store_true",
        help="permite sll/srl/sra/slli/srli/srai (la ALU los ejecuta como ADD en este core; usar bajo tu propio riesgo)",
    )
    args = parser.parse_args(argv)

    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else input_path.with_suffix(".hex")

    try:
        words = assemble_file(input_path, output_path, allow_shifts=args.allow_shifts)
    except AssemblerError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    print(f"{input_path} -> {output_path} ({len(words)} palabras, {len(words) * 4} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

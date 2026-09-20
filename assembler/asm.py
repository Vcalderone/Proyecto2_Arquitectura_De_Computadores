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

from core import IDENT_RE, assemble_file, parse_number  # noqa: E402
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
    parser.add_argument(
        "-D",
        "--define",
        action="append",
        default=[],
        metavar="NOMBRE=VALOR",
        help="fija una constante desde la línea de comandos y pisa el .equ del archivo con ese nombre (repetible)",
    )
    args = parser.parse_args(argv)

    defines = {}
    for item in args.define:
        name, sep, val = item.partition("=")
        if not sep or not IDENT_RE.match(name):
            print(f"error: -D '{item}': se esperaba NOMBRE=VALOR", file=sys.stderr)
            return 1
        try:
            defines[name] = parse_number(val)
        except ValueError:
            print(f"error: -D '{item}': valor no numérico '{val}'", file=sys.stderr)
            return 1

    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else input_path.with_suffix(".hex")

    try:
        words = assemble_file(input_path, output_path, allow_shifts=args.allow_shifts, defines=defines)
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

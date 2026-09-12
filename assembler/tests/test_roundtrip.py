"""The extra test suggested by docs/assembler.md section 8: assemble,
disassemble, reassemble, compare. This catches encoding asymmetries that a
golden-file comparison can't, since it doesn't depend on already knowing
the correct answer -- only on encode and decode agreeing with each other.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import assemble_text  # noqa: E402
from disasm import disassemble  # noqa: E402

SW_DIR = Path(__file__).resolve().parents[2] / "sw"

ALL_REAL_INSTRUCTIONS = """\
start:
    add x1, x2, x3
    sub x1, x2, x3
    slt x1, x2, x3
    sltu x1, x2, x3
    xor x1, x2, x3
    or x1, x2, x3
    and x1, x2, x3
    addi x1, x2, 100
    slti x1, x2, 100
    sltiu x1, x2, 100
    xori x1, x2, -100
    ori x1, x2, 100
    andi x1, x2, 100
    lw x1, 4(x2)
    lh x1, 4(x2)
    lhu x1, 4(x2)
    lb x1, 4(x2)
    lbu x1, 4(x2)
    sw x1, 4(x2)
    sh x1, 4(x2)
    sb x1, 4(x2)
    beq x1, x2, loop
    bne x1, x2, loop
    blt x1, x2, loop
    bge x1, x2, loop
    bltu x1, x2, loop
    bgeu x1, x2, loop
loop:
    jal x1, loop
    jalr x1, 4(x2)
    lui x1, 0x12345
    auipc x1, 0x12345
"""

ALL_SHIFT_INSTRUCTIONS = """\
    sll x1, x2, x3
    srl x1, x2, x3
    sra x1, x2, x3
    slli x1, x2, 5
    srli x1, x2, 5
    srai x1, x2, 5
"""


def roundtrip(text, allow_shifts=False):
    words = assemble_text(text, allow_shifts=allow_shifts)
    disassembled = "\n".join(disassemble(words, allow_shifts=allow_shifts))
    words2 = assemble_text(disassembled, allow_shifts=allow_shifts)
    return words, words2


class RoundtripTests(unittest.TestCase):
    def test_all_real_instructions(self):
        words, words2 = roundtrip(ALL_REAL_INSTRUCTIONS)
        self.assertEqual(words, words2)
        self.assertGreater(len(words), 0)

    def test_all_shift_instructions(self):
        words, words2 = roundtrip(ALL_SHIFT_INSTRUCTIONS, allow_shifts=True)
        self.assertEqual(words, words2)
        self.assertGreater(len(words), 0)

    def _check_golden(self, name):
        source = (SW_DIR / f"{name}.s").read_text(encoding="utf-8")
        words, words2 = roundtrip(source)
        self.assertEqual(words, words2)

    def test_blink(self):
        self._check_golden("blink")

    def test_7seg(self):
        self._check_golden("7seg")

    def test_buttons_leds(self):
        self._check_golden("buttons_leds")


if __name__ == "__main__":
    unittest.main()

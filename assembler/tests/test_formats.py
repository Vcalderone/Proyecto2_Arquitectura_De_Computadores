"""Hand-computed encodings for what the golden files in sw/ don't cover:
sub, slt, the four branches other than beq/bne, jalr and auipc.

Every expected value below was worked out by hand from the bit layouts in
docs/assembler.md section 4 (same method as the blink.s example in section
9), independently of core.py's encoders -- so a shared bug in encode_r/
encode_i/... would not be masked by these tests.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import assemble_text  # noqa: E402


def asm_one(text):
    words = assemble_text(text)
    return [f"{w & 0xFFFFFFFF:08x}" for w in words]


class RTypeTests(unittest.TestCase):
    def test_sub(self):
        # opcode 0110011, funct7 0100000, funct3 000, rd=5, rs1=6, rs2=7
        self.assertEqual(asm_one("sub x5, x6, x7"), ["407302b3"])

    def test_slt(self):
        # opcode 0110011, funct7 0000000, funct3 010, rd=5, rs1=6, rs2=7
        self.assertEqual(asm_one("slt x5, x6, x7"), ["007322b3"])


class BranchTests(unittest.TestCase):
    def _branch(self, mnemonic, expected_hex):
        text = f"{mnemonic} x5, x6, target\nnop\ntarget:\n"
        self.assertEqual(asm_one(text), [expected_hex, "00000013"])

    def test_blt(self):
        self._branch("blt", "0062c463")

    def test_bge(self):
        self._branch("bge", "0062d463")

    def test_bltu(self):
        self._branch("bltu", "0062e463")

    def test_bgeu(self):
        self._branch("bgeu", "0062f463")


class JumpAndUpperImmTests(unittest.TestCase):
    def test_jalr(self):
        # opcode 1100111, rd=1, funct3=000, rs1=2, imm=4
        self.assertEqual(asm_one("jalr x1, 4(x2)"), ["004100e7"])

    def test_auipc(self):
        # opcode 0010111, rd=5, imm20=1
        self.assertEqual(asm_one("auipc x5, 0x1"), ["00001297"])


if __name__ == "__main__":
    unittest.main()

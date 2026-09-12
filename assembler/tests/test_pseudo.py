"""Pseudo-instruction expansion, per docs/assembler.md section 6.

Most expected hex values here were hand-computed the same way as in
test_formats.py. The `li` sign-correction cases are the two points the
spec calls out as the ones everybody gets wrong (the +0x800 correction and
the off-by-4 in branch/jal offsets), so those are checked by decoding the
produced words back with isa.imm_u/imm_i and asserting on hi/lo directly --
that's the strongest check available, since it doesn't depend on hi/lo
happening to combine into the same final hex some other bug would also
produce.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import assemble_text  # noqa: E402
from isa import field_opcode, field_rd, imm_i, imm_u, OPCODE_I_ARITH, OPCODE_LUI  # noqa: E402


def asm_one(text):
    words = assemble_text(text)
    return [f"{w & 0xFFFFFFFF:08x}" for w in words]


class SimplePseudoTests(unittest.TestCase):
    def test_nop(self):
        self.assertEqual(asm_one("nop"), ["00000013"])

    def test_mv(self):
        self.assertEqual(asm_one("mv x5, x6"), ["00030293"])

    def test_not(self):
        self.assertEqual(asm_one("not x5, x6"), ["fff34293"])

    def test_neg(self):
        self.assertEqual(asm_one("neg x5, x6"), ["406002b3"])

    def test_j(self):
        # j target; target is the next instruction (offset +4)
        self.assertEqual(asm_one("j target\ntarget:\n"), ["0040006f"])

    def test_jr(self):
        self.assertEqual(asm_one("jr x1"), ["00008067"])

    def test_ret(self):
        self.assertEqual(asm_one("ret"), ["00008067"])

    def test_beqz(self):
        self.assertEqual(asm_one("beqz x5, target\nnop\ntarget:\n"), ["00028463", "00000013"])

    def test_bnez(self):
        self.assertEqual(asm_one("bnez x5, target\nnop\ntarget:\n"), ["00029463", "00000013"])

    def test_bltz(self):
        self.assertEqual(asm_one("bltz x5, target\nnop\ntarget:\n"), ["0002c463", "00000013"])

    def test_la(self):
        # la x5, target; target sits at byte address 100 (25 nops * 4)
        text = "\n".join(["nop"] * 25) + "\ntarget:\nla x5, target\n"
        words = assemble_text(text)
        last = words[-1] & 0xFFFFFFFF
        self.assertEqual(field_opcode(last), OPCODE_I_ARITH)
        self.assertEqual(imm_i(last), 100)


class LiTests(unittest.TestCase):
    def test_li_fits_in_addi(self):
        self.assertEqual(asm_one("li x5, 100"), ["06400293"])

    def test_li_negative_fits_in_addi(self):
        # -1 as a 12-bit signed immediate: addi x5, x0, -1
        self.assertEqual(asm_one("li x5, -1"), ["fff00293"])

    def test_li_low_bits_zero_uses_lui_only(self):
        words = assemble_text("li x5, 0x80000000")
        self.assertEqual(len(words), 1)
        self.assertEqual(field_opcode(words[0] & 0xFFFFFFFF), OPCODE_LUI)
        self.assertEqual(imm_u(words[0] & 0xFFFFFFFF), 0x80000)

    def test_li_sign_correction_doc_example(self):
        # docs/assembler.md section 6: li rd, 75_000_000 must produce
        # hi=0x04787 (not 0x04786) and lo=-1856.
        words = assemble_text("li x5, 75000000")
        self.assertEqual(len(words), 2)
        lui_word, addi_word = (w & 0xFFFFFFFF for w in words)

        self.assertEqual(field_opcode(lui_word), OPCODE_LUI)
        self.assertEqual(imm_u(lui_word), 0x04787)
        self.assertEqual(field_rd(lui_word), 5)

        self.assertEqual(field_opcode(addi_word), OPCODE_I_ARITH)
        self.assertEqual(imm_i(addi_word), -1856)
        self.assertEqual(field_rd(addi_word), 5)

        # Reconstructing the constant from hi/lo must round-trip exactly.
        hi = imm_u(lui_word)
        lo = imm_i(addi_word)
        self.assertEqual((hi << 12) + lo, 75_000_000)

    def test_li_sign_correction_game_example(self):
        # From the user's own worked example: li rd, 0x04C11DB7 must give
        # lui rd, 0x04C12 (not 0x04C11) + addi rd, rd, -585.
        words = assemble_text("li x5, 0x04C11DB7")
        self.assertEqual(len(words), 2)
        lui_word, addi_word = (w & 0xFFFFFFFF for w in words)

        self.assertEqual(imm_u(lui_word), 0x04C12)
        self.assertEqual(imm_i(addi_word), -585)

        hi = imm_u(lui_word)
        lo = imm_i(addi_word)
        self.assertEqual((hi << 12) + lo, 0x04C11DB7)


if __name__ == "__main__":
    unittest.main()

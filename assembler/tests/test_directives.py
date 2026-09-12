""".equ and .word, per docs/assembler.md section 5 -- neither is exercised
by the golden sw/*.s files, so they need their own coverage. Also covers
case (in)sensitivity: mnemonics/registers are case-insensitive, labels and
.equ names are case-sensitive.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import assemble_text  # noqa: E402
from errors import AssemblerError  # noqa: E402


def asm_one(text):
    words = assemble_text(text)
    return [f"{w & 0xFFFFFFFF:08x}" for w in words]


class EquTests(unittest.TestCase):
    def test_equ_used_as_immediate(self):
        text = ".equ TENTHS_3S, 30\naddi x5, x0, TENTHS_3S\n"
        # addi x5, x0, 30
        self.assertEqual(asm_one(text), ["01e00293"])

    def test_equ_hex_and_binary_values(self):
        text = ".equ A, 0x1F\n.equ B, 0b101\naddi x5, x0, A\naddi x6, x0, B\n"
        words = assemble_text(text)
        self.assertEqual(words[0] & 0xFFF00000, 0x1F00000)
        self.assertEqual(words[1] & 0xFFF00000, 0x00500000)

    def test_equ_names_are_case_sensitive(self):
        text = ".equ foo, 1\naddi x5, x0, FOO\n"
        with self.assertRaises(AssemblerError):
            assemble_text(text)


class WordTests(unittest.TestCase):
    def test_word_emits_literal_data(self):
        text = ".word 1, 2, 3\n"
        words = assemble_text(text)
        self.assertEqual(words, [1, 2, 3])

    def test_word_accepts_hex_and_negative(self):
        text = ".word 0xDEADBEEF, -1\n"
        words = assemble_text(text)
        self.assertEqual([w & 0xFFFFFFFF for w in words], [0xDEADBEEF, 0xFFFFFFFF])

    def test_word_can_reference_a_forward_label(self):
        # a jump table entry pointing at a label defined later in the file
        text = ".word target\nnop\ntarget:\n"
        words = assemble_text(text)
        self.assertEqual(words[0], 8)

    def test_word_size_counts_toward_ram_limit(self):
        text = "\n".join(["nop"] * 511) + "\n.word 1, 2\n"
        with self.assertRaises(AssemblerError):
            assemble_text(text)


class IgnoredDirectiveTests(unittest.TestCase):
    def test_section_text_global_are_ignored(self):
        text = ".section .text\n.global _start\n_start:\nnop\n"
        self.assertEqual(asm_one(text), ["00000013"])


class CaseSensitivityTests(unittest.TestCase):
    def test_mnemonics_and_registers_are_case_insensitive(self):
        self.assertEqual(asm_one("ADDI X5, X0, 1"), asm_one("addi x5, x0, 1"))
        self.assertEqual(asm_one("Addi x5, X0, 1"), asm_one("addi x5, x0, 1"))

    def test_labels_are_case_sensitive(self):
        text = "Loop:\nnop\nj loop\n"
        with self.assertRaises(AssemblerError):
            assemble_text(text)


if __name__ == "__main__":
    unittest.main()

"""Validation, per docs/assembler.md section 8 -- this is an explicit item
of the rubric, not optional. Every one of these has to fail with a clear
message and a line number.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import (  # noqa: E402
    assemble_text,
    check_branch_range,
    check_jal_range,
)
from errors import AssemblerError  # noqa: E402


class RegisterValidationTests(unittest.TestCase):
    def test_rejects_x16_and_above(self):
        with self.assertRaises(AssemblerError) as ctx:
            assemble_text("addi x16, x0, 1")
        self.assertIn("x16", str(ctx.exception))
        self.assertEqual(ctx.exception.line, 1)

    def test_rejects_x31(self):
        with self.assertRaises(AssemblerError):
            assemble_text("add x31, x0, x0")

    def test_unknown_register_name(self):
        with self.assertRaises(AssemblerError):
            assemble_text("addi x0, banana, 1")

    def test_accepts_abi_names(self):
        # sp is x2, same encoding as the numeric form.
        words_numeric = assemble_text("addi x2, x2, 4")
        words_abi = assemble_text("addi sp, sp, 4")
        self.assertEqual(words_numeric, words_abi)


class ShiftValidationTests(unittest.TestCase):
    def test_shifts_rejected_by_default(self):
        for mnemonic in ("sll", "srl", "sra"):
            with self.assertRaises(AssemblerError):
                assemble_text(f"{mnemonic} x5, x5, x6")
        for mnemonic in ("slli", "srli", "srai"):
            with self.assertRaises(AssemblerError):
                assemble_text(f"{mnemonic} x5, x5, 2")

    def test_shifts_allowed_with_flag(self):
        words = assemble_text("slli x5, x5, 2", allow_shifts=True)
        self.assertEqual(len(words), 1)


class MnemonicAndLabelTests(unittest.TestCase):
    def test_unknown_mnemonic(self):
        with self.assertRaises(AssemblerError):
            assemble_text("mul x5, x6, x7")

    def test_undefined_label(self):
        with self.assertRaises(AssemblerError):
            assemble_text("j fin")

    def test_duplicate_label(self):
        with self.assertRaises(AssemblerError):
            assemble_text("loop:\nnop\nloop:\nnop\n")

    def test_duplicate_equ(self):
        with self.assertRaises(AssemblerError):
            assemble_text(".equ N, 1\n.equ N, 2\naddi x5, x0, N\n")


class ImmediateRangeTests(unittest.TestCase):
    def test_addi_immediate_too_large(self):
        with self.assertRaises(AssemblerError):
            assemble_text("addi x5, x0, 5000")

    def test_addi_immediate_too_negative(self):
        with self.assertRaises(AssemblerError):
            assemble_text("addi x5, x0, -5000")

    def test_addi_immediate_boundary_ok(self):
        assemble_text("addi x5, x0, 2047")
        assemble_text("addi x5, x0, -2048")

    def test_lui_immediate_out_of_range(self):
        with self.assertRaises(AssemblerError):
            assemble_text("lui x5, 0x100000")

    def test_lui_immediate_boundary_ok(self):
        assemble_text("lui x5, 0xFFFFF")

    def test_li_value_does_not_fit_in_32_bits(self):
        with self.assertRaises(AssemblerError):
            assemble_text("li x5, 0x100000000")


class OperandCountTests(unittest.TestCase):
    def test_too_few_operands(self):
        with self.assertRaises(AssemblerError):
            assemble_text("add x5, x6")

    def test_too_many_operands(self):
        with self.assertRaises(AssemblerError):
            assemble_text("add x5, x6, x7, x8")

    def test_bad_mem_operand_syntax(self):
        with self.assertRaises(AssemblerError):
            assemble_text("lw x5, x6")


class ProgramSizeTests(unittest.TestCase):
    def test_program_over_512_words_rejected(self):
        text = "\n".join(["nop"] * 513)
        with self.assertRaises(AssemblerError):
            assemble_text(text)

    def test_program_at_exactly_512_words_ok(self):
        text = "\n".join(["nop"] * 512)
        words = assemble_text(text)
        self.assertEqual(len(words), 512)


class BranchAndJalRangeTests(unittest.TestCase):
    """All instructions are 4 bytes, so within a single (<=512-word) program
    every label sits at a multiple of 4 and no reachable offset can exceed
    the branch/jal range. The checks below exercise the pure range/parity
    functions directly instead, which is the only way to reach them.
    """

    def test_branch_range_boundaries_ok(self):
        check_branch_range(4094, 1)
        check_branch_range(-4096, 1)

    def test_branch_range_too_far_positive(self):
        with self.assertRaises(AssemblerError):
            check_branch_range(4096, 1)

    def test_branch_range_too_far_negative(self):
        with self.assertRaises(AssemblerError):
            check_branch_range(-4098, 1)

    def test_branch_odd_offset_rejected(self):
        with self.assertRaises(AssemblerError):
            check_branch_range(3, 1)

    def test_jal_range_boundaries_ok(self):
        check_jal_range(1048574, 1)
        check_jal_range(-1048576, 1)

    def test_jal_range_too_far(self):
        with self.assertRaises(AssemblerError):
            check_jal_range(1048576, 1)

    def test_jal_odd_offset_rejected(self):
        with self.assertRaises(AssemblerError):
            check_jal_range(5, 1)


if __name__ == "__main__":
    unittest.main()

"""-D / --define: command-line constants that override or supplement .equ."""

import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from asm import main  # noqa: E402
from core import assemble_text  # noqa: E402


class DefineTests(unittest.TestCase):
    def test_define_overrides_equ(self):
        text = ".equ N, 5\naddi x5, x0, N\n"
        self.assertEqual(assemble_text(text)[0] & 0xFFFFFFFF, 0x00500293)
        words = assemble_text(text, defines={"N": 7})
        self.assertEqual(words[0] & 0xFFFFFFFF, 0x00700293)

    def test_define_without_equ_in_file(self):
        words = assemble_text("addi x5, x0, N\n", defines={"N": 3})
        self.assertEqual(words[0] & 0xFFFFFFFF, 0x00300293)

    def test_cli_non_numeric_value_is_error(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "a.s"
            src.write_text("addi x5, x0, 1\n")
            err = StringIO()
            with redirect_stderr(err):
                rc = main([str(src), "-o", str(Path(d) / "a.hex"), "-D", "N=abc"])
            self.assertEqual(rc, 1)
            self.assertIn("error", err.getvalue())


if __name__ == "__main__":
    unittest.main()

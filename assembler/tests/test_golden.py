"""The first test required by docs/assembler.md section 8: assemble the
three .s programs that ship with the repo and compare, line by line,
against their already-committed .hex files. This does not violate the
'no external assembler' restriction -- nothing is invoked here, we're
just comparing against data that was already in the repo.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import assemble_text  # noqa: E402

SW_DIR = Path(__file__).resolve().parents[2] / "sw"


class GoldenFileTests(unittest.TestCase):
    def _check(self, name):
        source = (SW_DIR / f"{name}.s").read_text(encoding="utf-8")
        expected = (SW_DIR / f"{name}.hex").read_text(encoding="utf-8").splitlines()
        expected = [line.strip() for line in expected if line.strip()]

        words = assemble_text(source)
        actual = [f"{w & 0xFFFFFFFF:08x}" for w in words]

        self.assertEqual(actual, expected)

    def test_blink(self):
        self._check("blink")

    def test_7seg(self):
        self._check("7seg")

    def test_buttons_leds(self):
        self._check("buttons_leds")


if __name__ == "__main__":
    unittest.main()

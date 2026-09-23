#!/usr/bin/env python3
from __future__ import annotations
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location("selector",ROOT/"scripts"/"select_macos_developer_id.py")
MODULE=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(MODULE)

class DeveloperIDSelectorTests(unittest.TestCase):
    def test_selects_exact_team_identity(self):
        output='''  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Example One (ABCDE12345)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Example (ABCDE12345)"
  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Other (ZZZZZZZZZZ)"
'''
        self.assertEqual(MODULE.parse(output,"ABCDE12345"),"A"*40)

    def test_rejects_zero_or_ambiguous_identity(self):
        with self.assertRaisesRegex(ValueError,"exactly one"):
            MODULE.parse("", "ABCDE12345")
        output='''  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Old (ABCDE12345)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: New (ABCDE12345)"
'''
        with self.assertRaisesRegex(ValueError,"exactly one"):
            MODULE.parse(output,"ABCDE12345")

if __name__=="__main__":unittest.main()

import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('nightly', Path(__file__).parents[1] / 'ios/nightly_testflight.py')
n = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(n)


class NightlyTests(unittest.TestCase):
    def test_duplicate_and_overlap_fail_closed_even_same_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'a', '2026-10-06')
            for owner, day in [('a', '2026-10-06'), ('b', '2026-10-06'), ('b', '2026-10-07')]:
                with self.assertRaises(ValueError):
                    n.transition(path, 'claim', owner, day)

    def test_owner_finish_and_next_day(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'a', '2026-10-06')
            with self.assertRaises(ValueError):
                n.transition(path, 'finish', 'b', '2026-10-06', 'testing')
            n.transition(path, 'finish', 'a', '2026-10-06', 'blocked_auth')
            with self.assertRaises(ValueError):
                n.transition(path, 'claim', 'a', '2026-10-06')
            self.assertEqual(n.transition(path, 'claim', 'b', '2026-10-07')['status'], 'active')

    def test_no_owner_or_fabricated_outcome(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            with self.assertRaises(ValueError):
                n.transition(path, 'claim', '', '2026-10-06')
            n.transition(path, 'claim', 'a', '2026-10-06')
            with self.assertRaises(ValueError):
                n.transition(path, 'finish', 'a', '2026-10-06', 'success')

    def test_private_path_rejects_outside_and_symlink(self):
        with self.assertRaises(ValueError):
            n.safe_private(n.ROOT / 'docs/release.json')
        with tempfile.TemporaryDirectory() as temp:
            link = Path(temp) / 'link'
            link.symlink_to(n.PRIVATE)
            with self.assertRaises(ValueError):
                n.safe_private(link)

    def test_ledger_symlink_cannot_overwrite_other_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            evidence = path / 'receipt.json'
            evidence.write_text('preserve')
            (path / 'ledger.json').symlink_to(evidence)
            with self.assertRaises(ValueError):
                n.transition(path, 'claim', 'a', '2026-10-06')
            self.assertEqual(evidence.read_text(), 'preserve')

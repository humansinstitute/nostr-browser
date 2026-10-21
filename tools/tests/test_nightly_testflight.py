import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('nightly', Path(__file__).parents[1] / 'ios/nightly_testflight.py')
n = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(n)


class NightlyTests(unittest.TestCase):
    old = {'nbrowser': 'a' * 40, 'flightdeck': 'b' * 40}
    new = {'nbrowser': 'c' * 40, 'flightdeck': 'd' * 40}

    def test_duplicate_and_overlap_fail_closed_even_same_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'a', '2026-10-06', source=self.old)
            for owner, day in [('a', '2026-10-06'), ('b', '2026-10-06'), ('b', '2026-10-07')]:
                with self.assertRaises(ValueError):
                    n.transition(path, 'claim', owner, day, source=self.new)

    def test_owner_finish_and_next_day(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'a', '2026-10-06', source=self.old)
            with self.assertRaises(ValueError):
                n.transition(path, 'finish', 'b', '2026-10-06', 'testing')
            n.transition(path, 'finish', 'a', '2026-10-06', 'blocked_auth')
            with self.assertRaises(ValueError):
                n.transition(path, 'claim', 'a', '2026-10-06', source=self.old)
            self.assertEqual(n.transition(path, 'claim', 'b', '2026-10-07', source=self.old)['status'], 'active')

    def test_failed_source_can_be_followed_by_newer_source_same_day(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'manual', '2026-10-21', source=self.old)
            n.transition(path, 'finish', 'manual', '2026-10-21', 'failed')
            with self.assertRaisesRegex(ValueError, 'exact committed source'):
                n.transition(path, 'claim', 'scheduled', '2026-10-21', source=self.old)
            got = n.transition(path, 'claim', 'scheduled', '2026-10-21', source=self.new)
            self.assertEqual(got['attempt'], 2)
            self.assertEqual(got['source'], self.new)

    def test_source_identity_names_canonical_repo(self):
        with patch.object(n, 'git', side_effect=['main', '', 'a' * 40, 'main', '', 'b' * 40]):
            self.assertEqual(n.source_identity('/flightdeck'), self.old)

    def test_no_owner_or_fabricated_outcome(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            with self.assertRaises(ValueError):
                n.transition(path, 'claim', '', '2026-10-06')
            n.transition(path, 'claim', 'a', '2026-10-06', source=self.old)
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
                n.transition(path, 'claim', 'a', '2026-10-06', source=self.old)
            self.assertEqual(evidence.read_text(), 'preserve')

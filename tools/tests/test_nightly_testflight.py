import importlib.util
import json
import os
import sys
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

    def test_delivered_readback_continuation_preserves_finished_claim(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'worker', '2026-10-24', source=self.old)
            n.transition(path, 'finish', 'worker', '2026-10-24', 'action_required')
            before = json.loads((path / 'ledger.json').read_text())['days']['2026-10-24']['attempts'][0]
            state = dict(api=True, stage='api_action_required', source=self.old,
                         upload_command_completed_at='2026-10-24T00:00:00Z')
            got = n.resume_readback(path, 'worker', '2026-10-24', 'delivered-run', state)
            self.assertEqual(got['readback_run'], 'delivered-run')
            attempts = json.loads((path / 'ledger.json').read_text())['days']['2026-10-24']['attempts']
            self.assertEqual(attempts[0], before)
            self.assertEqual(len(attempts), 2)
            with self.assertRaises(ValueError):
                n.resume_readback(path, 'worker', '2026-10-24', 'delivered-run', state)

    def test_readback_continuation_rejects_other_owner_source_and_unuploaded_run(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'worker', '2026-10-24', source=self.old)
            n.transition(path, 'finish', 'worker', '2026-10-24', 'action_required')
            state = dict(api=True, stage='api_action_required', source=self.old,
                         upload_command_completed_at='2026-10-24T00:00:00Z')
            for owner, run, changed in [('other', 'run', state), ('worker', '../run', state),
                    ('worker', 'run', dict(state, source=self.new)),
                    ('worker', 'run', dict(state, stage='exported')),
                    ('worker', 'run', dict(state, upload_command_completed_at=None))]:
                with self.assertRaises(ValueError):
                    n.resume_readback(path, owner, '2026-10-24', run, changed)

    def test_continued_claim_cannot_reserve_build_or_upload_or_read_another_run(self):
        sys.path.insert(0, str(Path(__file__).parents[1] / 'ios'))
        import testflight_api_release as api
        day = n.dt.datetime.now(n.ZoneInfo('Australia/Perth')).date().isoformat()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            n.transition(path, 'claim', 'worker', day, source=self.old)
            n.transition(path, 'finish', 'worker', day, 'action_required')
            n.resume_readback(path, 'worker', day, 'exact-run', dict(api=True,
                stage='api_action_required', source=self.old, upload_command_completed_at='now'))
            with patch.dict(sys.modules, nightly_testflight=n), patch.object(n, 'PRIVATE', path), \
                    patch.object(n, 'safe_private'), patch.dict(os.environ, SESSION_ID='worker'):
                api.require_daily_claim(Path('exact-run'), 'api-readback')
                for action in ['api-reserve', 'api-build', 'api-upload']:
                    with self.assertRaisesRegex(ValueError, 'never upload'):
                        api.require_daily_claim(Path('exact-run'), action)
                with self.assertRaises(ValueError):
                    api.require_daily_claim(Path('another-run'), 'api-readback')

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

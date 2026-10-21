"""Release safety tests: no Flutter, Apple network calls, signing or uploads."""
import argparse
import contextlib
import io
import os
import subprocess
import time
import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'ios/testflight_release.py')
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.s = {'schema': 1, 'version': '0.1.7', 'build': 9,
                  'stage': 'initialized', 'app_id': '123',
                  'source_commit': 'a' * 40}
        self.o = {'observed_at': r.now(), 'xcode_gui_account_present': True,
                  'team': r.TEAM, 'bundle': r.BUNDLE, 'app_id': '123',
                  'existing_builds': [8], 'history_complete': True, 'latest_version': '0.1.6',
                  'group': r.GROUP, 'internal': True, 'tester_count': 1, 'sole_tester_is_owner': True,
                  'public_link': False, 'other_distribution_groups': [], 'automatic_distribution_reviewed': True}
        self.b = dict(self.o, version='0.1.7', build=9, receipt_or_build_id='apple-build-id',
                      processing='complete', encryption_compliance='complete', assigned_to_group=True,
                      internal_only=True, owner_sees_exact_build=True)

    def test_preflight_and_no_accounts_is_not_logout(self):
        self.o['cli_error'] = 'No Accounts'
        r.preflight(self.o, self.s)
        self.assertIn('does not mean Xcode is signed out', r.ACCOUNT_HELP)

    def test_missing_gui_account_fails(self):
        self.o['xcode_gui_account_present'] = False
        with self.assertRaisesRegex(ValueError, 'existing account'):
            r.preflight(self.o, self.s)

    def test_team_and_bundle_mismatch(self):
        for key in ['team', 'bundle']:
            with self.subTest(key=key):
                o = dict(self.o, **{key: 'wrong'})
                with self.assertRaises(ValueError):
                    r.preflight(o, self.s)

    def test_duplicate_and_older_build(self):
        for build in [8, 7, 9]:
            with self.subTest(build=build):
                with self.assertRaisesRegex(ValueError, 'Duplicate'):
                    r.preflight(dict(self.o, existing_builds=[8, 9]), dict(self.s, build=build))

    def test_incomplete_history(self):
        with self.assertRaisesRegex(ValueError, 'all iOS build history'):
            r.preflight(dict(self.o, history_complete=False), self.s)

    def test_old_version(self):
        with self.assertRaisesRegex(ValueError, 'older'):
            r.preflight(dict(self.o, latest_version='0.2.0'), self.s)

    def test_stale_observation(self):
        with self.assertRaisesRegex(ValueError, '24 hours'):
            r.preflight(dict(self.o, observed_at='2020-01-01T00:00:00+00:00'), self.s)

    def test_audience_drift(self):
        for change in [dict(tester_count=2), dict(sole_tester_is_owner=False), dict(group='Other'),
                       dict(public_link=True), dict(other_distribution_groups=['Other']), dict(internal=False)]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                r.preflight(dict(self.o, **change), self.s)

    def test_upload_processing_and_ready_are_distinct(self):
        self.assertEqual(r.readback(dict(self.b, processing='processing'), self.s), 'uploaded_processing')
        self.assertEqual(r.readback(dict(self.b, processing='failed'), self.s), 'uploaded_action_required')
        self.assertEqual(r.readback(dict(self.b, encryption_compliance='pending'), self.s), 'uploaded_action_required')
        self.assertEqual(r.readback(dict(self.b, owner_sees_exact_build=False), self.s), 'processed_awaiting_tester')
        self.assertEqual(r.readback(self.b, self.s), 'ready_to_test')

    def test_no_receipt_or_wrong_build_never_ready(self):
        for change in [dict(receipt_or_build_id=None), dict(build=8), dict(app_id='456'),
                       dict(assigned_to_group=False), dict(internal_only=False), dict(tester_count=2)]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                r.readback(dict(self.b, **change), self.s)

    def test_stale_ipa(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            (run / 'Runner.xcarchive').mkdir()
            (run / 'export').mkdir()
            (run / 'export/stale.ipa').write_bytes(b'old')
            s = dict(self.s, archive_hashes={}, export_started_ns=10**30)
            with patch.object(r, 'signed_app'), self.assertRaisesRegex(ValueError, 'Stale IPA'):
                r.validate_artifacts(run, s)

    def test_changed_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            (run / 'Runner.xcarchive').mkdir()
            (run / 'Runner.xcarchive/file').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Archive changed'):
                r.validate_artifacts(run, dict(self.s, archive_hashes={}))

    def test_profile_validation_both_targets(self):
        for bundle in [r.BUNDLE, r.BUNDLE + '.FipsPacketTunnel']:
            info = dict(CFBundleIdentifier=bundle,
                        CFBundleShortVersionString='0.1.7',
                        CFBundleVersion='9',
                        NBrowserSourceCommit='a' * 40,
                        NBrowserSourceRepository=r.SOURCE_REPOSITORY)
            ent = {'application-identifier': r.TEAM + '.' + bundle,
                   'com.apple.developer.team-identifier': r.TEAM, 'get-task-allow': False,
                   'beta-reports-active': True, 'com.apple.developer.networking.networkextension': ['packet-tunnel-provider']}
            profile = {'TeamIdentifier': [r.TEAM], 'ExpirationDate': dt.datetime.now() + dt.timedelta(days=1), 'Entitlements': ent}
            r.profile_check(info, profile, ent, self.s, bundle)
            for key, value in [('ProvisionedDevices', ['generic-device']), ('TeamIdentifier', ['WRONG'])]:
                with self.subTest(bundle=bundle, key=key), self.assertRaises(ValueError):
                    r.profile_check(info, dict(profile, **{key: value}), ent, self.s, bundle)
            for change in [{'get-task-allow': True}, {'application-identifier': 'wrong'},
                           {'com.apple.developer.networking.networkextension': []}]:
                with self.subTest(change=change), self.assertRaises(ValueError):
                    r.profile_check(info, profile, dict(ent, **change), self.s, bundle)
            with self.assertRaisesRegex(ValueError, 'stale artifact'):
                r.profile_check(dict(info, CFBundleVersion='8'), profile, ent, self.s, bundle)
            with self.assertRaisesRegex(ValueError, 'source provenance'):
                r.profile_check(dict(info, NBrowserSourceCommit='b' * 40),
                                profile, ent, self.s, bundle)

    def test_dry_run_no_build_or_state_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            r.write(run / 'state.json', self.s)
            r.write(run / 'preflight.json', self.o)
            before = (run / 'state.json').read_bytes()
            with patch.object(r, 'logged') as log, patch.object(r, 'command') as cmd:
                r.execute(argparse.Namespace(action='run', dry_run=True), run)
            log.assert_not_called()
            cmd.assert_not_called()
            self.assertEqual(before, (run / 'state.json').read_bytes())

    def test_upload_pending_barrier_prevents_repeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            s = dict(self.s, stage='exported', artifact={'sha256': 'exact-ipa'})
            r.write(run / 'state.json', s)
            r.write(run / 'preflight.json', self.o)
            with patch.object(r, 'validate_artifacts', return_value=s['artifact']), patch.object(r, 'logged') as log:
                r.execute(argparse.Namespace(action='upload'), run)
                log.assert_not_called()
            self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
            with self.assertRaisesRegex(ValueError, 'pending or performed'):
                r.execute(argparse.Namespace(action='upload'), run)

    def test_ipa_cannot_establish_uploaded_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            r.write(run / 'state.json', dict(self.s, stage='exported'))
            with self.assertRaisesRegex(ValueError, 'IPA is not evidence'):
                r.execute(argparse.Namespace(action='readback'), run)

    def test_preserve_existing_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = root / 'run'
            run.mkdir()
            output = root / 'app/build/ios/archive'
            output.mkdir(parents=True)
            (output / 'record').write_bytes(b'original\x00bytes')
            with patch.object(r, 'ROOT', root):
                r.preserve_outputs(run)
            self.assertEqual((run / 'previous-archive/record').read_bytes(), b'original\x00bytes')
            self.assertEqual(r.read(run / 'previous-archive-hashes.json'), r.tree_hash(run / 'previous-archive'))

    def test_cli_no_accounts_error_gives_gui_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = io.StringIO()
            def failed(args, stdout, stderr):
                stdout.write(b'error: No Accounts\n')
                return subprocess.CompletedProcess(args, 1)
            with patch.object(r.subprocess, 'run', side_effect=failed), contextlib.redirect_stdout(output):
                with self.assertRaisesRegex(ValueError, 'No upload'):
                    r.logged(['xcodebuild'], Path(tmp), 'export')
            self.assertIn('does not mean Xcode is signed out', output.getvalue())
            self.assertIn('Organizer', output.getvalue())

    def test_failed_build_export_retains_archive_and_resumes_without_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = root / 'run'
            run.mkdir()
            r.write(run / 'state.json', self.s)
            r.write(run / 'preflight.json', self.o)
            source = root / 'app/build/ios/archive/Runner.xcarchive'
            def build_failed(*args):
                source.mkdir(parents=True)
                (source / 'record').write_bytes(b'archive')
                future = time.time_ns() + 1000000
                os.utime(source, ns=(future, future))
                raise ValueError('No Accounts')
            with patch.object(r, 'ROOT', root), patch.object(r, 'project_settings'), \
                 patch.object(r, 'command', return_value=b'fixture'), patch.object(r, 'logged', side_effect=build_failed):
                with self.assertRaisesRegex(ValueError, 'No Accounts'):
                    r.execute(argparse.Namespace(action='run', dry_run=False), run)
            self.assertEqual(r.read(run / 'state.json')['stage'], 'archived')
            self.assertEqual((run / 'Runner.xcarchive/record').read_bytes(), b'archive')
            with patch.object(r, 'ROOT', root), patch.object(r, 'project_settings'), \
                 patch.object(r, 'command', return_value=b'fixture'), patch.object(r, 'signed_app'), \
                 patch.object(r, 'validate_artifacts', return_value={'sha256': 'new'}), \
                 patch.object(r, 'logged') as logged:
                r.execute(argparse.Namespace(action='run', dry_run=False), run)
                args = logged.call_args.args[0]
                self.assertEqual(args[0], 'xcodebuild')
                self.assertIn(run / 'Runner.xcarchive', args)
            self.assertEqual(r.read(run / 'state.json')['stage'], 'exported')

    def test_changed_ipa_blocks_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            r.write(run / 'state.json', dict(self.s, stage='exported', artifact={'sha256': 'original'}))
            r.write(run / 'preflight.json', self.o)
            with patch.object(r, 'validate_artifacts', return_value={'sha256': 'changed'}):
                with self.assertRaisesRegex(ValueError, 'IPA changed'):
                    r.execute(argparse.Namespace(action='upload'), run)
            self.assertEqual(r.read(run / 'state.json')['stage'], 'exported')

    def test_cli_upload_pins_policy_and_never_claims_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            s = dict(self.s, stage='exported', artifact={'sha256': 'exact-ipa'})
            r.write(run / 'state.json', s)
            r.write(run / 'preflight.json', self.o)
            def upload(args, observed_run, label):
                # Barrier must exist before the network-capable command starts.
                self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
                self.assertEqual(label, 'upload')
                self.assertEqual(args[0], 'xcodebuild')
                self.assertIn(run / 'Runner.xcarchive', args)
                self.assertIn('-allowProvisioningUpdates', args)
                options = r.plistlib.loads((run / 'UploadOptions.plist').read_bytes())
                self.assertEqual(options['destination'], 'upload')
                self.assertEqual(options['teamID'], r.TEAM)
                self.assertIs(options['testFlightInternalTestingOnly'], True)
                self.assertIs(options['manageAppVersionAndBuildNumber'], False)
            with patch.object(r, 'validate_artifacts', return_value=s['artifact']), \
                 patch.object(r, 'logged', side_effect=upload) as logged:
                r.execute(argparse.Namespace(action='upload', via='cli'), run)
                logged.assert_called_once()
            result = r.read(run / 'state.json')
            self.assertEqual(result['stage'], 'upload_pending')
            self.assertIn('cli_upload_command_completed_at', result)
            self.assertNotIn('apple_readback', result)

    def test_failed_cli_upload_is_uncertain_and_cannot_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            s = dict(self.s, stage='exported', artifact={'sha256': 'exact-ipa'})
            r.write(run / 'state.json', s)
            r.write(run / 'preflight.json', self.o)
            def failed(args, stdout, stderr):
                self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
                stdout.write(b'No Accounts')
                return subprocess.CompletedProcess(args, 1)
            with patch.object(r, 'validate_artifacts', return_value=s['artifact']), \
                 patch.object(r.subprocess, 'run', side_effect=failed) as command:
                with self.assertRaisesRegex(ValueError, 'Upload outcome uncertain'):
                    r.execute(argparse.Namespace(action='upload', via='cli'), run)
                with self.assertRaisesRegex(ValueError, 'pending or performed'):
                    r.execute(argparse.Namespace(action='upload', via='cli'), run)
                command.assert_called_once()
            self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
            self.assertNotIn('cli_upload_command_completed_at', r.read(run / 'state.json'))

    def test_second_run_cannot_retry_uncertain_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            private = Path(tmp)
            other = private / 'other'
            other.mkdir()
            r.write(other / 'state.json', dict(self.s, stage='upload_pending'))
            with patch.object(r, 'PRIVATE', private):
                with self.assertRaisesRegex(ValueError, 'Another run'):
                    r.no_other_delivery(private / 'new', self.s)
                r.no_other_delivery(other, self.s)
                r.no_other_delivery(private / 'new', dict(self.s, build=10))

    def test_successful_helper_ipa_is_reused_without_second_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = root / 'run'
            run.mkdir()
            r.write(run / 'state.json', self.s)
            r.write(run / 'preflight.json', self.o)
            def build(args, observed_run, label):
                self.assertEqual(args, [root / 'build_ios_testflight.sh', '--build-name=0.1.7', '--build-number=9'])
                archive = root / 'app/build/ios/archive/Runner.xcarchive'
                archive.mkdir(parents=True)
                ipa_dir = root / 'app/build/ios/ipa'
                ipa_dir.mkdir()
                (ipa_dir / 'fresh.ipa').write_bytes(b'new signed fixture')
                future = time.time_ns() + 1000000
                os.utime(archive, ns=(future, future))
            with patch.object(r, 'ROOT', root), patch.object(r, 'project_settings'), \
                 patch.object(r, 'command', return_value=b'fixture'), patch.object(r, 'logged', side_effect=build) as logged, \
                 patch.object(r, 'validate_artifacts', return_value={'sha256': 'fresh'}):
                r.execute(argparse.Namespace(action='run', dry_run=False), run)
                logged.assert_called_once()
            self.assertEqual((run / 'export/fresh.ipa').read_bytes(), b'new signed fixture')
            self.assertEqual(r.read(run / 'state.json')['stage'], 'exported')

    def external_fixtures(self):
        state = dict(self.s, audience='external', group='WMAPP Public')
        observation = dict(self.o, group='WMAPP Public', internal=False, external_group_id='group-id',
                           private_group={'group': r.GROUP, 'internal': True, 'tester_count': 1,
                                          'sole_tester_is_owner': True, 'settings_unchanged': True})
        build = dict(self.b, **{key: observation[key] for key in
                              ('group', 'internal', 'external_group_id', 'private_group')},
                     internal_only=False, beta_review_status='approved', review_submission_id='review-id',
                     test_metadata_complete=True, build_testing_status='Testing', public_link=True,
                     invitation_access='Open to Anyone', tester_criteria=[], custom_tester_limit=None,
                     public_link_url='https://testflight.apple.com/join/Example1', public_landing_accepting=True)
        return state, observation, build

    def test_external_init_requires_distinct_group_and_keeps_private_default(self):
        for mode, group in [('external', None), ('external', r.GROUP), ('external', '  '),
                            ('internal', 'WMAPP Public')]:
            with tempfile.TemporaryDirectory() as tmp:
                run = Path(tmp) / 'run'
                with self.subTest(mode=mode, group=group), self.assertRaises(ValueError):
                    r.execute(argparse.Namespace(action='init', version='0.1.7', build=9,
                                                 audience=mode, group=group), run)
                self.assertFalse(run.exists())
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp) / 'run'
            r.execute(argparse.Namespace(action='init', version='0.1.7', build=9), run)
            self.assertEqual(r.read(run / 'state.json')['audience'], 'internal')
            self.assertEqual(r.read(run / 'preflight.json')['group'], r.GROUP)
            external = Path(tmp) / 'external'
            r.execute(argparse.Namespace(action='init', version='0.1.7', build=9,
                                         audience='external', group='WMAPP Public'), external)
            self.assertEqual(r.read(external / 'state.json')['audience'], 'external')
            self.assertNotIn('tester_count', r.read(external / 'preflight.json'))

    def test_external_preflight_preserves_private_and_requires_new_version(self):
        state, observation, _ = self.external_fixtures()
        r.preflight(observation, state)
        for changes in [dict(group=r.GROUP), dict(internal=True), dict(public_link=True),
                        dict(other_distribution_groups=['Unexpected']), dict(latest_version='0.1.7')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                r.preflight(dict(observation, **changes), state)
        for changes in [dict(tester_count=2), dict(sole_tester_is_owner=False),
                        dict(settings_unchanged=False), dict(group='Wrong')]:
            with self.subTest(private_changes=changes), self.assertRaises(ValueError):
                r.preflight(dict(observation, private_group=dict(observation['private_group'], **changes)), state)

    def test_external_export_policy_is_separate_and_fails_closed(self):
        self.assertEqual(r.plistlib.loads(r.options().read_bytes())['teamID'], r.TEAM)
        self.assertEqual(r.plistlib.loads(r.options('external').read_bytes())['teamID'], r.TEAM)
        internal = r.plistlib.loads(r.OPTIONS.read_bytes())
        external = r.plistlib.loads(r.EXTERNAL_OPTIONS.read_bytes())
        self.assertIs(internal['testFlightInternalTestingOnly'], True)
        self.assertIs(external['testFlightInternalTestingOnly'], False)
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / 'bad.plist'
            bad.write_bytes(r.plistlib.dumps(internal))
            with patch.object(r, 'EXTERNAL_OPTIONS', bad), self.assertRaisesRegex(ValueError, 'Unsafe'):
                r.options('external')
        with self.assertRaises(ValueError):
            r.options('unknown')

    def test_external_readback_distinguishes_each_milestone(self):
        state, _, build = self.external_fixtures()
        for changes, stage in [
            (dict(processing='processing', public_link=False), 'uploaded_processing'),
            (dict(encryption_compliance='pending', public_link=False), 'uploaded_action_required'),
            (dict(beta_review_status='not_submitted', public_link=False), 'processed_awaiting_review'),
            (dict(beta_review_status='waiting_for_review', public_link=False), 'beta_review_pending'),
            (dict(beta_review_status='in_review', public_link=False), 'beta_review_pending'),
            (dict(beta_review_status='rejected', public_link=False), 'beta_review_action_required'),
            (dict(public_link=False), 'approved_awaiting_public_link'),
            (dict(build_testing_status='Ready to Test'), 'approved_awaiting_public_link'),
            (dict(public_landing_accepting=False), 'approved_awaiting_public_link'),
            ({}, 'ready_for_external_testing'),
        ]:
            with self.subTest(changes=changes):
                self.assertEqual(r.readback(dict(build, **changes), state), stage)

    def test_external_readiness_rejects_internal_build_and_invalid_access(self):
        state, _, build = self.external_fixtures()
        for changes in [dict(internal_only=True), dict(assigned_to_group=False),
                        dict(external_group_id=None), dict(receipt_or_build_id=None),
                        dict(review_submission_id=None), dict(test_metadata_complete=False),
                        dict(beta_review_status='unknown'), dict(invitation_access='Filter by Criteria'),
                        dict(tester_criteria=['iPhone']), dict(custom_tester_limit=10),
                        dict(public_link_url='https://example.com/join/Example1'),
                        dict(build=8), dict(group='Wrong')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                r.readback(dict(build, **changes), state)
        with self.assertRaisesRegex(ValueError, 'before approval'):
            r.readback(dict(build, beta_review_status='waiting_for_review'), state)
        with self.assertRaisesRegex(ValueError, 'group ID changed'):
            r.readback(build, dict(state, external_group_id='different-id'))

    def test_external_cli_upload_uses_external_policy_and_pending_barrier(self):
        state, observation, _ = self.external_fixtures()
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            state.update(stage='exported', artifact={'sha256': 'exact-external-ipa'})
            r.write(run / 'state.json', state)
            r.write(run / 'preflight.json', observation)
            def upload(args, observed_run, label):
                self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
                policy = r.plistlib.loads((run / 'UploadOptions.plist').read_bytes())
                self.assertIs(policy['testFlightInternalTestingOnly'], False)
                self.assertEqual(policy['destination'], 'upload')
                self.assertEqual(policy['teamID'], r.TEAM)
                self.assertIs(policy['manageAppVersionAndBuildNumber'], False)
            with patch.object(r, 'validate_artifacts', return_value=state['artifact']), \
                 patch.object(r, 'logged', side_effect=upload):
                r.execute(argparse.Namespace(action='upload', via='cli'), run)
            self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
            self.assertIsNone(r.read(run / 'readback.json')['beta_review_status'])
            with self.assertRaisesRegex(ValueError, 'pending or performed'):
                r.execute(argparse.Namespace(action='upload', via='cli'), run)

    def test_external_build_passes_explicit_flag_and_keeps_artifact_hashes(self):
        state, observation, _ = self.external_fixtures()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = root / 'run'
            run.mkdir()
            r.write(run / 'state.json', state)
            r.write(run / 'preflight.json', observation)
            def build(args, observed_run, label):
                self.assertIn('--external', args)
                archive = root / 'app/build/ios/archive/Runner.xcarchive'
                archive.mkdir(parents=True)
                (archive / 'record').write_bytes(b'external archive')
                ipa_dir = root / 'app/build/ios/ipa'
                ipa_dir.mkdir()
                (ipa_dir / 'external.ipa').write_bytes(b'external signed fixture')
                future = time.time_ns() + 1000000
                os.utime(archive, ns=(future, future))
            with patch.object(r, 'ROOT', root), patch.object(r, 'project_settings'), \
                 patch.object(r, 'command', return_value=b'fixture'), \
                 patch.object(r, 'logged', side_effect=build), \
                 patch.object(r, 'validate_artifacts', return_value={'sha256': 'external'}):
                r.execute(argparse.Namespace(action='run', dry_run=False), run)
            result = r.read(run / 'state.json')
            self.assertEqual(result['stage'], 'exported')
            self.assertEqual(result['external_group_id'], 'group-id')
            self.assertEqual(result['export_policy_sha256'], r.digest(r.options('external')))
            self.assertEqual(result['archive_hashes'], r.tree_hash(run / 'Runner.xcarchive'))
            self.assertIn('source_commit', result)

    def test_external_readback_pins_group_and_status_hides_pending_link(self):
        state, _, build = self.external_fixtures()
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            r.write(run / 'state.json', dict(state, stage='upload_pending'))
            r.write(run / 'readback.json', dict(build, public_landing_accepting=False))
            r.execute(argparse.Namespace(action='readback'), run)
            result = r.read(run / 'state.json')
            self.assertEqual(result['stage'], 'approved_awaiting_public_link')
            self.assertEqual(result['external_group_id'], 'group-id')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                r.execute(argparse.Namespace(action='status'), run)
            self.assertNotIn(build['public_link_url'], output.getvalue())
            r.write(run / 'readback.json', build)
            r.execute(argparse.Namespace(action='readback'), run)
            self.assertEqual(r.read(run / 'state.json')['stage'], 'ready_for_external_testing')

    def test_changed_policy_blocks_artifact_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'Export policy changed'):
                r.validate_artifacts(Path(tmp), dict(self.s, export_policy_sha256='wrong'))

    def test_shell_helper_preserves_default_and_selects_external_export(self):
        # Execute the real argument handling with stubbed build tools; no signing/network.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helper = root / 'build_ios_testflight.sh'
            helper.write_bytes((r.ROOT / helper.name).read_bytes())
            (root / 'tools/ios').mkdir(parents=True)
            (root / 'app').mkdir()
            for file in ('tools/ios/build_core.sh', 'tools/update_flightdeck_bundle.sh'):
                path = root / file
                path.write_text('#!/bin/bash\nexit 0\n')
                path.chmod(0o700)
            for name in ('configure_apple_signing.py', 'testflight_release.py'):
                (root / 'tools/ios' / name).write_bytes((r.ROOT / 'tools/ios' / name).read_bytes())
            (root / 'docs/deploy').mkdir(parents=True)
            for template in (r.OPTIONS, r.EXTERNAL_OPTIONS):
                (root / 'docs/deploy' / template.name).write_bytes(template.read_bytes())
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'uname').write_text('#!/bin/bash\necho Darwin\n')
            flutter = bin_dir / 'flutter'
            flutter.write_text('#!' + r.sys.executable + '\nimport json, pathlib, sys\n'
                               'pathlib.Path("args.json").write_text(json.dumps(sys.argv[1:]))\n'
                               'pathlib.Path("build/ios/ipa").mkdir(parents=True, exist_ok=True)\n'
                               'pathlib.Path("build/ios/ipa/fixture.ipa").write_bytes(b"fixture")\n')
            for path in bin_dir.iterdir():
                path.chmod(0o700)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
            for args, expected in [([], 'TestFlightExportOptions.plist'),
                                   (['--external'], 'TestFlightExternalExportOptions.plist'),
                                   (['--build-name=0.1.7', '--build-number=9', '--external'],
                                    'TestFlightExternalExportOptions.plist')]:
                with self.subTest(args=args):
                    result = subprocess.run(['/bin/bash', str(helper), *args], env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    forwarded = r.read(root / 'app/args.json')
                    self.assertIn('--export-options-plist=' + str(root.resolve() / 'tmp/docs/handoffs/apple-signing' / ('external-ExportOptions.plist' if '--external' in args else 'internal-ExportOptions.plist')), forwarded)
                    self.assertNotIn('--external', forwarded)
                    for arg in args:
                        if arg.startswith('--build-'):
                            self.assertIn(arg, forwarded)
            result = subprocess.run(['/bin/bash', str(helper), '--publish'], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_repository_options_and_settings(self):
        r.options()
        r.project_settings()


if __name__ == '__main__':
    unittest.main()

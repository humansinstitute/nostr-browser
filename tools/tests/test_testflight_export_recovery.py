"""Recovery must prove exact export ownership; empty Apple files alone are insufficient."""
import copy
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ios'))
import testflight_export_recovery as recovery
import testflight_release as r
import nightly_testflight as nightly
import testflight_api_release as api
from appstore_connect import APP, BUNDLE

ID = '11111111-2222-3333-4444-555555555555'


class RecoveryTests(unittest.TestCase):
    source = {'nbrowser': 'a' * 40, 'flightdeck': 'b' * 40}
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name).resolve(); self.logs = self.run / 'export.xcdistributionlogs'; self.logs.mkdir()
        self.ipa = self.run / 'retained.ipa'
        with zipfile.ZipFile(self.ipa, 'w') as z:
            z.writestr('Payload/Runner.app/Info.plist', plistlib.dumps({'TFInternalTestingOnly': True,
                'CFBundleIdentifier': BUNDLE, 'CFBundleVersion': '11', 'CFBundleShortVersionString': '0.1.7'}))
        self.s = {'api': True, 'app_id': APP, 'stage': 'exported', 'version': '0.1.7', 'build': 11,
                  'export_started_ns': 1704067199 * 10**9,
                  'artifact': {'ipa': str(self.ipa), 'sha256': r.digest(self.ipa)}}
        r.write(self.run / 'api-preflight.json', {'history_complete': True, 'pending_upload_ids': [], 'pending_build_ids': [], 'uploads': [], 'builds': []})
        (self.run / 'export.log').write_text('Created bundle at path "/native/export.xcdistributionlogs"\n** EXPORT SUCCEEDED **')
        p = {'destination': 'export', 'method': 'app-store-connect', 'teamID': r.TEAM,
             'testFlightInternalTestingOnly': True, 'manageAppVersionAndBuildNumber': False}
        (self.logs / 'IDEDistribution.standard.log').write_text('Starting export with options: ' + json.dumps(p))
        req = {'data': {'type': 'builds', 'attributes': {'cfBundleVersion': '11',
            'cfBundleShortVersionString': '0.1.7', 'platform': 'IOS'},
            'relationships': {'app': {'data': {'id': APP, 'type': 'apps'}}}}}
        res = {'data': {'type': 'builds', 'id': ID, 'attributes': {'version': '11', 'uploadedDate': None}}}
        (self.logs / 'ContentDelivery.log').write_text('CREATE BUILD (ASSET_UPLOAD) REQUEST:\nhttpBody: ' + json.dumps(req) +
            '\nCREATE BUILD (ASSET_UPLOAD) RESPONSE:\nstatus code: 201 (created)\nhttpBody: ' + json.dumps(res) + '\nReceived build ID: ' + ID)
        for p in self.run.rglob('*'):
            if p.is_file(): p.chmod(0o600)
        self.client = Mock(); self.client.all.return_value = []
        self.h = {'pending_upload_ids': [ID], 'pending_build_ids': [], 'builds': [],
                  'versions': [{'attributes': {'platform': 'IOS', 'version': '0.1.7'}}],
                  'uploads': [{'id': ID, 'attributes': {'platform': 'IOS', 'cfBundleVersion': '11',
                    'cfBundleShortVersionString': '0.1.7', 'createdDate': '2024-01-01T00:00:00Z',
                    'uploadedDate': None, 'state': {'state': 'AWAITING_UPLOAD', 'errors': [], 'warnings': [], 'infos': []}}}]}

    def proof(self):
        with patch.object(nightly, 'safe_private'), patch.object(r, 'validate_artifacts', return_value=self.s['artifact']):
            return recovery.export_proof(r, self.run, self.s, self.logs)

    def test_exact_export_reservation_passes_without_removing_other_history(self):
        proof = self.proof(); before = copy.deepcopy(self.h)
        self.assertEqual(recovery.recovery_history(r, self.client, self.h, self.s, proof)['id'], ID)
        self.assertEqual(self.h, before)
        self.client.all.assert_called_once_with(f'/v1/buildUploads/{ID}/buildUploadFiles?limit=200')

    def test_unrelated_processing_files_or_uploaded_date_block(self):
        proof = self.proof()
        for mutate in [lambda h: h['pending_upload_ids'].append('unrelated'),
                       lambda h: h['pending_build_ids'].append('processing'),
                       lambda h: h['uploads'][0]['attributes'].update(uploadedDate='2024-01-01'),
                       lambda h: h['uploads'][0]['attributes'].update(cfBundleVersion='12'),
                       lambda h: h['uploads'][0]['attributes'].update(createdDate='2023-01-01T00:00:00Z'),
                       lambda h: h['builds'].append({'attributes': {'version': '11'}}),
                       lambda h: h['uploads'].append({'id': 'higher', 'attributes': {'cfBundleVersion': '12', 'cfBundleShortVersionString': '0.1.7'}})]:
            h = copy.deepcopy(self.h); mutate(h)
            with self.assertRaises(ValueError): recovery.recovery_history(r, self.client, h, self.s, proof)
        self.client.all.return_value = [{'id': 'file'}]
        with self.assertRaises(ValueError): recovery.recovery_history(r, self.client, self.h, self.s, proof)

    def test_uncertain_local_intent_blocks_even_with_empty_apple_files(self):
        for name in ('upload.log', 'upload-123.log', 'UploadOptions.plist', 'upload-output'):
            p = self.run / name; p.touch()
            with self.assertRaises(ValueError): self.proof()
            p.unlink()
        self.s['stage'] = 'upload_pending'
        with self.assertRaises(ValueError): self.proof()

    def test_native_mismatch_or_subsequent_activity_blocks(self):
        p = self.logs / 'ContentDelivery.log'; original = p.read_text()
        for value in (original.replace(APP, 'wrong'), original.replace('201 (created)', '200 (ok)'),
                      original + '\nUPLOAD FILE REQUEST:', original.replace('"11"', '"12"')):
            p.write_text(value)
            with self.assertRaises(ValueError): self.proof()
        p.write_text(original)
        (self.run / 'export.log').write_text('Created bundle at path "/other.xcdistributionlogs"\n** EXPORT SUCCEEDED **')
        with self.assertRaises(ValueError): self.proof()

    def test_claim_recovery_preserves_failed_history_and_refuses_active_or_wrong_owner(self):
        day = dt.datetime.now(nightly.ZoneInfo('Australia/Perth')).date().isoformat()
        d = self.run / 'claim'; nightly.transition(d, 'claim', 'prior', day, source=self.source)
        with self.assertRaises(ValueError): nightly.recover_claim(d, 'new', 'prior', 'run', 'a'*64)
        nightly.transition(d, 'finish', 'prior', day, 'failed')
        before = json.loads((d / 'ledger.json').read_text())['days'][day]['attempts'][0]
        with self.assertRaises(ValueError): nightly.recover_claim(d, 'new', 'wrong', 'run', 'a'*64)
        got = nightly.recover_claim(d, 'new', 'prior', 'run', 'a'*64)
        self.assertEqual(got['prior_claim'], before); self.assertEqual(got['recovery_run'], 'run')
        with self.assertRaises(ValueError): nightly.recover_claim(d, 'third', 'new', 'run', 'a'*64)
        with patch.object(nightly, 'PRIVATE', d), patch.object(nightly, 'safe_private'), patch.dict(os.environ, {'SESSION_ID':'new'}):
            api.require_daily_claim(Path('/run'), 'api-upload')
            for action, run in [('api-reserve', Path('/run')), ('api-build', Path('/run')), ('api-upload', Path('/other'))]:
                with self.assertRaises(ValueError): api.require_daily_claim(run, action)

    def test_live_worker_cannot_be_reconciled_as_stopped(self):
        with patch.object(recovery.subprocess, 'run', return_value=Mock(stdout=json.dumps({'session': {'id':'prior'}}))):
            with self.assertRaises(ValueError): recovery.stopped_session('prior')

    def test_current_owner_recovery_reuses_active_claim_without_transfer(self):
        from types import SimpleNamespace
        self.client.preflight.return_value = self.h
        args = SimpleNamespace(export_logs=self.logs, previous_owner=None)
        with patch.object(nightly, 'safe_private'), \
                patch.object(recovery, 'export_proof', return_value={'upload_id': ID}), \
                patch.object(recovery, 'recovery_history', return_value={'id': ID}), \
                patch.object(api, 'delivery_barrier'), patch.object(r, 'no_other_delivery'), \
                patch.object(api, 'require_daily_claim') as claim, \
                patch.object(nightly, 'recover_claim') as transfer:
            r.write(self.run / 'state.json', self.s)
            recovery.recover(r, self.client, self.run, self.s, args)
        claim.assert_called_once_with(self.run, 'api-upload')
        transfer.assert_not_called()
        self.assertEqual(r.read(self.run / 'export-recovery.json')['claim_mode'],
                         'current_active_claim')

    def test_recovery_upload_pins_proof_and_retained_ipa(self):
        proof = self.proof(); proof.update(schema=1, app_id=APP, basis='same_run_native_export_reservation',
            run=self.run.name, reservation=recovery.recovery_history(r, self.client, self.h, self.s, proof))
        r.write(self.run / 'state.json', self.s); proof['state_sha256'] = r.digest(self.run / 'state.json')
        r.write(self.run / 'export-recovery.json', proof); self.client.altool_args.return_value = ['--p8-file-path','private']
        with patch.object(nightly,'safe_private'), patch.object(r,'validate_artifacts',return_value=self.s['artifact']):
            cmd = recovery.upload_gate(r, self.client, self.run, self.s, self.h)
            self.assertEqual(cmd[:4], ['xcrun','altool','--upload-package',str(self.ipa)])
            (self.logs / 'ContentDelivery.log').write_text((self.logs / 'ContentDelivery.log').read_text() + '\n')
            with self.assertRaises(ValueError): recovery.upload_gate(r, self.client, self.run, self.s, self.h)

    def test_recovered_delivery_persists_intent_and_never_retries_uncertainty(self):
        proof = self.proof(); proof.update(schema=1, app_id=APP, basis='same_run_native_export_reservation',
            run=self.run.name, reservation=recovery.recovery_history(r, self.client, self.h, self.s, proof))
        r.write(self.run / 'state.json', self.s); proof['state_sha256'] = r.digest(self.run / 'state.json')
        r.write(self.run / 'export-recovery.json', proof)
        self.client.preflight.return_value = self.h; self.client.altool_args.return_value = []
        def uncertain(args, run, label):
            self.assertEqual(r.read(run / 'state.json')['stage'], 'upload_pending')
            self.assertEqual(args[:4], ['xcrun', 'altool', '--upload-package', str(self.ipa)])
            raise ValueError('uncertain')
        from types import SimpleNamespace
        a = SimpleNamespace(action='api-upload', auth_reference='unused')
        with patch.object(api, 'Client', return_value=self.client), patch.object(api, 'require_daily_claim'), patch.object(nightly, 'safe_private'), patch.object(api, 'delivery_barrier'), patch.object(r, 'no_other_delivery'), patch.object(r, 'project_settings'), patch.object(r, 'validate_artifacts', return_value=self.s['artifact']), patch.object(r, 'logged', side_effect=uncertain) as upload:
            with self.assertRaises(ValueError): api.execute(r, a, self.run)
            with self.assertRaises(ValueError): api.execute(r, a, self.run)
            upload.assert_called_once()

    def test_preexisting_empty_reservation_is_not_same_run_proof(self):
        before = r.read(self.run / 'api-preflight.json'); before['uploads'] = self.h['uploads']
        r.write(self.run / 'api-preflight.json', before)
        with self.assertRaises(ValueError): self.proof()

    def test_native_logs_are_preserved_byte_for_byte_with_timestamps(self):
        source=self.run/'native'/'export.xcdistributionlogs';source.parent.mkdir()
        import shutil
        shutil.copytree(self.logs,source,copy_function=shutil.copy2)
        (self.run/'export.log').write_text('Created bundle at path "'+str(source)+'"\n** EXPORT SUCCEEDED **')
        before={p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in source.iterdir()}
        with patch.object(nightly,'safe_private'):
            retained=recovery.retain_export_logs(r,self.run)
            self.assertEqual({p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in retained.iterdir()},before)
            self.assertEqual(recovery.retain_export_logs(r,self.run),retained)
            (retained/'ContentDelivery.log').write_text('changed')
            with self.assertRaises(ValueError):recovery.retain_export_logs(r,self.run)

    def test_automatic_recovery_requires_exact_native_proof_not_merely_empty_files(self):
        from types import SimpleNamespace
        retained=self.run/'native-export'/self.logs.name;retained.parent.mkdir()
        import shutil
        shutil.copytree(self.logs,retained,copy_function=shutil.copy2)
        r.write(self.run/'state.json',self.s)
        self.client.preflight=Mock(return_value=self.h)
        with patch.object(nightly,'safe_private'),patch.object(api,'require_daily_claim'),patch.object(api,'delivery_barrier'),patch.object(r,'no_other_delivery'),patch.object(r,'validate_artifacts',return_value=self.s['artifact']):
            recovery.automatic_recovery(r,self.client,self.run,self.s,self.h)
            self.assertEqual(r.read(self.run/'export-recovery.json')['upload_id'],ID)
            self.assertEqual(r.read(self.run/'state.json')['stage'],'exported')
            self.client.request.assert_not_called()
        (self.run/'export-recovery.json').unlink()
        (retained/'ContentDelivery.log').write_text('empty reservation with no ownership proof')
        with patch.object(nightly,'safe_private'),patch.object(api,'require_daily_claim'),patch.object(r,'validate_artifacts',return_value=self.s['artifact']):
            with self.assertRaises(ValueError):recovery.automatic_recovery(r,self.client,self.run,self.s,self.h)
        self.assertFalse((self.run/'export-recovery.json').exists())

    def test_completed_altool_delivery_reconciles_only_exact_proved_native_reservation(self):
        import hashlib, copy
        original=copy.deepcopy(self.s)
        proof=self.proof()
        proof.update(schema=1,app_id=APP,basis='same_run_native_export_reservation',run=self.run.name,
                     reservation=dict(id=ID,version='0.1.7',build=11,created_at='2024-01-01T00:00:00Z'),
                     state_sha256=hashlib.sha256((json.dumps(original,indent=2)+'\n').encode()).hexdigest())
        r.write(self.run/'export-recovery.json',proof)
        state=dict(original,stage='api_testing',upload_command_completed_at='now',api_readback={'build_id':'delivered-id'})
        r.write(self.run/'state.json',state)
        self.client.audience=Mock(return_value={'group_id':'private'})
        self.client.all=Mock(return_value=[])
        builds=[dict(build=11,version='0.1.7',processing='VALID',id='delivered-id')]
        with patch.object(r,'PRIVATE',self.run.parent),patch.object(nightly,'safe_private'),patch.object(r,'validate_artifacts',return_value=self.s['artifact']):
            self.assertTrue(recovery.completed_reservation(self.client,self.h['uploads'][0],builds))
            with self.assertRaises(ValueError):recovery.completed_reservation(self.client,self.h['uploads'][0],[])
            self.client.all.return_value=[{'id':'unexplained-upload-file'}]
            with self.assertRaises(ValueError):recovery.completed_reservation(self.client,self.h['uploads'][0],builds)
        self.assertEqual(r.read(self.run/'state.json'),state)

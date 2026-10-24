import importlib.util
from pathlib import Path
import unittest
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
spec=importlib.util.spec_from_file_location('nightly',Path(__file__).resolve().parents[1]/'nightly_zapstore.py')
n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
class NightlyTests(unittest.TestCase):
    def test_monotonic_over_local_and_remote(self):
        ledger={'schema':1,'runs':{'yesterday':{'stage':'published','version_code':2000000001}}}
        self.assertEqual(n.reserve(ledger,'today','session',2000000005,'2.3.4')['version_code'],2000000006)
    def test_source_marketing_version_is_not_hardcoded(self):
        s=n.reserve({'schema':1,'runs':{}},'2026-10-06','session',0,'2.3.4')
        self.assertTrue(s['version_name'].startswith('2.3.4-nightly.20261006.'))
        with self.assertRaises(ValueError):n.reserve({'schema':1,'runs':{}},'today','session',0,'invalid')
    def test_duplicate_and_uncertain_delivery_block(self):
        ledger={'schema':1,'runs':{}}
        n.reserve(ledger,'today','session',0,'2.3.4')
        with self.assertRaisesRegex(ValueError,'already'):n.reserve(ledger,'today','session',0,'2.3.4')
        for stage in ('reserved','building','built','prepared','prepared_public','public_assets_pending','delivery_pending','listing_update_pending'):
            ledger['runs']['today']['stage']=stage
            with self.assertRaisesRegex(ValueError,'uncertain'):n.reserve(ledger,'tomorrow','other',0,'2.3.4')
    def test_invalid_history_and_owner_fail_closed(self):
        for maximum in (-1,False,1.2,None):
            with self.assertRaises(ValueError):n.reserve({'schema':1,'runs':{}},'today','session',maximum,'2.3.4')
        with self.assertRaises(ValueError):n.reserve({'schema':1,'runs':{}},'today',None,0,'2.3.4')
    def test_version_limit(self):
        with self.assertRaises(ValueError):n.reserve({'schema':1,'runs':{}},'today','session',2100000000,'2.3.4')
    def test_same_owner_resume_refuses_signing_or_delivery(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            run=Path(temp);s={'owner':'same','stage':'building'}
            n.require_resume(s,'same',run)
            with self.assertRaises(ValueError):n.require_resume(s,'other',run)
            for stage in ('built','prepared','prepared_public','delivery_pending','published'):
                with self.assertRaises(ValueError):n.require_resume({**s,'stage':stage},'same',run)
            (run/'proof-signed.json').write_text('{}')
            with self.assertRaises(ValueError):n.require_resume(s,'same',run)
    def test_functional_failure_blocks_today_but_not_next_night_or_other_lane(self):
        import tempfile, json, os, contextlib
        from types import SimpleNamespace
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); private=root/'private'; private.mkdir()
            ledger=private/'ledger.json'; ledger.write_text('{"schema":1,"runs":{}}')
            # A lingering Apple claim must not affect Android's own build.
            apple=root/'tmp/docs/handoffs/nightly-testflight'; apple.mkdir(parents=True)
            (apple/'ledger.json').write_text('{"schema":2,"days":{"today":{"attempts":[{"status":"active"}]}}}')
            day=n.dt.datetime.now(n.ZoneInfo('Australia/Perth')).date().isoformat()
            def command(args, cwd=None, env=None):
                if 'history' in args: return '{"maxVersionCode":0}'
                if 'show' in args: return 'version: 0.1.7+1'
                if 'status' in args: return ''
                return 'a'*40
            def snapshot(repo,target,commit=None):
                target.mkdir()
                (target/'.build-meta.json').write_text('{"absoluteVersion":1}')
                (target/'release-notes.json').write_text('{"releases":[]}')
                return 'a'*40
            def run(args, **kw):
                return SimpleNamespace(returncode=1 if args==['bun','run','test:release'] else 0)
            with patch.object(n,'ROOT',root), patch.object(n,'PRIVATE',private), patch.object(n,'safe_private'), patch.object(n,'private_key_reference'), patch.object(n,'command',side_effect=command), patch.object(n,'snapshot',side_effect=snapshot), patch.object(n.subprocess,'run',side_effect=run), patch.object(n,'source_lock',return_value=contextlib.nullcontext()), patch.dict(os.environ,SESSION_ID='android-worker',FLIGHT_DECK_PG_APP_NPUB='verified'), patch.object(sys,'argv',['nightly','build','--flightdeck',str(root)]):
                with self.assertRaisesRegex(ValueError,'failed'): n.main()
            retained=json.loads(ledger.read_text())
            self.assertEqual(retained['runs'][day]['stage'],'failed_before_delivery')
            self.assertEqual(retained['runs'][day]['failure_log'],'fd-test-release.log')
            self.assertEqual(n.reserve(retained,'next-night','next-worker',0,'0.1.7')['stage'],'reserved')
            self.assertIn('active',(apple/'ledger.json').read_text())
    def test_snapshot_has_real_source_index_and_preserves_shared_state(self):
        import tempfile,subprocess
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            repo=Path(temp)/'source';repo.mkdir()
            def git(*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
            git('init','-b','main');git('config','user.name','Test');git('config','user.email','test@example.invalid')
            (repo/'source.txt').write_text('committed source');git('add','source.txt');git('commit','-m','test: source')
            (repo/'unfinished.txt').write_text('concurrent edit')
            before=git('status','--porcelain')
            with patch.object(n,'safe_private',lambda p:None):commit=n.snapshot(repo,Path(temp)/'snapshot')
            self.assertEqual(git('status','--porcelain'),before)
            self.assertEqual(n.command(['git','ls-files'],Path(temp)/'snapshot'),'source.txt')
            self.assertEqual(n.command(['git','rev-parse','HEAD'],Path(temp)/'snapshot'),commit)
            self.assertFalse((Path(temp)/'snapshot/unfinished.txt').exists())
    def test_package_isolation_and_provider_scope(self):
        root=Path(__file__).resolve().parents[2]
        gradle=(root/'app/android/app/build.gradle.kts').read_text()
        self.assertIn('if (nightly) "'+n.PACKAGE+'" else "com.wingmanbefree.wingman_app"',gradle)
        manifest=(root/'app/android/app/src/main/AndroidManifest.xml').read_text()
        self.assertIn('${applicationId}.drivefiles',manifest)
        self.assertIn('com.wingmanbefree.wingman_app.MainActivity',manifest)
    def test_archived_prebuild_reconciliation_never_clears_uncertain_publication(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            run=Path(temp);state=dict(owner='old',stage='building',version_code=12)
            history=dict(historyComplete=True,versionCodes=[11],maxVersionCode=11)
            archived=dict(id='old',archivedAt='verified')
            got=n.reconcile_build(state,run,history,archived)
            self.assertEqual(got['prior_state'],state)
            self.assertEqual(state['stage'],'building')
            for changed in [dict(state,stage='delivery_pending'),dict(state,stage='uploaded'),dict(state,public_release_url='https://example.invalid')]:
                with self.assertRaises(ValueError): n.reconcile_build(changed,run,history,archived)
            for bad in [dict(id='wrong',archivedAt='yes'),dict(id='old',archivedAt=None)]:
                with self.assertRaises(ValueError):n.reconcile_build(state,run,history,bad)
            (run/'signed.json').write_text('retained signed event')
            with self.assertRaises(ValueError):n.reconcile_build(state,run,history,archived)

    def test_missing_history_restore_requires_original_certificate_and_exact_failure_proof(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            record=Path(temp)/'task.json';record.write_text('Reviewed exact task: no APK signing or delivery')
            evidence=dict(schema=1,basis='reviewed_missing_android_ledger',package=n.PACKAGE,publisher='original',certificate_sha256=n.CERTIFICATE_SHA256,pre_build_failures=[dict(day='2026-10-21',version_code=12,owner='old',source_commit='a'*40,outcome='no_apk_signing_or_delivery',task_evidence_path=str(record),task_evidence_sha256=n.digest(record))])
            history=dict(publisher='original',historyComplete=True,versionCodes=[11],releases=[dict(versionCode=11,version='0.1.7-nightly.20261020.11',eventId='event',apkSha256='a'*64,certificateSha256=n.CERTIFICATE_SHA256)])
            with patch.object(n,'safe_private'):
                restored=n.restore_history(evidence,history)
                self.assertEqual(restored['runs']['2026-10-20']['stage'],'published')
                self.assertEqual(restored['runs']['2026-10-21']['stage'],'failed_before_delivery')
                with self.assertRaises(ValueError):n.restore_history(dict(evidence,certificate_sha256='wrong'),history)
                with self.assertRaises(ValueError):n.restore_history(evidence,dict(history,versionCodes=[11,12]))
                record.write_text('changed proof')
                with self.assertRaises(ValueError):n.restore_history(evidence,history)
if __name__=='__main__':unittest.main()

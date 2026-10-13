import importlib.util
from pathlib import Path
import unittest
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
    def test_scheduler_coordination_is_fail_closed(self):
        self.assertTrue(n.testflight_active({'schema':1,'days':{'today':{'status':'active'}}}))
        self.assertFalse(n.testflight_active({'schema':1,'days':{'today':{'status':'testing'}}}))
        with self.assertRaises(ValueError):n.testflight_active({'days':{}})
        with self.assertRaises(KeyError):n.testflight_active({'schema':1,'days':{'today':{}}})
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
if __name__=='__main__':unittest.main()

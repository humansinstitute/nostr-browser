import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_sources', Path(__file__).parents[1]/'release_sources.py')
n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)


class SourceTests(unittest.TestCase):
    def test_pinned_archive_survives_new_head_and_preserves_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)/'source'; repo.mkdir()
            def git(*args):
                return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
            git('init','-q','-b','main');git('config','user.name','Test');git('config','user.email','test@example.invalid')
            (repo/'code').write_text('selected');git('add','code');git('commit','-qm','test: first')
            first = git('rev-parse','HEAD')
            (repo/'code').write_text('newer');git('commit','-am','test: newer')
            (repo/'code').write_text('unfinished edit')
            before = git('status','--porcelain')
            target = Path(temp)/'snapshot'
            self.assertEqual(n.snapshot(repo,target,first),first)
            self.assertEqual((target/'code').read_text(),'selected')
            self.assertEqual(git('status','--porcelain'),before)
            self.assertEqual((repo/'code').read_text(),'unfinished edit')
            self.assertEqual(subprocess.check_output(['git','-C',str(target),'ls-files'],text=True).strip(),'code')

    def test_source_lock_releases_after_process_crash(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve(); subprocess.run(['git','init','-q',str(root)],check=True)
            (root/'.gitignore').write_text('tmp/\n')
            script = f"import sys,time;sys.path.insert(0,{str(Path(n.__file__).parent)!r});from release_sources import source_lock;from pathlib import Path\nwith source_lock(Path({str(root)!r})):\n print('locked',flush=True)\n time.sleep(20)"
            worker=subprocess.Popen(['python3','-c',script],stdout=subprocess.PIPE,text=True)
            try:
                self.assertEqual(worker.stdout.readline().strip(),'locked')
                with self.assertRaises(ValueError):
                    with n.source_lock(root,timeout=0): pass
            finally:
                worker.kill(); worker.wait(); worker.stdout.close()
            with n.source_lock(root,timeout=0): pass

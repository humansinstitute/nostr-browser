import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from register_flightdeck_assets import register


class AssetRegistrationTests(unittest.TestCase):
    def test_nested_files_are_declared_and_repeat_is_identical(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bundle = root/'app/assets/flightdeck'
            (bundle/'fonts/Example').mkdir(parents=True)
            (bundle/'legal').mkdir()
            for name in ('version.json','fonts/Example/font.woff2','legal/privacy.html'):
                (bundle/name).write_text('bytes')
            pubspec = root/'app/pubspec.yaml'
            pubspec.write_text('flutter:\n  assets:\n    - assets/other/\n    - assets/flightdeck/\n    - assets/flightdeck/assets/\n')
            register(root)
            first = pubspec.read_bytes()
            self.assertIn(b'    - assets/flightdeck/fonts/Example/\n', first)
            self.assertIn(b'    - assets/flightdeck/legal/\n', first)
            self.assertIn(b'    - assets/other/\n', first)
            register(root)
            self.assertEqual(first, pubspec.read_bytes())
            (bundle/'bad').symlink_to(bundle/'version.json')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                register(root)
            self.assertEqual(first, pubspec.read_bytes())

"""Local signing configuration must be explicit and scoped to private output."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('apple_signing_config', Path(__file__).parents[1] / 'ios/configure_apple_signing.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class SigningConfigTests(unittest.TestCase):
    def test_explicit_team_is_private_and_exact(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = config.configure('A1B2C3D4E5', root)
            self.assertEqual(path.read_text(), 'DEVELOPMENT_TEAM = A1B2C3D4E5\n')
            self.assertTrue(path.is_relative_to(root.resolve() / 'tmp/docs/handoffs'))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_missing_or_injected_team_fails_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for team in ('', 'invalid', 'A1B2C3D4E5\nOTHER = injected'):
                with self.assertRaises(ValueError):
                    config.configure(team, root)
            self.assertFalse((root / 'tmp').exists())

    def test_private_output_symlink_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'tmp').symlink_to(root)
            with self.assertRaises(ValueError):
                config.configure('A1B2C3D4E5', root)

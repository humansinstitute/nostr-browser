"""Committed Nostr Browser icons and application names must match the approved branding."""
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('magick'), 'ImageMagick 7 is required')
class BrandingAssetsTests(unittest.TestCase):
    def test_exports_and_product_names_match_approved_branding(self):
        result = subprocess.run([sys.executable, str(ROOT / 'tools/branding_assets.py'), '--check'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Product name: Nostr Browser', result.stdout)
        self.assertIn('PASS: 35 PNG exports', result.stdout)


if __name__ == '__main__':
    unittest.main()

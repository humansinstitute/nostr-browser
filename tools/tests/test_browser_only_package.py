"""Browser package inputs must stay independent of the retired embedded app."""
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from nightly_zapstore import verify_browser_apk, verify_retained_apk


class BrowserOnlyPackageTests(unittest.TestCase):
    def test_all_platform_inputs_and_helpers_have_no_frontend_build(self):
        pubspec = (ROOT / 'app/pubspec.yaml').read_text()
        self.assertNotIn('assets/flightdeck/', pubspec)
        self.assertNotIn('assets/ambulando/', pubspec)
        main = (ROOT / 'app/lib/main.dart').read_text()
        self.assertIn('runApp(const WingmanApp())', main)
        self.assertNotIn('LocalFlightDeckServer', main)
        self.assertNotIn('createFlightDeckUpdateController', main)
        for name in ('macos', 'ios', 'android', 'linux', 'web'):
            self.assertTrue((ROOT / 'app' / name).is_dir(), name)
        for helper in ROOT.glob('build*.sh'):
            text = helper.read_text()
            self.assertNotIn('update_flightdeck_bundle', text, helper.name)
            self.assertNotIn('FLIGHT_DECK_DIR', text, helper.name)
        for helper in ('tools/nightly_zapstore.py', 'tools/ios/testflight_api_release.py',
                       'tools/ios/nightly_testflight.py'):
            text = (ROOT / helper).read_text()
            self.assertNotIn('--flightdeck', text, helper)
            self.assertNotIn('update_flightdeck_bundle', text, helper)
            self.assertNotIn('FLIGHT_DECK_PG_APP_NPUB', text, helper)

    def test_apk_rejects_retired_payload_but_keeps_generic_browser_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'browser.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/flutter_assets/assets/app-selector/background.png', b'image')
                archive.writestr('lib/arm64-v8a/libfips.so', b'native')
            verify_browser_apk(apk)
            for app in ('flightdeck', 'ambulando'):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr(f'assets/flutter_assets/assets/{app}/index.html', b'retired')
                with self.assertRaisesRegex(ValueError, 'retired'):
                    verify_browser_apk(apk)

    def test_legacy_readback_keeps_pinned_evidence_without_permitting_new_bundle(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / 'old.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/flutter_assets/assets/flightdeck/index.html', b'old')
            state = dict(flightdeck_commit='a' * 40,
                         flightdeck_assets={'index.html': hashlib.sha256(b'old').hexdigest()})
            verify_retained_apk(apk, state)
            with self.assertRaises(ValueError):
                verify_retained_apk(apk, dict(state, browser_only=True))
            with self.assertRaises(ValueError):
                verify_retained_apk(apk, {})
            with self.assertRaises(ValueError):
                verify_retained_apk(apk, dict(state, flightdeck_assets={'index.html': '0' * 64}))

    def test_apple_legacy_source_is_readable_but_not_a_new_build(self):
        sys.path.insert(0, str(ROOT / 'tools/ios'))
        from nightly_testflight import _valid_source
        old = {'nbrowser': 'a' * 40, 'flightdeck': 'b' * 40}
        self.assertTrue(_valid_source(old))
        self.assertFalse(_valid_source(old, browser_only=True))
        self.assertTrue(_valid_source({'nbrowser': 'a' * 40}, browser_only=True))

    def test_apple_browser_payload_guard_rejects_stale_flutter_output(self):
        sys.path.insert(0, str(ROOT / 'tools/ios'))
        from testflight_release import verify_browser_payload
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Runner.app'
            assets = app / 'Frameworks/App.framework/flutter_assets/assets'
            assets.mkdir(parents=True)
            verify_browser_payload(app)
            (assets / 'flightdeck').mkdir()
            with self.assertRaisesRegex(ValueError, 'retired'):
                verify_browser_payload(app)


if __name__ == '__main__':
    unittest.main()

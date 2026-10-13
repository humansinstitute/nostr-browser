from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "prepare_zapstore_release.py"
SPEC = importlib.util.spec_from_file_location("prepare_zapstore_release", SCRIPT)
assert SPEC and SPEC.loader
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)


class FakeInspector:
    def inspect(self, _apk: Path, _icon: Path):
        return release.ApkMetadata(
            package_id=release.EXPECTED_PACKAGE_ID,
            version_name="0.1.3",
            version_code=4,
            min_sdk=24,
            target_sdk=36,
            abis=release.EXPECTED_ABIS,
            certificate_sha256=release.EXPECTED_CERTIFICATE_SHA256,
        )


class PrepareZapstoreReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = Path(__file__).resolve().parents[2]
        self.apk = self.root / "input.apk"
        self.icon = self.root / "icon.png"
        self.notes = self.root / "notes.md"
        self.apk.write_bytes(b"signed-apk-fixture")
        self.icon.write_bytes(b"png-fixture")
        self.notes.write_text("Release notes\n", encoding="utf-8")
        self.catalog = self.root / "catalog"
        self.now = datetime(2026, 9, 2, 1, 2, 3, tzinfo=timezone.utc)

    def tearDown(self):
        self.temp.cleanup()

    def prepare(self):
        return release.prepare_release(
            repo=self.repo,
            apk=self.apk,
            icon=self.icon,
            notes=self.notes,
            catalog_root=self.catalog,
            source_commit="HEAD",
            inspector=FakeInspector(),
            now=self.now,
        )

    def test_generates_manifest_and_versioned_snapshot(self):
        target, manifest, created = self.prepare()

        self.assertTrue(created)
        self.assertEqual(target.name, "0.1.3+4")
        self.assertEqual(manifest["createdAt"], "2026-09-02T01:02:03Z")
        self.assertEqual(manifest["platforms"][0]["abis"], ["arm64-v8a"])
        self.assertEqual(manifest["certificateSha256"], release.EXPECTED_CERTIFICATE_SHA256)
        self.assertEqual(
            {path.name for path in target.iterdir()},
            {
                "release.json",
                "app-release.apk",
                "app-release_icon.png",
                "release-notes-0.1.3+4.md",
            },
        )
        self.assertEqual(json.loads((target / "release.json").read_text()), manifest)

    def test_identical_rerun_is_idempotent_and_preserves_created_at(self):
        target, first, first_created = self.prepare()
        self.now = datetime(2027, 1, 1, tzinfo=timezone.utc)
        second_target, second, second_created = self.prepare()

        self.assertTrue(first_created)
        self.assertFalse(second_created)
        self.assertEqual(second_target, target)
        self.assertEqual(second["createdAt"], first["createdAt"])

    def test_changed_input_cannot_replace_release_id(self):
        target, _, _ = self.prepare()
        original_manifest = (target / "release.json").read_bytes()
        self.notes.write_text("Changed release notes\n", encoding="utf-8")

        with self.assertRaises(release.ExistingReleaseConflict):
            self.prepare()

        self.assertEqual((target / "release.json").read_bytes(), original_manifest)
        self.assertEqual(
            (target / "release-notes-0.1.3+4.md").read_text(encoding="utf-8"),
            "Release notes\n",
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Validate and atomically snapshot a signed WMAPP APK for the publisher WApp."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence


EXPECTED_PACKAGE_ID = "com.wingmanbefree.wingman_app"
EXPECTED_CERTIFICATE_SHA256 = (
    "6c0da09b9e2375d657645f197419be7b8227a7434e0225512fc760cedf383c8c"
)
EXPECTED_ABIS = ("arm64-v8a",)
FIPS_LIBRARY = "lib/arm64-v8a/libwmapp_fips_android.so"
VPN_SERVICE = "com.wingmanbefree.wingman_app.fips.FipsVpnService"
VPN_PERMISSION = "android.permission.BIND_VPN_SERVICE"
VPN_ACTION = "android.net.VpnService"
SCHEMA_VERSION = 1


class PreparationError(RuntimeError):
    """Release preparation failed closed."""


class ExistingReleaseConflict(PreparationError):
    """An immutable release ID already contains different content."""


@dataclass(frozen=True)
class ApkMetadata:
    package_id: str
    version_name: str
    version_code: int
    min_sdk: int
    target_sdk: int
    abis: tuple[str, ...]
    certificate_sha256: str

    @property
    def release_id(self) -> str:
        return f"{self.version_name}+{self.version_code}"


def _run(command: Sequence[str], *, env: dict[str, str] | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
    except FileNotFoundError as exc:
        raise PreparationError(f"Required tool was not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stdout or "").strip()
        raise PreparationError(
            f"Command failed ({Path(command[0]).name}): {detail}"
        ) from exc
    return result.stdout


def _version_key(path: Path) -> tuple[tuple[int, object], ...]:
    return tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.split(r"([0-9]+)", path.parent.name)
        if part
    )


def find_android_tools() -> tuple[Path, Path]:
    roots: list[Path] = []
    for variable in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        if os.environ.get(variable):
            roots.append(Path(os.environ[variable]).expanduser())
    roots.extend(
        [
            Path.home() / "Library/Android/sdk",
            Path.home() / "Android/Sdk",
        ]
    )
    for root in roots:
        candidates = sorted(
            (root / "build-tools").glob("*/aapt"), key=_version_key, reverse=True
        )
        for aapt in candidates:
            apksigner = aapt.with_name("apksigner")
            if aapt.is_file() and apksigner.is_file():
                return aapt, apksigner
    raise PreparationError(
        "Android aapt and apksigner were not found under an installed SDK build-tools directory."
    )


def find_zsp() -> Path:
    installed = shutil.which("zsp")
    if installed:
        return Path(installed)
    fallback = Path.home() / "go/bin/zsp"
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return fallback
    raise PreparationError(
        "Zapstore zsp was not found in PATH or ~/go/bin; install it before preparing a release."
    )


class ApkInspector:
    def __init__(
        self,
        aapt: Path | None = None,
        apksigner: Path | None = None,
        zsp: Path | None = None,
    ):
        if aapt is None or apksigner is None:
            aapt, apksigner = find_android_tools()
        self.aapt = aapt
        self.apksigner = apksigner
        self.zsp = zsp or find_zsp()

    def inspect(self, apk: Path, icon: Path) -> ApkMetadata:
        if not apk.is_file():
            raise PreparationError(f"APK does not exist: {apk}")

        signer_env = os.environ.copy()
        bundled_java = Path(
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        )
        if not signer_env.get("JAVA_HOME") and bundled_java.is_dir():
            signer_env["JAVA_HOME"] = str(bundled_java)
        signer = _run(
            [str(self.apksigner), "verify", "--verbose", "--print-certs", str(apk)],
            env=signer_env,
        )
        if not re.search(r"^Verifies$", signer, re.MULTILINE):
            raise PreparationError("apksigner did not confirm a valid APK signature.")
        signer_count = re.search(r"^Number of signers: ([0-9]+)$", signer, re.MULTILINE)
        cert = re.search(
            r"^Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]{64})$",
            signer,
            re.MULTILINE,
        )
        if not signer_count or signer_count.group(1) != "1" or not cert:
            raise PreparationError("Expected exactly one identifiable APK signer.")
        certificate_sha256 = cert.group(1).lower()
        if certificate_sha256 != EXPECTED_CERTIFICATE_SHA256:
            raise PreparationError(
                "APK signing certificate does not match the established WMAPP certificate."
            )

        badging = _run([str(self.aapt), "dump", "badging", str(apk)])
        package = re.search(
            r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'",
            badging,
            re.MULTILINE,
        )
        min_sdk = re.search(r"^sdkVersion:'([0-9]+)'$", badging, re.MULTILINE)
        target_sdk = re.search(r"^targetSdkVersion:'([0-9]+)'$", badging, re.MULTILINE)
        native_code = re.search(r"^native-code: (.+)$", badging, re.MULTILINE)
        if not package or not min_sdk or not target_sdk or not native_code:
            raise PreparationError("aapt returned incomplete APK package, SDK, or ABI metadata.")
        package_id, version_code_text, version_name = package.groups()
        if package_id != EXPECTED_PACKAGE_ID:
            raise PreparationError(f"Unexpected APK package ID: {package_id}")
        abis = tuple(re.findall(r"'([^']+)'", native_code.group(1)))
        if abis != EXPECTED_ABIS:
            raise PreparationError(
                f"Expected ARM64-only APK ABIs {EXPECTED_ABIS}, found {abis or 'none'}."
            )
        if not re.fullmatch(r"[0-9A-Za-z._-]+", version_name):
            raise PreparationError("APK version name is unsafe for a stable release directory.")

        manifest = _run(
            [str(self.aapt), "dump", "xmltree", str(apk), "AndroidManifest.xml"]
        )
        if not self._has_vpn_service(manifest):
            raise PreparationError(
                "Compiled manifest is missing the expected protected FIPS VPN service declaration."
            )

        try:
            with zipfile.ZipFile(apk) as archive:
                bad_member = archive.testzip()
                names = set(archive.namelist())
        except (OSError, zipfile.BadZipFile) as exc:
            raise PreparationError("APK is not a readable, internally consistent ZIP archive.") from exc
        if bad_member:
            raise PreparationError(f"APK ZIP integrity check failed at {bad_member}.")
        if FIPS_LIBRARY not in names:
            raise PreparationError(f"APK is missing {FIPS_LIBRARY}.")

        metadata = ApkMetadata(
            package_id=package_id,
            version_name=version_name,
            version_code=int(version_code_text),
            min_sdk=int(min_sdk.group(1)),
            target_sdk=int(target_sdk.group(1)),
            abis=abis,
            certificate_sha256=certificate_sha256,
        )
        self._validate_zsp_metadata_and_icon(apk, icon, metadata)
        return metadata

    def _validate_zsp_metadata_and_icon(
        self, apk: Path, icon: Path, metadata: ApkMetadata
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="wmapp-zsp-extract-") as temp_text:
            temp = Path(temp_text)
            copied_apk = temp / "app-release.apk"
            try:
                os.link(apk, copied_apk)
            except OSError:
                shutil.copyfile(apk, copied_apk)
            output = _run([str(self.zsp), "utils", "extract-apk", str(copied_apk)])
            try:
                extracted = json.loads(output)
            except json.JSONDecodeError as exc:
                raise PreparationError("zsp returned invalid APK metadata JSON.") from exc
            expected = {
                "package_id": metadata.package_id,
                "version_name": metadata.version_name,
                "version_code": metadata.version_code,
                "min_sdk": metadata.min_sdk,
                "target_sdk": metadata.target_sdk,
                "architectures": list(metadata.abis),
                "cert_fingerprint": metadata.certificate_sha256,
                "file_size": apk.stat().st_size,
                "sha256": sha256_file(apk),
            }
            mismatches = [
                key for key, expected_value in expected.items()
                if extracted.get(key) != expected_value
            ]
            if mismatches:
                raise PreparationError(
                    "zsp metadata disagrees with validated Android metadata: "
                    + ", ".join(mismatches)
                )
            extracted_icon = temp / "app-release_icon.png"
            if not extracted_icon.is_file() or sha256_file(extracted_icon) != sha256_file(icon):
                raise PreparationError(
                    "Canonical icon differs from the launcher icon extracted from this APK by zsp."
                )

    @staticmethod
    def _has_vpn_service(manifest: str) -> bool:
        lines = manifest.splitlines()
        for index, line in enumerate(lines):
            if line.lstrip().startswith("E: service"):
                indent = len(line) - len(line.lstrip())
                block = [line]
                for following in lines[index + 1 :]:
                    following_indent = len(following) - len(following.lstrip())
                    if following.strip() and following_indent <= indent:
                        break
                    block.append(following)
                text = "\n".join(block)
                if all(value in text for value in (VPN_SERVICE, VPN_PERMISSION, VPN_ACTION)):
                    return True
        return False


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(filename: str, mime_type: str, source: Path) -> dict[str, object]:
    return {
        "filename": filename,
        "mimeType": mime_type,
        "byteSize": source.stat().st_size,
        "sha256": sha256_file(source),
    }


def validate_source_commit(repo: Path, source_commit: str) -> str:
    if source_commit != "HEAD" and not re.fullmatch(r"[0-9a-fA-F]{7,40}", source_commit):
        raise PreparationError("Source commit must be HEAD or a Git commit hash.")
    resolved = _run(
        ["git", "-C", str(repo), "rev-parse", "--verify", f"{source_commit}^{{commit}}"],
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    ).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", resolved):
        raise PreparationError("Git did not resolve the source commit to a full hash.")
    return resolved


def _manifest(
    metadata: ApkMetadata,
    created_at: str,
    source_commit: str,
    apk: Path,
    icon: Path,
    notes: Path,
) -> dict[str, object]:
    notes_filename = f"release-notes-{metadata.release_id}.md"
    return {
        "schemaVersion": SCHEMA_VERSION,
        "releaseId": metadata.release_id,
        "createdAt": created_at,
        "sourceGitCommit": source_commit,
        "packageId": metadata.package_id,
        "versionName": metadata.version_name,
        "versionCode": metadata.version_code,
        "platforms": [{"name": "android", "abis": list(metadata.abis)}],
        "minSdk": metadata.min_sdk,
        "targetSdk": metadata.target_sdk,
        "certificateSha256": metadata.certificate_sha256,
        "validatedContents": {
            "fipsLibrary": FIPS_LIBRARY,
            "vpnService": VPN_SERVICE,
        },
        "files": {
            "apk": file_record("app-release.apk", "application/vnd.android.package-archive", apk),
            "icon": file_record("app-release_icon.png", "image/png", icon),
            "releaseNotes": file_record(notes_filename, "text/markdown", notes),
        },
    }


def _validate_input_file(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink():
        raise PreparationError(f"{label} must be a regular, non-symlink file: {path}")


def _existing_matches(target: Path, candidate: dict[str, object]) -> bool:
    manifest_path = target / "release.json"
    try:
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ExistingReleaseConflict(
            f"Existing release {target.name} has no valid immutable manifest."
        ) from exc
    created_at = existing.get("createdAt")
    if not isinstance(created_at, str):
        raise ExistingReleaseConflict(f"Existing release {target.name} has no creation timestamp.")
    try:
        parsed_created_at = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ExistingReleaseConflict(
            f"Existing release {target.name} has an invalid creation timestamp."
        ) from exc
    if parsed_created_at.tzinfo is None:
        raise ExistingReleaseConflict(
            f"Existing release {target.name} creation timestamp has no timezone."
        )
    candidate["createdAt"] = created_at
    if existing != candidate:
        return False
    expected_names = {"release.json"}
    for record in existing["files"].values():
        filename = record["filename"]
        expected_names.add(filename)
        path = target / filename
        if (
            not path.is_file()
            or path.is_symlink()
            or path.stat().st_size != record["byteSize"]
            or sha256_file(path) != record["sha256"]
        ):
            return False
    actual_names = {path.name for path in target.iterdir()}
    return actual_names == expected_names


def prepare_release(
    *,
    repo: Path,
    apk: Path,
    icon: Path,
    notes: Path | None,
    catalog_root: Path,
    source_commit: str,
    inspector: ApkInspector | None = None,
    now: datetime | None = None,
) -> tuple[Path, dict[str, object], bool]:
    _validate_input_file(apk, "APK")
    _validate_input_file(icon, "Icon")
    metadata = (inspector or ApkInspector()).inspect(apk, icon)
    if notes is None:
        notes = repo / "docs/release-notes" / f"{metadata.version_name}.md"
    _validate_input_file(notes, "Release notes")
    resolved_commit = validate_source_commit(repo, source_commit)

    if catalog_root.is_symlink():
        raise PreparationError(f"Catalog root must not be a symlink: {catalog_root}")
    catalog_root.mkdir(parents=True, exist_ok=True)
    target = catalog_root / metadata.release_id
    timestamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    created_at = timestamp.isoformat(timespec="seconds").replace("+00:00", "Z")
    manifest = _manifest(metadata, created_at, resolved_commit, apk, icon, notes)

    if target.exists():
        if (
            target.is_symlink()
            or not target.is_dir()
            or not _existing_matches(target, manifest)
        ):
            raise ExistingReleaseConflict(
                f"Refusing to replace immutable release {metadata.release_id}: existing bytes or metadata differ."
            )
        return target, manifest, False

    staging = Path(
        tempfile.mkdtemp(
            prefix=f".zapstore-{metadata.release_id}.staging-", dir=catalog_root.parent
        )
    )
    try:
        records = manifest["files"]
        for key, source in (("apk", apk), ("icon", icon), ("releaseNotes", notes)):
            destination = staging / records[key]["filename"]
            shutil.copyfile(source, destination)
            with destination.open("rb") as stream:
                os.fsync(stream.fileno())
        manifest_path = staging / "release.json"
        with manifest_path.open("x", encoding="utf-8") as stream:
            json.dump(manifest, stream, indent=2, sort_keys=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.rename(staging, target)
        directory_fd = os.open(catalog_root, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except FileExistsError as exc:
        raise ExistingReleaseConflict(
            f"Release {metadata.release_id} appeared concurrently; refusing to overwrite it."
        ) from exc
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return target, manifest, True


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-commit",
        default="HEAD",
        help="Git commit from which the already-built APK was produced (default: HEAD)",
    )
    parser.add_argument(
        "--apk",
        type=Path,
        default=repo / "app/build/app/outputs/flutter-apk/app-release.apk",
    )
    parser.add_argument(
        "--icon",
        type=Path,
        default=repo / "app/build/app/outputs/flutter-apk/app-release_icon.png",
    )
    parser.add_argument(
        "--release-notes",
        type=Path,
        help="Defaults to docs/release-notes/<APK version name>.md",
    )
    parser.add_argument(
        "--catalog-root",
        type=Path,
        default=repo / "app/build/zapstore-releases",
    )
    parser.set_defaults(repo=repo)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        target, manifest, created = prepare_release(
            repo=args.repo,
            apk=args.apk.resolve(),
            icon=args.icon.resolve(),
            notes=args.release_notes.resolve() if args.release_notes else None,
            catalog_root=args.catalog_root.resolve(),
            source_commit=args.source_commit,
        )
    except PreparationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    action = "Prepared" if created else "Already prepared"
    print(f"{action} Zapstore release {manifest['releaseId']}: {target}")
    print(f"Manifest: {target / 'release.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

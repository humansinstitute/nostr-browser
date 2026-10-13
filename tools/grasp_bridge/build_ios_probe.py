#!/usr/bin/env python3
"""Build the isolated stock-WKWebView fixture app for an Apple Silicon simulator."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: build_ios_probe.py OUTPUT_DIRECTORY")
root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve() / "GraspProbe.app"
output.mkdir(parents=True, exist_ok=True)
(output / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "org.wingman.validation.GraspProbe",
    "CFBundleName": "GraspProbe",
    "CFBundleExecutable": "GraspProbe",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "CFBundlePackageType": "APPL",
    "LSRequiresIPhoneOS": True,
    "UIDeviceFamily": [1, 2],
    "UILaunchScreen": {},
    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
}))
sdk = subprocess.check_output(
    ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True
).strip()
subprocess.run([
    "xcrun", "--sdk", "iphonesimulator", "swiftc", "-sdk", sdk,
    "-target", "arm64-apple-ios17.0-simulator",
    str(root / "tools/grasp_bridge/main.swift"),
    str(root / "packages/webview_flutter_wkwebview/darwin/"
        "webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/"
        "WingmanScriptMessagePolicy.swift"),
    "-o", str(output / "GraspProbe"),
], env={**os.environ, "SDKROOT": sdk}, check=True)
print(output)

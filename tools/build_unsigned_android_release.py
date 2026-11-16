#!/usr/bin/env python3
"""Build an unsigned release APK from an isolated committed source snapshot.

The main checkout's signing guard and provider/Kotlin files are never edited.
The output is intentionally not installable until its owner signs it.
"""
import argparse
import os
from pathlib import Path
import subprocess
from release_sources import snapshot
from verify_android_jni import verify

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--commit', required=True)
parser.add_argument('--build-number', type=int, required=True)
parser.add_argument('--channel', choices=('stable', 'nightly'), default='stable')
parser.add_argument('--output', type=Path, required=True,
                    help='New ignored directory under tmp/docs/handoffs')
args = parser.parse_args()
if args.build_number <= 13:
    parser.error('The packaged shell test build must be greater than 13.')
output = args.output.resolve()
allowed = (root / 'tmp/docs/handoffs').resolve()
if not output.is_relative_to(allowed) or output == allowed or output.exists():
    parser.error('Use a new output directory under ignored tmp/docs/handoffs.')
subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', str(output)], check=True)
output.parent.mkdir(parents=True, exist_ok=True)
snapshot(root, output, args.commit)
gradle = output / 'app/android/app/build.gradle.kts'
source = gradle.read_text()
start = source.index('gradle.taskGraph.whenReady {')
end = source.index('\nkotlin {', start)
block = source[start:end]
if ('WMAPP release signing is not configured.' not in block or
        block.count('gradle.taskGraph.whenReady') != 1):
    raise ValueError('Signing guard changed; review unsigned build adaptation.')
gradle.write_text(source[:start] + '// Isolated unsigned-build snapshot: no signing credentials are loaded.\n' + source[end:])
env = dict(os.environ)
for name in ('WMAPP_ANDROID_KEYSTORE', 'WMAPP_ANDROID_STORE_PASSWORD',
             'WMAPP_ANDROID_KEY_ALIAS', 'WMAPP_ANDROID_KEY_PASSWORD'):
    env.pop(name, None)
env['WMAPP_ANDROID_CHANNEL'] = args.channel
env['CARGO_TARGET_DIR'] = str(root / 'target')
subprocess.run(['flutter', 'build', 'apk', '--release', '--target-platform',
                'android-arm64', '--build-number', str(args.build_number)],
               cwd=output / 'app', env=env, check=True)
apk = output / 'app/build/app/outputs/flutter-apk/app-release.apk'
if not apk.exists():
    raise FileNotFoundError(apk)
sdk = Path(env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT') or
           Path.home() / 'Library/Android/sdk')
dexdumps = sorted((sdk / 'build-tools').glob('*/dexdump'))
if not dexdumps:
    raise FileNotFoundError('Android SDK dexdump is required to verify release JNI ABI')
print(verify(apk, dexdumps[-1]))
print(f'UNSIGNED release APK (owner signing required): {apk}')
print(f'Source commit: {args.commit}; test build number: {args.build_number}')

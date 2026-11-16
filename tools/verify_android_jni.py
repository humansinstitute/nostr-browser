#!/usr/bin/env python3
"""Assert the actual release APK retains the name-based JNI ABI using dexdump."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def verify(apk, dexdump):
    found = {}
    class_name = 'Lcom/wingmanbefree/wingman_app/fips/FipsNative;'
    required = {
        'resolvePublicDns': ('([BJ)[B', 'STATIC'),
        'nativePrepare': ('(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;', 'NATIVE'),
        'nativeStartNode': ('()Ljava/lang/String;', 'NATIVE'),
        'nativeRunNode': ('(IJ)Ljava/lang/String;', 'NATIVE'),
        'nativeInspect': ('()Ljava/lang/String;', 'NATIVE'),
        'nativeStop': ('()Ljava/lang/String;', 'NATIVE'),
        'nativePeerStatus': ('()Ljava/lang/String;', 'NATIVE'),
        'nativeProbe': ('(Ljava/lang/String;)Ljava/lang/String;', 'NATIVE'),
    }
    with tempfile.TemporaryDirectory() as temporary, zipfile.ZipFile(apk) as archive:
        for name in archive.namelist():
            if not re.fullmatch(r'classes\d*\.dex', name):
                continue
            dex = Path(temporary) / name
            dex.write_bytes(archive.read(name))
            # DEX strings use modified UTF-8; unrelated string constants may
            # contain encodings invalid in standard UTF-8. ABI names are ASCII.
            output = subprocess.check_output(
                [str(dexdump), str(dex)], text=True, errors='replace')
            for block in output.split('Class #'):
                if f"Class descriptor  : '{class_name}'" not in block:
                    continue
                for method, (signature, flag) in required.items():
                    pattern = (r"name\s+: '" + method + r"'\s+type\s+: '" +
                               re.escape(signature) + r"'\s+access\s+: [^\n]*\b" + flag + r"\b")
                    if re.search(pattern, block):
                        found[method] = f'{class_name}.{method}{signature} {flag}'
    missing = required.keys() - found.keys()
    if missing:
        raise ValueError('Missing exact JNI ABI in APK DEX: ' + ', '.join(sorted(missing)))
    return '\n'.join(found.values())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--dexdump', required=True, type=Path)
    args = parser.parse_args()
    print(verify(args.apk, args.dexdump))

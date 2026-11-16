#!/usr/bin/env python3
"""Import an explicitly reviewed local Tower build; never downloads assets."""
import hashlib
import json
import pathlib
import re
import shutil
import sys

def require(condition, message='invalid packaged shell'):
    if not condition:
        raise ValueError(message)


if len(sys.argv) != 3:
    raise SystemExit('Usage: import_nstack_shell.py <local-build-directory> <reviewed-manifest-sha256>')
source = pathlib.Path(sys.argv[1]).resolve()
expected = sys.argv[2]
raw = (source / 'manifest.json').read_bytes()
require(hashlib.sha256(raw).hexdigest() == expected, 'manifest pin mismatch')
m = json.loads(raw)
require(m['schemaVersion'] == 1 and m['id'] == 'nstack' and m['entrypoint'] == 'index.html')
require(re.fullmatch('[a-f0-9]{40}', m['sourceRevision']))
require(0 < len(m['files']) <= 256)
verified = {'manifest.json': raw}
for name, meta in m['files'].items():
    require(re.fullmatch('[a-zA-Z0-9_-][a-zA-Z0-9_./-]*', name))
    require(all(p not in ('', '.', '..') for p in name.split('/')))
    path = source / name
    require(path.resolve().is_relative_to(source) and not path.is_symlink())
    data = path.read_bytes()
    require(hashlib.sha256(data).hexdigest() == meta['sha256'], name)
    verified[name] = data
require(m['files']['index.html']['contentType'].split(';')[0] == 'text/html')
require(sum(map(len, verified.values())) <= 32 * 1024 * 1024, 'package exceeds size limit')
root = pathlib.Path(__file__).resolve().parents[1]
dest = root / 'app/assets/nstack-shell'
if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True)
for name in ['manifest.json', *m['files']]:
    target = dest / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(verified[name])
(root / 'app/lib/src/core/nstack_shell_catalogue.dart').write_text(
    "/// Reviewed packaged manifest pin; update only with its complete asset set.\n"
    f"const nstackShellManifestSha256 = '{expected}';\n")
pub = root / 'app/pubspec.yaml'
s = pub.read_text()
s = re.sub(r'^    - assets/nstack-shell/.*\n', '', s, flags=re.M)
s = s.replace('  assets:\n', '  assets:\n' + ''.join(
    f'    - assets/nstack-shell/{name}\n' for name in ['manifest.json', *m['files']]), 1)
pub.write_text(s)
print(f'Imported {len(m["files"])} reviewed assets from {m["sourceRevision"]}')

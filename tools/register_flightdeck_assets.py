#!/usr/bin/env python3
"""Register each generated Flight Deck directory: Flutter assets are not recursive."""
from pathlib import Path
import re
import sys


def register(root):
    bundle = root / 'app/assets/flightdeck'
    if not (bundle / 'version.json').is_file():
        raise ValueError('Verified Flight Deck bundle required.')
    directories = {bundle}
    for path in bundle.rglob('*'):
        if path.is_symlink():
            raise ValueError('Flight Deck assets cannot contain symlinks.')
        if path.is_file():
            directories.add(path.parent)
    entries = []
    for directory in sorted(directories):
        relative = directory.relative_to(root / 'app').as_posix() + '/'
        if not re.fullmatch(r'[A-Za-z0-9_./-]+', relative):
            raise ValueError('Unsafe Flutter asset directory.')
        entries.append('    - ' + relative)
    pubspec = root / 'app/pubspec.yaml'
    text = pubspec.read_text()
    pattern = r'(?m)^    - assets/flightdeck/[^\n]*\n'
    if not re.search(pattern, text):
        raise ValueError('Flight Deck asset declaration missing.')
    first = re.search(pattern, text).start()
    stripped = re.sub(pattern, '', text)
    pubspec.write_text(stripped[:first] + '\n'.join(entries) + '\n' + stripped[first:])
    return entries


if __name__ == '__main__':
    register(Path(sys.argv[1]).resolve())

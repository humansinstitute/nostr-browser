#!/usr/bin/env python3
"""Write ignored Apple signing settings from explicit local configuration."""
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def configure(team=None, root=ROOT):
    team = team if team is not None else os.environ.get('WMAPP_APPLE_TEAM', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Set WMAPP_APPLE_TEAM to the verified existing Apple team.')
    root = root.resolve()
    directory = root / 'tmp/docs/handoffs/apple-signing'
    if any(p.is_symlink() for p in [directory, *directory.parents] if p.is_relative_to(root)):
        raise ValueError('Signing configuration must not use symlinks.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    settings = directory / 'Signing.local.xcconfig'
    if settings.is_symlink():
        raise ValueError('Signing configuration must not use symlinks.')
    settings.write_text('DEVELOPMENT_TEAM = ' + team + '\n')
    settings.chmod(0o600)
    return settings


if __name__ == '__main__':
    print(configure())

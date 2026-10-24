#!/usr/bin/env python3
"""Short process-owned source lock and immutable committed release snapshots."""
from contextlib import contextmanager
import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def source_lock(root=ROOT, timeout=1800):
    """Serialize source checkpoint/snapshot work, never store processing or delivery.

    flock is released by the kernel on exit/crash; the file is not a lease and
    must never be deleted. Each store keeps its own delivery/claim lock.
    """
    path = root / 'tmp/docs/handoffs/nightly-source.lock'
    if any(p.is_symlink() for p in [path, *path.parents]):
        raise ValueError('Source lock cannot traverse symlinks.')
    relative = str(path.relative_to(root))
    subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', relative], check=True)
    if subprocess.check_output(['git', '-C', str(root), 'ls-files', '--', relative]):
        raise ValueError('Source lock must be untracked.')
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        os.chmod(path, 0o600)
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError('Source preparation lock busy; no store delivery was attempted.')
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def snapshot(repo, target, commit):
    """Archive the selected commit even if shared HEAD/edits subsequently move."""
    if not re.fullmatch('[a-f0-9]{40}', commit):
        raise ValueError('Exact committed snapshot identity required.')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *map(str, args)], text=True).strip()
    if git('rev-parse', commit + '^{commit}') != commit:
        raise ValueError('Snapshot commit unavailable.')
    target.mkdir(mode=0o700)
    archive = target.with_suffix('.tar')
    with archive.open('xb') as stream:
        subprocess.run(['git', '-C', str(repo), 'archive', commit], stdout=stream, check=True)
    subprocess.run(['tar', '-xf', str(archive), '-C', str(target)], check=True)
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(target)], check=True)
    objects = Path(git('rev-parse', '--git-path', 'objects'))
    if not objects.is_absolute(): objects = repo / objects
    (target / '.git/objects/info/alternates').write_text(str(objects.resolve()) + '\n')
    for args in [('read-tree', commit), ('update-ref', 'refs/heads/main', commit),
                 ('symbolic-ref', 'HEAD', 'refs/heads/main')]:
        subprocess.run(['git', '-C', str(target), *args], check=True)
    return commit


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command: parser.error('Provide a source-preparation command after --.')
    with source_lock():
        raise SystemExit(subprocess.run(command).returncode)

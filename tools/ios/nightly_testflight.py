#!/usr/bin/env python3
"""Private daily release claim and read-only prerequisites; never uploads to Apple."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
PRIVATE = ROOT / 'tmp/docs/handoffs/nightly-testflight'


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def safe_private(path=PRIVATE):
    path = Path(path).absolute()
    if not path.is_relative_to(ROOT / 'tmp/docs/handoffs'):
        raise ValueError('Evidence must remain under tmp/docs/handoffs.')
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise ValueError('Evidence path cannot traverse symlinks.')
    relative = str(path.relative_to(ROOT))
    subprocess.run(['git', '-C', str(ROOT), 'check-ignore', '-q', relative], check=True)
    if git(ROOT, 'ls-files', '--', relative):
        raise ValueError('Evidence destination contains tracked files.')


def save(path, value):
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    os.chmod(temp, 0o600)
    temp.replace(path)


def transition(directory, action, owner, day, result=None):
    """Serialize claim/finish; a crashed active claim needs explicit reconciliation."""
    if not owner:
        raise ValueError('A session owner is required.')
    if directory.is_symlink() or any((directory / name).is_symlink()
                                    for name in ('.lock', 'ledger.json', 'ledger.new')):
        raise ValueError('Claim storage cannot use symlinks.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = directory / 'ledger.json'
        ledger = json.loads(path.read_text()) if path.exists() else {'schema': 1, 'days': {}}
        if ledger.get('schema') != 1:
            raise ValueError('Unsupported nightly ledger.')
        days = ledger['days']
        if action == 'claim':
            if day in days:
                raise ValueError('This Perth day is already claimed; do not repeat its release or report.')
            if any(v['status'] == 'active' for v in days.values()):
                raise ValueError('Another nightly release is active; reconcile it before another run. No automatic expiry.')
            days[day] = {'owner': owner, 'status': 'active', 'started_at': dt.datetime.now(dt.timezone.utc).isoformat()}
        else:
            entry = days.get(day)
            if not entry or entry['owner'] != owner or entry['status'] != 'active':
                raise ValueError('Only the active claim owner can finish this day.')
            if result not in ('blocked_auth', 'failed', 'processing', 'testing'):
                raise ValueError('An explicit release outcome is required.')
            entry.update(status=result, finished_at=dt.datetime.now(dt.timezone.utc).isoformat())
        save(path, ledger)
        return {'day': day, **days[day]}


def recover_claim(directory, owner, previous_owner, run, state_sha256):
    """Explicitly resume a failed day for one proved retained export, preserving history."""
    if not owner or owner == previous_owner or not run or len(state_sha256) != 64:
        raise ValueError('Distinct recovery owner and exact retained run are required.')
    if directory.is_symlink() or any((directory / name).is_symlink() for name in ('.lock', 'ledger.json', 'ledger.new')):
        raise ValueError('Claim storage cannot use symlinks.')
    day = dt.datetime.now(ZoneInfo('Australia/Perth')).date().isoformat()
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = directory / 'ledger.json'
        ledger = json.loads(path.read_text())
        entry = ledger.get('days', {}).get(day)
        if ledger.get('schema') != 1 or not entry or entry.get('owner') != previous_owner or entry.get('status') != 'failed' or any(v.get('status') == 'active' for v in ledger['days'].values()):
            raise ValueError('Recovery requires exact failed current-day owner and no active claim.')
        prior = dict(entry)
        entry.clear()
        entry.update(owner=owner, status='active', started_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                     recovery_run=run, recovery_state_sha256=state_sha256, prior_claim=prior)
        save(path, ledger)
        return {'day': day, **entry}


def prerequisites(fd):
    repos = {}
    for name, repo in [('flightdeck', fd), ('wmapp', ROOT)]:
        repos[name] = {'branch': git(repo, 'branch', '--show-current'),
                       'commit': git(repo, 'rev-parse', 'HEAD'),
                       'status': git(repo, 'status', '--porcelain'),
                       'upstream': git(repo, 'config', '--get', 'branch.main.remote')}
    auth = {'ready': False, 'status': 'blocked_auth', 'release_ready': False,
            'reason': 'Private API credential reference is missing.'}
    reference = PRIVATE / 'auth-reference.json'
    if reference.is_file():
        try:
            from appstore_connect import Client
            from testflight_api_release import numbers, delivery_barrier
            import testflight_release as release
            client = Client(reference)
            h = client.preflight()
            auth.pop('reason', None)
            auth.update(ready=True, status='api_authenticated', history_complete=True,
                        builds=numbers(h), audience=h['audience'],
                        pending_upload_ids=h['pending_upload_ids'], pending_build_ids=h['pending_build_ids'],
                        upload_path='xcodebuild API archive/export/upload; live upload not yet proven',
                        release_ready=not h['pending_upload_ids'] and not h['pending_build_ids'],
                        inactive_upload_ids=h['inactive_upload_ids'])
            try:
                delivery_barrier(release, None, client)
            except ValueError as error:
                auth.update(release_ready=False, release_blocker=str(error))
            if h['pending_upload_ids'] or h['pending_build_ids']:
                auth['release_blocker'] = 'Apple pending delivery requires reconciliation.'
        except (ValueError, OSError, KeyError, ImportError) as error:
            auth.update(ready=False, release_ready=False, status='blocked_auth', reason=str(error))
    return {'repos': repos, 'main_ready': all(v['branch'] == 'main' for v in repos.values()),
            'tools': {tool: bool(shutil.which(tool)) for tool in ('flutter', 'xcodebuild', 'codesign', 'bun', 'node', 'rsync')},
            'auth': auth, 'upload_performed': False}



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('dry-run', 'claim', 'finish'))
    parser.add_argument('--flightdeck', type=Path, default=ROOT.parent / 'flightdeck')
    parser.add_argument('--owner', default=os.environ.get('SESSION_ID'))
    parser.add_argument('--day', help='Claimed Perth date, YYYY-MM-DD; finish must use claim output.')
    parser.add_argument('--result', choices=('blocked_auth', 'failed', 'processing', 'testing'))
    args = parser.parse_args()
    safe_private()
    if args.action == 'dry-run':
        output = prerequisites(args.flightdeck)
        output['private_path_verified'] = True
        output['ledger_present'] = (PRIVATE / 'ledger.json').exists()
    else:
        day = args.day or dt.datetime.now(ZoneInfo('Australia/Perth')).date().isoformat()
        if dt.date.fromisoformat(day).isoformat() != day:
            raise ValueError('Invalid Perth day.')
        if args.action == 'finish' and not args.day:
            raise ValueError('Finish requires the exact claimed --day.')
        if args.action == 'claim' and day != dt.datetime.now(ZoneInfo('Australia/Perth')).date().isoformat():
            raise ValueError('Claim must use the current Perth day.')
        output = transition(PRIVATE, args.action, args.owner, day, args.result)
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('Stopped: ' + str(error))

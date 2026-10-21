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
SCHEMA = 2


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


def source_identity(fd):
    """Return the exact clean committed source pair that a claim authorizes."""
    source = {}
    for name, repo in [('nbrowser', ROOT), ('flightdeck', Path(fd))]:
        if git(repo, 'branch', '--show-current') != 'main':
            raise ValueError('Nightly source claims require main in both repositories.')
        if git(repo, 'status', '--porcelain'):
            raise ValueError('Commit compatible source before claiming its release.')
        source[name] = git(repo, 'rev-parse', 'HEAD')
    return source


def _valid_source(source):
    return (isinstance(source, dict) and set(source) == {'nbrowser', 'flightdeck'} and
            all(isinstance(value, str) and len(value) == 40 and
                all(char in '0123456789abcdef' for char in value) for value in source.values()))


def _ledger(value):
    """Read legacy ledgers without discarding history; writes upgrade to schema 2."""
    if value.get('schema') == SCHEMA and isinstance(value.get('days'), dict):
        ledger = value
    elif value.get('schema') == 1 and isinstance(value.get('days'), dict):
        ledger = {'schema': SCHEMA, 'days': {
            day: {'attempts': [dict(entry)]} for day, entry in value['days'].items()
        }}
    else:
        raise ValueError('Unsupported nightly ledger.')
    if any(not isinstance(record, dict) or not isinstance(record.get('attempts'), list) or
           not record['attempts'] for record in ledger['days'].values()):
        raise ValueError('Invalid nightly ledger history.')
    return ledger


def active_claim(ledger, day=None):
    active = [(record_day, attempt) for record_day, record in ledger.get('days', {}).items()
              for attempt in record.get('attempts', []) if attempt.get('status') == 'active']
    if len(active) > 1:
        raise ValueError('Multiple active nightly claims require reconciliation.')
    if not active or (day is not None and active[0][0] != day):
        return None
    return active[0][1]


def transition(directory, action, owner, day, result=None, source=None):
    """Serialize source-aware claims; a crashed active claim needs reconciliation."""
    if not owner:
        raise ValueError('A session owner is required.')
    if directory.is_symlink() or any((directory / name).is_symlink()
                                    for name in ('.lock', 'ledger.json', 'ledger.new')):
        raise ValueError('Claim storage cannot use symlinks.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = directory / 'ledger.json'
        ledger = _ledger(json.loads(path.read_text())) if path.exists() else {'schema': SCHEMA, 'days': {}}
        days = ledger['days']
        if action == 'claim':
            if not _valid_source(source):
                raise ValueError('Claim requires exact committed NBrowser and Flight Deck source.')
            if active_claim(ledger):
                raise ValueError('Another nightly release is active; reconcile it before another run. No automatic expiry.')
            record = days.setdefault(day, {'attempts': []})
            attempts = record['attempts']
            if any(attempt.get('source') is None for attempt in attempts):
                raise ValueError('This Perth day has a legacy claim without pinned source; reconcile it explicitly.')
            if any(attempt.get('source') == source for attempt in attempts):
                raise ValueError('This exact committed source is already claimed for the Perth day; do not duplicate it.')
            attempts.append({'owner': owner, 'status': 'active', 'source': dict(source),
                             'started_at': dt.datetime.now(dt.timezone.utc).isoformat()})
            entry = attempts[-1]
        else:
            attempts = days.get(day, {}).get('attempts', [])
            matches = [attempt for attempt in attempts
                       if attempt.get('owner') == owner and attempt.get('status') == 'active']
            if len(matches) != 1:
                raise ValueError('Only the active claim owner can finish this day.')
            entry = matches[0]
            if result not in ('blocked_auth', 'failed', 'processing', 'action_required', 'testing'):
                raise ValueError('An explicit release outcome is required.')
            entry.update(status=result, finished_at=dt.datetime.now(dt.timezone.utc).isoformat())
        save(path, ledger)
        return {'day': day, 'attempt': days[day]['attempts'].index(entry) + 1, **entry}


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
        ledger = _ledger(json.loads(path.read_text()))
        attempts = ledger.get('days', {}).get(day, {}).get('attempts', [])
        matches = [attempt for attempt in attempts
                   if attempt.get('owner') == previous_owner and attempt.get('status') == 'failed']
        if len(matches) != 1 or active_claim(ledger):
            raise ValueError('Recovery requires exact failed current-day owner and no active claim.')
        prior = dict(matches[0])
        entry = dict(owner=owner, status='active', source=prior.get('source'),
                     started_at=dt.datetime.now(dt.timezone.utc).isoformat(), recovery_run=run,
                     recovery_state_sha256=state_sha256, prior_claim=prior)
        attempts.append(entry)
        save(path, ledger)
        return {'day': day, 'attempt': len(attempts), **entry}


def prerequisites(fd):
    repos = {}
    for name, repo in [('flightdeck', fd), ('nbrowser', ROOT)]:
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
    parser.add_argument('--result', choices=('blocked_auth', 'failed', 'processing', 'action_required', 'testing'))
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
        source = source_identity(args.flightdeck) if args.action == 'claim' else None
        output = transition(PRIVATE, args.action, args.owner, day, args.result, source)
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('Stopped: ' + str(error))

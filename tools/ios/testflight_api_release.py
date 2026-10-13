"""API actions for the existing TestFlight helper; private internal releases only."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
from appstore_connect import Client, APP


def numbers(h):
    return [int(b['attributes']['version']) for b in h['builds']] + [int(u['attributes']['cfBundleVersion']) for u in h['uploads']]


def latest_version(r, h):
    versions = [v['attributes']['version'] for v in h['versions'] if v['attributes']['platform'] == 'IOS']
    versions += [u['attributes']['cfBundleShortVersionString'] for u in h['uploads']]
    return max(versions, key=r.version)


def reservation_gate(r, h, s):
    r.require(not h['pending_upload_ids'] and not h.get('pending_build_ids'), 'Apple history has pending deliveries.')
    r.require(s['build'] > max(numbers(h), default=0), 'Apple build history changed; reconcile and reserve higher.')
    r.require(r.version(s['version']) >= r.version(latest_version(r, h)), 'Apple marketing version changed; rebuild with current version.')


PENDING = {'upload_pending', 'uploaded_processing', 'api_processing', 'api_upload_uncertain',
           'api_action_required', 'uploaded_action_required', 'api_assigned_ready', 'api_failed_processing'}


def require_daily_claim(run=None, action=None):
    import datetime as dt
    from zoneinfo import ZoneInfo
    from nightly_testflight import PRIVATE, safe_private
    path = PRIVATE / 'ledger.json'
    safe_private(path)
    ledger = json.loads(path.read_text())
    owner = os.environ.get('SESSION_ID')
    day = dt.datetime.now(ZoneInfo('Australia/Perth')).date().isoformat()
    entry = ledger.get('days', {}).get(day, {})
    if ledger.get('schema') != 1 or not owner or entry.get('owner') != owner or entry.get('status') != 'active':
        raise ValueError('Nightly API mutation requires this session’s active Perth daily claim.')
    if entry.get('recovery_run') and (run is None or entry['recovery_run'] != run.name or action not in ('api-upload', 'api-readback')):
        raise ValueError('Recovered claim authorizes only exact retained-run upload/readback.')


def local_states(r):
    from nightly_testflight import safe_private
    for path in r.PRIVATE.glob('*/state.json'):
        safe_private(path)
        yield path, r.read(path)


def delivery_barrier(r, run, client):
    for path, s in local_states(r):
        if path.parent != run and s.get('stage') in PENDING:
            r.require(client.local_reconciled(path), 'Local pending delivery blocks new uploads; reconcile exact run first.')


def reserve(r, run, client):
    h = client.preflight()
    r.require(not h['pending_upload_ids'] and not h.get('pending_build_ids'), 'Apple upload history has unresolved deliveries; reconcile before new release.')
    local = []
    for path, s in local_states(r):
        local.append(s['build'])
        r.require(s.get('stage') not in PENDING or client.local_reconciled(path),
                  'Local pending delivery blocks all new uploads; reconcile exact run first.')
    r.require(not run.exists(), 'Run already reserved; resume without a new upload.')
    version = latest_version(r, h)
    s = {'schema': 1, 'version': version, 'build': max(numbers(h) + local + [0]) + 1,
         'app_id': APP, 'stage': 'initialized', 'audience': 'internal', 'group': r.GROUP, 'api': True}
    run.mkdir(mode=0o700)
    r.write(run / 'state.json', s)
    r.write(run / 'api-preflight.json', h)
    return s


def snapshot(r, repo, target):
    r.require(r.command(['git', '-C', repo, 'branch', '--show-current']).decode().strip() == 'main', 'Snapshot requires main.')
    r.require(not r.command(['git', '-C', repo, 'status', '--porcelain']), 'Commit compatible source before snapshot.')
    commit = r.command(['git', '-C', repo, 'rev-parse', 'HEAD']).decode().strip()
    target.mkdir(mode=0o700)
    tar = target.parent / (target.name + '.tar')
    with tar.open('xb') as stream:
        subprocess.run(['git', '-C', str(repo), 'archive', commit], stdout=stream, check=True)
    subprocess.run(['tar', '-xf', str(tar), '-C', str(target)], check=True)
    r.require(r.command(['git', '-C', repo, 'rev-parse', 'HEAD']).decode().strip() == commit and
              not r.command(['git', '-C', repo, 'status', '--porcelain']), 'Source changed during snapshot; preserve and stop.')
    return commit


def execute(r, a, run):
    r.require(not getattr(a, 'dry_run', False), '--dry-run is not supported for API actions; use api-preflight or read-only readback.')
    client = Client(a.auth_reference)
    if a.action == 'api-preflight':
        h = client.preflight()
        print(json.dumps({'auth_ready': h['auth_ready'], 'history_complete': True,
                          'builds': numbers(h), 'pending_upload_ids': h['pending_upload_ids'],
                          'audience': h['audience'], 'upload_performed': False}, indent=2))
        return
    if a.action in ('api-reserve', 'api-build', 'api-upload') or (
            a.action == 'api-readback' and not getattr(a, 'read_only', False)):
        require_daily_claim(run, a.action)
    if a.action == 'api-reserve':
        print(json.dumps(reserve(r, run, client), indent=2))
        return
    r.options(); r.project_settings()
    s = r.read(run / 'state.json')
    r.require(s.get('api') and s['app_id'] == APP and r.release_audience(s) == 'internal', 'API actions require exact private API run.')
    state = run / 'state.json'
    if a.action == 'api-recover-export':
        from testflight_export_recovery import recover
        recover(r, client, run, s, a)
        return
    if a.action == 'api-build':
        r.require(s['stage'] == 'initialized', 'Build already attempted; preserve evidence.')
        r.require(os.environ.get('FLIGHT_DECK_PG_APP_NPUB'), 'Verified FLIGHT_DECK_PG_APP_NPUB required.')
        h = client.preflight()
        reservation_gate(r, h, s)
        delivery_barrier(r, run, client)
        s['stage'] = 'building'; r.write(state, s)
        # Flight Deck is built first from the exact committed snapshot.
        fd = run / 'flightdeck'; wm = run / 'wmapp'
        s['flightdeck_commit'] = snapshot(r, a.flightdeck, fd)
        meta = json.loads((fd / '.build-meta.json').read_text())
        notes = json.loads((fd / 'release-notes.json').read_text())
        number = max([meta['absoluteVersion']] + [x['buildNumber'] for x in notes['releases']])
        env = os.environ.copy()
        env.update(FLIGHTDECK_BUILD_NUMBER=str(number), FLIGHTDECK_BUILD_ID='wmapp-' + s['flightdeck_commit'][:12] + '-' + str(number),
                   SOURCE_DATE_EPOCH=r.command(['git', '-C', a.flightdeck, 'log', '-1', '--format=%ct']).decode().strip(), FLIGHT_DECK_DIR=str(fd))
        def logged(args, cwd, label):
            with (run / (label + '.log')).open('xb') as stream:
                p = subprocess.run([str(x) for x in args], cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
            r.require(p.returncode == 0, label + ' failed; inspect private log. No automatic retry.')
        logged(['bun', 'install', '--frozen-lockfile'], fd, 'fd-install')
        logged(['bun', 'run', 'build'], fd, 'fd-build')
        logged(['bun', 'run', 'verify:dist'], fd, 'fd-verify')
        s['flightdeck_version'] = json.loads((fd / 'dist/version.json').read_text())
        r.require(s['flightdeck_version']['buildId'] == env['FLIGHTDECK_BUILD_ID'], 'Flight Deck build ID mismatch.')
        s['flightdeck_assets'] = r.tree_hash(fd / 'dist')
        s['source_commit'] = snapshot(r, r.ROOT, wm)
        s['export_policy_sha256'] = r.digest(r.options())
        r.write(state, s)
        logged([wm / 'tools/ios/build_core.sh'], wm, 'core')
        logged([wm / 'tools/update_flightdeck_bundle.sh', '--use-existing-dist'], wm, 'bundle')
        r.require(r.tree_hash(wm / 'app/assets/flightdeck') == s['flightdeck_assets'], 'Bundled Flight Deck differs from verified dist.')
        logged(['flutter', 'build', 'ios', '--release', '--no-codesign', '--build-name=' + s['version'], '--build-number=' + str(s['build'])], wm / 'app', 'flutter')
        logged(['xcodebuild', '-workspace', wm / 'app/ios/Runner.xcworkspace', '-scheme', 'Runner', '-configuration', 'Release',
                '-destination', 'generic/platform=iOS', '-archivePath', run / 'Runner.xcarchive', *client.xcode_args(), 'archive'], wm / 'app', 'archive')
        s['archive_hashes'] = r.tree_hash(run / 'Runner.xcarchive')
        r.signed_app(run / 'Runner.xcarchive/Products/Applications/Runner.app', s, False)
        s['stage'] = 'archived'; s['export_started_ns'] = time.time_ns(); r.write(state, s)
        logged(['xcodebuild', '-exportArchive', '-archivePath', run / 'Runner.xcarchive', '-exportPath', run / 'export',
                '-exportOptionsPlist', r.options(), *client.xcode_args()], wm, 'export')
        s['artifact'] = r.validate_artifacts(run, s); s['stage'] = 'exported'; r.write(state, s)
    elif a.action == 'api-upload':
        r.require(s['stage'] == 'exported', 'Upload attempted already; readback only, never retry.')
        h = client.preflight()
        recovered = (run / 'export-recovery.json').exists()
        if recovered:
            from testflight_export_recovery import upload_gate
            upload_command = upload_gate(r, client, run, s, h)
        else:
            reservation_gate(r, h, s)
        delivery_barrier(r, run, client)
        r.no_other_delivery(run, s)
        r.require(r.validate_artifacts(run, s) == s['artifact'], 'Artifact changed.')
        p = plistlib.loads(r.options().read_bytes()); p['destination'] = 'upload'
        policy = run / 'UploadOptions.plist'
        r.require(not policy.exists() and not policy.is_symlink(), 'Upload policy exists; preserve and reconcile.')
        policy.write_bytes(plistlib.dumps(p)); os.chmod(policy, 0o600)
        s['stage'] = 'upload_pending'; r.write(state, s)
        # Existing helper's durable barrier and validated archive; API authentication only.
        r.logged(upload_command if recovered else ['xcodebuild', '-exportArchive', '-archivePath', run / 'Runner.xcarchive', '-exportPath', run / 'upload-output',
                  '-exportOptionsPlist', policy, *client.xcode_args()], run, 'upload')
        s['upload_command_completed_at'] = r.now(); r.write(state, s)
    elif a.action == 'api-readback':
        r.require(s['stage'] in ('upload_pending', 'api_processing', 'api_upload_uncertain', 'api_action_required', 'api_assigned_ready', 'api_testing', 'api_failed_processing'), 'Upload intent required.')
        deadline = time.monotonic() + a.poll_seconds
        while True:
            result = client.readback(s['version'], s['build'], assign=not getattr(a, 'read_only', False))
            stages = {'upload_pending': 'api_upload_uncertain', 'uploaded_processing': 'api_processing',
                      'uploaded_action_required': 'api_action_required', 'api_testing': 'api_testing',
                      'processed_awaiting_tester': 'api_assigned_ready'}
            s['stage'] = stages[result['stage']]; s['api_readback'] = result; r.write(state, s)
            if result['stage'] not in ('uploaded_processing', 'upload_pending', 'processed_awaiting_tester') or time.monotonic() >= deadline:
                break
            time.sleep(min(30, max(0, deadline - time.monotonic())))
        print(json.dumps(result, indent=2))

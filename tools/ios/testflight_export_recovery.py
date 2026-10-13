"""Fail-closed recovery of a reservation created by a successful local Xcode export."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile
import plistlib

from appstore_connect import APP, BUNDLE, owner_file, require


def export_proof(r, run, s, logs):
    from nightly_testflight import safe_private
    require(s.get('stage') == 'exported' and s.get('api') is True and s.get('app_id') == APP,
            'Recovery requires an exported private API run, never attempted delivery.')
    require(not any((run / name).exists() or (run / name).is_symlink() for name in ('upload.log', 'UploadOptions.plist', 'upload-output')) and
            not list(run.glob('upload-*.log')) and
            not any(k.startswith('upload_') for k in s), 'Delivery intent/evidence exists; readback only.')
    safe_private(logs)
    export = owner_file(run / 'export.log').read_text()
    require('** EXPORT SUCCEEDED **' in export, 'Successful export evidence required.')
    # Preserve the original native bundle; its basename must match this run’s export log.
    match = re.findall(r'Created bundle at path "([^"\n]+\.xcdistributionlogs)"', export)
    require(len(match) == 1 and Path(match[0]).name == logs.name, 'Distribution log is not this run’s export.')
    standard = owner_file(logs / 'IDEDistribution.standard.log').read_text()
    options = re.findall(r'Starting export with options: (\{[^\n]+\})', standard)
    require(len(options) == 1, 'Ambiguous export policy evidence.')
    p = json.loads(options[0])
    require(p.get('destination') == 'export' and p.get('method') == 'app-store-connect' and
            p.get('teamID') == r.TEAM and p.get('testFlightInternalTestingOnly') is True and
            p.get('manageAppVersionAndBuildNumber') is False, 'Native export policy drift.')
    content = owner_file(logs / 'ContentDelivery.log').read_text()
    require(content.count('CREATE BUILD (ASSET_UPLOAD) REQUEST:') == 1 and
            content.count('CREATE BUILD (ASSET_UPLOAD) RESPONSE:') == 1 and
            content.count('httpBody:') == 2 and 'status code: 201 (created)' in content,
            'Expected exactly one native reservation creation, no delivery operations.')
    decoder = json.JSONDecoder()
    bodies = [decoder.raw_decode(content[pos.end():].lstrip())[0]
              for pos in re.finditer('httpBody:', content)]
    request, response = [b['data'] for b in bodies]
    require(request == {'attributes': {'cfBundleShortVersionString': s['version'],
                'cfBundleVersion': str(s['build']), 'platform': 'IOS'},
                'relationships': {'app': {'data': {'id': APP, 'type': 'apps'}}}, 'type': 'builds'},
            'Native reservation app/version/build mismatch.')
    ident = response['id']
    require(re.fullmatch(r'[a-f0-9-]{36}', ident) and response['type'] == 'builds' and
            response['attributes']['version'] == str(s['build']) and
            all(response['attributes'].get(k) is None for k in
                ('uploadedDate', 'processingState', 'processingErrors', 'buildProcessingState')),
            'Native reservation already has delivery/processing evidence.')
    received = re.findall(r'Received build ID: ([a-f0-9-]+)', content)
    require(received == [ident] and content.rstrip().endswith('Received build ID: ' + ident),
            'Native export log has uncertain or subsequent activity.')
    require(r.validate_artifacts(run, s) == s['artifact'], 'Retained artifact changed.')
    with zipfile.ZipFile(s['artifact']['ipa']) as z:
        info = plistlib.loads(z.read('Payload/Runner.app/Info.plist'))
    require(info.get('TFInternalTestingOnly') is True and info.get('CFBundleIdentifier') == BUNDLE and
            info.get('CFBundleVersion') == str(s['build']) and
            info.get('CFBundleShortVersionString') == s['version'], 'Signed IPA private identity drift.')
    before = r.read(run / 'api-preflight.json')
    require(before.get('history_complete') is True and not before.get('pending_upload_ids') and
            not before.get('pending_build_ids') and not any(u['id'] == ident or
                int(u['attributes']['cfBundleVersion']) >= s['build'] for u in before['uploads']) and
            not any(int(b['attributes']['version']) >= s['build'] for b in before['builds']),
            'Reservation was already present before this run or preflight incomplete.')
    return {'upload_id': ident, 'logs': str(logs), 'log_hashes':
            {name: r.digest(logs / name) for name in ('ContentDelivery.log', 'IDEDistribution.standard.log')},
            'export_log_sha256': r.digest(run / 'export.log'),
            'preflight_sha256': r.digest(run / 'api-preflight.json'), 'ipa_sha256': s['artifact']['sha256']}


def recovery_history(r, client, h, s, proof):
    ident = proof['upload_id']
    matches = [u for u in h['uploads'] if u['id'] == ident]
    require(len(matches) == 1, 'Exact export reservation absent or ambiguous.')
    a = matches[0]['attributes']
    require(a['platform'] == 'IOS' and a['cfBundleVersion'] == str(s['build']) and
            a['cfBundleShortVersionString'] == s['version'] and
            a['state']['state'] == 'AWAITING_UPLOAD' and a['state']['errors'] == [] and
            not a['state'].get('warnings') and not a['state'].get('infos') and a['uploadedDate'] is None,
            'Export reservation now has delivery evidence or identity drift.')
    created = dt.datetime.fromisoformat(a['createdDate'].replace('Z', '+00:00'))
    require(created.tzinfo is not None and created.timestamp() >= s['export_started_ns'] / 1e9 and
            created.timestamp() <= Path(proof['logs']).joinpath('ContentDelivery.log').stat().st_mtime,
            'Reservation creation is outside this export.')
    require(not client.all(f'/v1/buildUploads/{ident}/buildUploadFiles?limit=200'),
            'Export reservation has upload files; uncertain delivery, readback only.')
    require(h['pending_upload_ids'] == [ident] and not h.get('pending_build_ids'),
            'Unrelated pending delivery blocks recovery.')
    require(not any(int(b['attributes']['version']) == s['build'] for b in h['builds']),
            'Exact build already exists; readback only.')
    filtered = dict(h, pending_upload_ids=[], uploads=[u for u in h['uploads'] if u['id'] != ident])
    from testflight_api_release import reservation_gate
    reservation_gate(r, filtered, s)
    return {'id': ident, 'version': s['version'], 'build': s['build'], 'created_at': a['createdDate']}


def stopped_session(owner):
    # Supported read-only runtime route; do not infer stopped from an old comment.
    repo = Path(__file__).resolve().parents[3] / 'autopilot'
    result = subprocess.run(['bun', 'clis/sessions.ts', 'archive-info', owner, '--json'],
                            cwd=repo, capture_output=True, text=True, check=True)
    session = json.loads(result.stdout)['session']
    require(session['id'] == owner and bool(session.get('archivedAt')) and
            session.get('workingDirectory') == str(Path(__file__).resolve().parents[2]),
            'Prior claim owner is not verifiably archived.')
    return {'id': owner, 'archived_at': session['archivedAt']}


def recover(r, client, run, s, a):
    from nightly_testflight import PRIVATE, recover_claim, safe_private
    safe_private(PRIVATE / 'ledger.json')
    safe_private(run / 'export-recovery.json')
    require(a.export_logs and a.previous_owner, 'Recovery requires retained export logs and previous owner.')
    require(not (run / 'export-recovery.json').exists(), 'Recovery already recorded; resume upload/readback.')
    proof = export_proof(r, run, s, a.export_logs)
    h = client.preflight()
    proof['reservation'] = recovery_history(r, client, h, s, proof)
    from testflight_api_release import delivery_barrier
    delivery_barrier(r, run, client); r.no_other_delivery(run, s)
    proof['stopped_session'] = stopped_session(a.previous_owner)
    proof.update(schema=1, app_id=APP, basis='same_run_native_export_reservation',
                 run=run.name, state_sha256=r.digest(run / 'state.json'), observed_at=r.now())
    # Record proof first; an interrupted claim handoff must be reconciled, never retried blindly.
    r.write(run / 'export-recovery.json', proof)
    recover_claim(PRIVATE, os.environ.get('SESSION_ID'), a.previous_owner, run.name,
                  proof['state_sha256'])
    print(json.dumps({'recovered_run': run.name, 'upload_id': proof['upload_id'],
                      'upload_performed': False}, indent=2))


def upload_gate(r, client, run, s, h):
    proof = r.read(run / 'export-recovery.json')
    require(proof.get('schema') == 1 and proof.get('app_id') == APP and
            proof.get('basis') == 'same_run_native_export_reservation' and proof.get('run') == run.name and
            r.digest(run / 'state.json') == proof['state_sha256'], 'Recovery state/proof drift.')
    fresh = export_proof(r, run, s, Path(proof['logs']))
    require(all(proof.get(k) == v for k, v in fresh.items()), 'Retained native proof changed.')
    require(recovery_history(r, client, h, s, proof) == proof['reservation'], 'Apple reservation pin drift.')
    return ['xcrun', 'altool', '--upload-package', s['artifact']['ipa'], '--platform', 'ios',
            '--apple-id', APP, '--bundle-id', BUNDLE, '--bundle-version', str(s['build']),
            '--bundle-short-version-string', s['version'], *client.altool_args()]

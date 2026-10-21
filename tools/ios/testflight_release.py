#!/usr/bin/env python3
"""Resumable local automation with explicit Apple UI observations and separate internal/external policies."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PRIVATE = ROOT / 'tmp/docs/handoffs/testflight'
TEAM = os.environ.get('WMAPP_APPLE_TEAM', '')
BUNDLE = 'com.wingmanbefree.wingmanApp'
SOURCE_REPOSITORY = 'https://github.com/humansinstitute/nostr-browser.git'
GROUP = os.environ.get('WMAPP_TESTFLIGHT_PRIVATE_GROUP', 'Private Internal')
OPTIONS = ROOT / 'docs/deploy/TestFlightExportOptions.plist'
EXTERNAL_OPTIONS = ROOT / 'docs/deploy/TestFlightExternalExportOptions.plist'
ACCOUNT_HELP = ('CLI No Accounts does not mean Xcode is signed out. Check Xcode → Settings → '
                'Apple Accounts for the existing account and the configured existing Apple team. If present, open '
                'this run’s Runner.xcarchive in Organizer → Distribute App → Custom → '
                'App Store Connect → Export; use this run’s audience (internal: enable TestFlight internal '
                'testing only; external: disable it), disable '
                'Manage version and build number, use automatic signing, export into this run’s '
                'export directory. Only reauthenticate if Apple’s UI explicitly requires it. '
                'If Keychain prompts for codesign, enter the password in that visible dialog '
                'and choose Allow (or Always Allow at your discretion). Never revoke certificates.')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    # Atomic state writes; locking is held across the entire command.
    temp = path.with_suffix('.new')
    require(not path.is_symlink() and not temp.is_symlink(), 'State cannot use symlinks.')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    os.chmod(temp, 0o600)
    temp.replace(path)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def fresh(observation):
    observed = dt.datetime.fromisoformat(observation['observed_at'])
    age = (dt.datetime.now(dt.timezone.utc) - observed).total_seconds()
    require(0 <= age <= 86400, 'Apple UI observation must be timezone-aware and within 24 hours; refresh it.')


def audience(o):
    require(o['group'] == GROUP and o['internal'] is True and
            o['tester_count'] == 1 and o['sole_tester_is_owner'] is True and
            o['public_link'] is False and o['other_distribution_groups'] == [],
            'Audience mismatch: verify Private Internal, only Owner, no public link or other distribution groups.')


def release_audience(s):
    mode = s.get('audience', 'internal')  # Existing schema-1 private runs stay private.
    require(mode in ('internal', 'external'), 'Unknown release audience.')
    return mode


def external_audience(o, s, before_upload=False):
    require(o['group'] == s['group'] and o['internal'] is False,
            'External group must match this run and must not be internal.')
    # Preserve the private group independently of the authorized external audience.
    private = o['private_group']
    require(private['group'] == GROUP and private['internal'] is True and
            private['tester_count'] == 1 and private['sole_tester_is_owner'] is True and
            private['settings_unchanged'] is True, 'Private Internal membership/settings changed.')
    require(o['other_distribution_groups'] == [], 'Unexpected additional distribution groups.')
    if s.get('external_group_id'):
        require(o['external_group_id'] == s['external_group_id'], 'External group ID changed.')
    if before_upload:
        require(o['public_link'] is False, 'Keep the public link disabled until the build is approved.')


def preflight(o, s):
    fresh(o)
    require(o['xcode_gui_account_present'] is True, 'Verify the existing account in Xcode Apple Accounts.')
    require(o['team'] == TEAM, 'Wrong Apple team.')
    require(o['bundle'] == BUNDLE and str(o['app_id']).isdigit(), 'Wrong bundle or missing App Store Connect app ID.')
    if release_audience(s) == 'external':
        external_audience(o, s, before_upload=True)
    else:
        audience(o)
    require(o['history_complete'] is True, 'Read all iOS build history, including processing uploads.')
    builds = o['existing_builds']
    require(isinstance(builds, list) and all(type(b) is int and b > 0 for b in builds), 'Invalid build history.')
    require(s['build'] > max(builds, default=0), 'Duplicate/non-increasing build number; choose a higher build and rebuild.')
    require(o['latest_version'] and version(s['version']) >= version(o['latest_version']), 'Version is older than Apple history.')
    if release_audience(s) == 'external':
        require(version(s['version']) > version(o['latest_version']), 'External release needs a newer version than Apple history.')
    require(o['automatic_distribution_reviewed'] is True, 'Review all groups’ automatic distribution settings before upload.')


def version(value):
    require(isinstance(value, str), 'Version must be x.y.z.')
    require(bool(re.fullmatch(r'\d+\.\d+\.\d+', value)), 'Version must be x.y.z.')
    return tuple(map(int, value.split('.')))


def options(mode='internal'):
    require(mode in ('internal', 'external'), 'Unknown export audience.')
    require(bool(re.fullmatch(r'[A-Z0-9]{10}', TEAM)), 'Verified WMAPP_APPLE_TEAM required.')
    path = EXTERNAL_OPTIONS if mode == 'external' else OPTIONS
    p = plistlib.loads(path.read_bytes())
    require(p.get('teamID') in ('', TEAM) and p.get('destination') == 'export' and
            p.get('method') == 'app-store-connect' and p.get('signingStyle') == 'automatic' and
            p.get('testFlightInternalTestingOnly') is (mode == 'internal') and
            p.get('manageAppVersionAndBuildNumber') is False, 'Unsafe TestFlight export options.')
    if p.get('teamID') == '':
        from configure_apple_signing import configure
        configure(TEAM, ROOT)
        p['teamID'] = TEAM
        path = ROOT / 'tmp/docs/handoffs/apple-signing' / (mode + '-ExportOptions.plist')
        require(not path.is_symlink(), 'Unsafe local export policy.')
        path.write_bytes(plistlib.dumps(p))
        path.chmod(0o600)
    return path


def project_settings():
    text = (ROOT / 'app/ios/Runner.xcodeproj/project.pbxproj').read_text()
    teams = set(re.findall(r'DEVELOPMENT_TEAM = ([^;]+);', text))
    bundles = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', text))
    require(teams == {'""'}, 'Project must use local Apple signing configuration.')
    from configure_apple_signing import configure
    os.environ['XCODE_XCCONFIG_FILE'] = str(configure(TEAM, ROOT))
    require(bundles == {BUNDLE, BUNDLE + '.FipsPacketTunnel', BUNDLE + '.RunnerTests'},
            'Project bundle mismatch.')


def command(args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.PIPE)


def profile_check(info, profile, ent, s, bundle, distribution=True):
    require(info['CFBundleIdentifier'] == bundle, 'Signed bundle mismatch.')
    require(info['CFBundleShortVersionString'] == s['version'] and str(info['CFBundleVersion']) == str(s['build']), 'Signed version/build mismatch; stale artifact.')
    require(info.get('NBrowserSourceCommit') == s.get('source_commit') and
            info.get('NBrowserSourceRepository') == SOURCE_REPOSITORY,
            'Signed bundle lacks exact canonical NBrowser source provenance.')
    require(profile['TeamIdentifier'] == [TEAM] and ent.get('com.apple.developer.team-identifier') == TEAM, 'Signed team mismatch.')
    require(profile['ExpirationDate'].replace(tzinfo=dt.timezone.utc) > dt.datetime.now(dt.timezone.utc), 'Provisioning profile expired.')
    pe = profile['Entitlements']
    for e in (pe, ent):
        require(e.get('application-identifier') == TEAM + '.' + bundle, 'Provisioning application identifier mismatch.')
        require('packet-tunnel-provider' in e.get('com.apple.developer.networking.networkextension', []), 'Missing packet tunnel entitlement.')
    if distribution:
        require('ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices', False) and
                pe.get('get-task-allow') is False and ent.get('get-task-allow') is False and
                pe.get('beta-reports-active') is True, 'Expected App Store distribution profiles for both targets.')


def signed_app(app, s, distribution):
    require(app.is_dir(), 'Missing Runner.app.')
    command(['codesign', '--verify', '--deep', '--strict', app])
    hashes = {}
    for path, bundle in [(app, BUNDLE), (app / 'PlugIns/FipsPacketTunnel.appex', BUNDLE + '.FipsPacketTunnel')]:
        command(['codesign', '--verify', '--strict', path])
        details = subprocess.run(['codesign', '-dvv', str(path)], capture_output=True, check=True).stderr.decode()
        require('TeamIdentifier=' + TEAM in details.splitlines(), 'Code signature team mismatch.')
        if distribution:
            require(any(line.startswith(('Authority=Apple Distribution:', 'Authority=iPhone Distribution:'))
                        for line in details.splitlines()), 'Expected an Apple iOS distribution signing certificate.')
        info = plistlib.loads((path / 'Info.plist').read_bytes())
        profile = plistlib.loads(command(['security', 'cms', '-D', '-i', path / 'embedded.mobileprovision']))
        ent = plistlib.loads(command(['codesign', '-d', '--entitlements', ':-', path]))
        profile_check(info, profile, ent, s, bundle, distribution)
        hashes[bundle] = digest(path / info['CFBundleExecutable'])
    return hashes


def tree_hash(path):
    return {str(p.relative_to(path)): digest(p) for p in path.rglob('*') if p.is_file()}


def validate_artifacts(run, s):
    policy = options(release_audience(s))
    if s.get('export_policy_sha256'):
        require(digest(policy) == s['export_policy_sha256'], 'Export policy changed since build.')
    archive = run / 'Runner.xcarchive'
    require(archive.is_dir(), 'No run archive; build first.')
    require(tree_hash(archive) == s.get('archive_hashes'), 'Archive changed; preserve evidence and start a new run.')
    signed_app(archive / 'Products/Applications/Runner.app', s, False)
    ipas = list((run / 'export').glob('*.ipa'))
    require(len(ipas) == 1, 'Expected exactly one newly exported IPA in this run’s export directory.')
    ipa = ipas[0]
    require(ipa.stat().st_mtime_ns >= s['export_started_ns'], 'Stale IPA: predates this run’s export attempt.')
    with tempfile.TemporaryDirectory(dir=run) as temp:
        # ditto preserves the signed bundle’s symlinks and metadata on macOS.
        command(['ditto', '-x', '-k', ipa, temp])
        apps = list((Path(temp) / 'Payload').glob('*.app'))
        require(len(apps) == 1, 'Expected exactly one IPA application.')
        hashes = signed_app(apps[0], s, True)
    return {'ipa': str(ipa), 'sha256': digest(ipa), 'executables': hashes}


def preserve_outputs(run):
    for name in ('archive', 'ipa'):
        source = ROOT / 'app/build/ios' / name
        if source.exists():
            hashes = tree_hash(source)
            backup = run / ('previous-' + name)
            require(not backup.exists(), 'Previous output backup exists; do not overwrite it.')
            shutil.move(str(source), backup)
            require(tree_hash(backup) == hashes, 'Backup hash mismatch.')
            write(run / ('previous-' + name + '-hashes.json'), hashes)


def logged(args, run, label):
    # Preserve each retry separately; never publish private build/signing logs.
    log = run / (label + '-' + str(time.time_ns()) + '.log')
    print('Running', args[0], '; private log:', log, flush=True)
    with log.open('wb') as stream:
        result = subprocess.run([str(a) for a in args], stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        if 'No Accounts' in log.read_text(errors='replace'):
            print(ACCOUNT_HELP)
        if label == 'upload':
            raise ValueError('Upload outcome uncertain; inspect private log and Apple history before any Organizer fallback. Do not retry upload.')
        raise ValueError('Command failed; inspect private log. No upload was performed.')


def readback(o, s):
    fresh(o)
    require(o['app_id'] == s['app_id'] and o['bundle'] == BUNDLE and o['team'] == TEAM and
            o['version'] == s['version'] and o['build'] == s['build'], 'Readback refers to another app/team/build.')
    require(o['receipt_or_build_id'], 'Record Apple upload receipt or exact build ID; IPA alone is not upload evidence.')
    if o['processing'] != 'complete':
        return 'uploaded_processing' if o['processing'] == 'processing' else 'uploaded_action_required'
    if o['encryption_compliance'] != 'complete':
        return 'uploaded_action_required'
    if release_audience(s) == 'external':
        require(o['internal_only'] is False, 'Apple build is Internal Only; rebuild for external testing.')
        external_audience(o, s)
        review = o['beta_review_status']
        require(review in ('not_submitted', 'waiting_for_review', 'in_review', 'approved', 'rejected',
                           'action_required'), 'Unknown Beta App Review status.')
        require(o['public_link'] is False or review == 'approved', 'Do not enable the public link before approval.')
        if review == 'not_submitted':
            return 'processed_awaiting_review'
        require(o['assigned_to_group'] is True and o['external_group_id'],
                'Submitted build must be assigned to the exact external group.')
        require(o['review_submission_id'] and o['test_metadata_complete'] is True,
                'Record the Beta App Review submission and complete test metadata.')
        if review in ('waiting_for_review', 'in_review'):
            return 'beta_review_pending'
        if review in ('rejected', 'action_required'):
            return 'beta_review_action_required'
        if o['public_link'] is not True:
            return 'approved_awaiting_public_link'
        require(o['assigned_to_group'] is True and o['external_group_id'],
                'Read back the exact build assignment to the external group.')
        require(o['invitation_access'] == 'Open to Anyone' and o['tester_criteria'] == [] and
                o['custom_tester_limit'] is None, 'Public link must be Open to Anyone with Apple defaults.')
        require(isinstance(o['public_link_url'], str) and
                re.fullmatch(r'https://testflight\.apple\.com/join/[A-Za-z0-9]+', o['public_link_url']),
                'Invalid TestFlight public invitation URL.')
        if o['build_testing_status'] != 'Testing' or o['public_landing_accepting'] is not True:
            return 'approved_awaiting_public_link'
        return 'ready_for_external_testing'
    audience(o)
    require(o['assigned_to_group'] is True and o['internal_only'] is True, 'Exact build must be assigned to the private internal group.')
    return 'ready_to_test' if o['owner_sees_exact_build'] is True else 'processed_awaiting_tester'


def template(s=None):
    result = {'observed_at': None, 'xcode_gui_account_present': None, 'team': TEAM,
            'bundle': BUNDLE, 'app_id': None, 'latest_version': None, 'existing_builds': None,
            'history_complete': None, 'group': GROUP, 'internal': None, 'tester_count': None,
            'sole_tester_is_owner': None, 'public_link': None, 'other_distribution_groups': None,
            'automatic_distribution_reviewed': None}
    if s and release_audience(s) == 'external':
        for field in ('tester_count', 'sole_tester_is_owner'):
            result.pop(field)
        result.update(group=s['group'], internal=False, external_group_id=None,
                      private_group={'group': GROUP, 'internal': True, 'tester_count': None,
                                     'sole_tester_is_owner': None, 'settings_unchanged': None})
    return result


def no_other_delivery(run, s):
    for path in PRIVATE.glob('*/state.json'):
        if path.parent == run:
            continue
        other = read(path)
        if other.get('app_id') == s['app_id'] and other.get('build') == s['build']:
            require(other.get('stage') in ('initialized', 'building', 'archived', 'exported'),
                    'Another run has pending/recorded delivery of this app/build; reconcile its Apple evidence first.')


def execute(a, run):
    state = run / 'state.json'
    if a.action.startswith('api-'):
        from testflight_api_release import execute as api_execute
        api_execute(sys.modules[__name__], a, run)
        return
    if a.action == 'init':
        require(not run.exists(), 'Run exists; resume it rather than overwriting.')
        version(a.version)
        require(a.build and a.build > 0, 'Build must be a positive integer.')
        mode = getattr(a, 'audience', 'internal')
        require(mode in ('internal', 'external'), 'Unknown release audience.')
        group = getattr(a, 'group', None)
        require((mode == 'internal' and group is None) or
                (mode == 'external' and isinstance(group, str) and group.strip() == group and
                 bool(group) and group != GROUP), 'External init requires a distinct --group; internal uses Private Internal.')
        s = {'schema': 1, 'version': a.version, 'build': a.build, 'stage': 'initialized',
             'audience': mode, 'group': group if mode == 'external' else GROUP}
        run.mkdir(mode=0o700)
        write(state, s)
        write(run / 'preflight.json', template(s))
        print('Fill preflight.json with fresh human observations; see docs/deploy/testflight.md.')
        return
    s = read(state)
    require(s['schema'] == 1, 'Unsupported release state schema.')
    if a.action == 'status':
        display = json.loads(json.dumps(s))
        if release_audience(s) == 'external' and s['stage'] != 'ready_for_external_testing':
            if display.get('apple_readback'):
                display['apple_readback']['public_link_url'] = None
        print(json.dumps(display, indent=2))
        return
    policy = options(release_audience(s))
    project_settings()
    if a.action == 'run':
        o = read(run / 'preflight.json')
        preflight(o, s)
        require(s['stage'] in ('initialized', 'archived', 'exported'), 'Use status/readback; do not rebuild or re-upload this run.')
        require(not s.get('app_id') or o['app_id'] == s['app_id'], 'App Store Connect app changed since preflight.')
        if a.dry_run:
            print('Dry-run passed: GUI account/team and human Apple history/audience observations accepted.\n'
                  'Plan: preserve prior outputs → build → validate archive and IPA → Organizer upload → Apple readback.\n'
                  'No build, signing, upload or release-state changes performed.')
            return
        require(sys.platform == 'darwin' and shutil.which('flutter'), 'macOS, Xcode and Flutter are required.')
        command(['xcodebuild', '-version'])
        s['app_id'] = o['app_id']
        if release_audience(s) == 'external' and o.get('external_group_id'):
            s['external_group_id'] = o['external_group_id']
        if s['stage'] == 'initialized':
            require(not (run / 'previous-archive').exists() and not (run / 'Runner.xcarchive').exists(),
                    'Interrupted build: preserve outputs; start a new run to rebuild.')
            # Persist barrier before overwriting the shared Flutter output location.
            s['source_commit'] = command(['git', '-C', ROOT, 'rev-parse', 'HEAD']).decode().strip()
            s['source_diff_sha256'] = hashlib.sha256(command(['git', '-C', ROOT, 'diff', 'HEAD', '--binary'])).hexdigest()
            s['export_policy_sha256'] = digest(policy)
            s['stage'] = 'building'
            s['build_started_ns'] = time.time_ns()
            write(state, s)
            preserve_outputs(run)
            try:
                args = [ROOT / 'build_ios_testflight.sh', '--build-name=' + s['version'],
                        '--build-number=' + str(s['build'])]
                if release_audience(s) == 'external':
                    args.append('--external')
                logged(args, run, 'build')
            finally:
                source = ROOT / 'app/build/ios/archive/Runner.xcarchive'
                if source.exists() and source.stat().st_mtime_ns >= s['build_started_ns']:
                    original_hashes = tree_hash(source)
                    shutil.copytree(source, run / 'Runner.xcarchive', symlinks=True)
                    s['archive_hashes'] = tree_hash(run / 'Runner.xcarchive')
                    require(s['archive_hashes'] == original_hashes, 'Archive copy hash mismatch.')
                    s['stage'] = 'archived'
                    s['export_started_ns'] = s['build_started_ns']
                    write(state, s)
            ipas = list((ROOT / 'app/build/ios/ipa').glob('*.ipa'))
            require(len(ipas) == 1 and ipas[0].stat().st_mtime_ns >= s['build_started_ns'],
                    'No unique fresh helper IPA. Retained archive can be exported on resume.')
            output = run / 'export'
            output.mkdir()
            shutil.copy2(ipas[0], output / ipas[0].name)
            require(digest(output / ipas[0].name) == digest(ipas[0]), 'IPA copy hash mismatch.')
            s['artifact'] = validate_artifacts(run, s)
            s['stage'] = 'exported'
            write(state, s)
            print('Validated local export only. Next: upload instructions; no release has been uploaded.')
            return
        if s['stage'] == 'archived':
            archive = run / 'Runner.xcarchive'
            require(tree_hash(archive) == s['archive_hashes'], 'Archive changed.')
            signed_app(archive / 'Products/Applications/Runner.app', s, False)
            output = run / 'export'
            require(not output.exists(), 'Export attempt exists; use verify for a GUI export, or preserve/rename export before retrying.')
            output.mkdir()
            s['export_started_ns'] = time.time_ns()
            write(state, s)
            logged(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', output,
                    '-exportOptionsPlist', policy, '-allowProvisioningUpdates'], run, 'export')
        s['artifact'] = validate_artifacts(run, s)
        s['stage'] = 'exported'
        write(state, s)
        print('Validated local export only. Next: upload instructions; no release has been uploaded.')
    elif a.action == 'verify':
        require(s['stage'] in ('archived', 'exported'), 'Build/archive first.')
        s['artifact'] = validate_artifacts(run, s)
        s['stage'] = 'exported'
        write(state, s)
        print('Validated local export only; no upload evidence.')
    elif a.action == 'upload':
        require(s['stage'] == 'exported', 'Upload already pending or performed; inspect status and Apple history, then readback.')
        no_other_delivery(run, s)
        preflight(read(run / 'preflight.json'), s)
        require(read(run / 'preflight.json')['app_id'] == s['app_id'], 'App ID changed.')
        require(validate_artifacts(run, s) == s['artifact'], 'IPA changed since validation.')
        o = template(s)
        o.update({'version': s['version'], 'build': s['build'], 'app_id': s['app_id'],
                  'receipt_or_build_id': None, 'processing': None, 'encryption_compliance': None,
                  'assigned_to_group': None, 'internal_only': None, 'owner_sees_exact_build': None})
        if release_audience(s) == 'external':
            o.update(external_group_id=s.get('external_group_id'), beta_review_status=None,
                     review_submission_id=None, test_metadata_complete=None, build_testing_status=None,
                     invitation_access=None, tester_criteria=None, custom_tester_limit=None,
                     public_link_url=None, public_landing_accepting=None)
        write(run / 'readback.json', o)
        s['stage'] = 'upload_pending'
        write(state, s)
        if getattr(a, 'via', 'organizer') == 'cli':
            upload_options = plistlib.loads(policy.read_bytes())
            upload_options['destination'] = 'upload'
            plist = run / 'UploadOptions.plist'
            plist.write_bytes(plistlib.dumps(upload_options))
            os.chmod(plist, 0o600)
            print('Explicit CLI upload requested. State is upload_pending before contacting Apple.', flush=True)
            logged(['xcodebuild', '-exportArchive', '-archivePath', run / 'Runner.xcarchive',
                    '-exportPath', run / 'upload-output', '-exportOptionsPlist', plist,
                    '-allowProvisioningUpdates'], run, 'upload')
            s['cli_upload_command_completed_at'] = now()
            write(state, s)
            print('CLI upload command completed; delivery/processing/group availability remain unverified. '
                  'Fill readback.json from Apple and run readback. Do not repeat upload.')
            return
        print('Upload pending; Organizer mode does not upload. In Organizer open:', run / 'Runner.xcarchive')
        if release_audience(s) == 'external':
            print('Validate App, then Custom → App Store Connect → Upload. Disable TestFlight internal testing only '
                  'and Manage version and build number. Use the existing account. Record Apple receipt/processing '
                  'and resolve encryption accurately. Preserve Private Internal; assign to the exact external group '
                  + s['group'] + ', complete test metadata and submit Beta App Review. After approval start testing, '
                  'enable Open to Anyone with Apple defaults and read back exact Testing status, group, '
                  'active link and public landing access. Never share a pending link. Do not retry uncertain upload.')
            return
        print('Validate App, then Distribute App → Custom → App Store Connect → Upload.\n'
              'Enable TestFlight internal testing only; disable Manage version and build number.\n'
              'Read back both settings and exact version/build before uploading. Use existing Xcode account.\n'
              'Record receipt/build ID in readback.json. Do not retry an uncertain upload; inspect Apple history first.\n'
              'Wait for processing; resolve encryption using the documented inventory. Add the exact build only to\n'
              'existing Private Internal if necessary; read back one tester (Owner), no other groups/public link.\n'
              'Refresh observed_at, then run readback. Keychain action, if required: ' + ACCOUNT_HELP)
    elif a.action == 'readback':
        require(s['stage'] in ('upload_pending', 'uploaded_processing', 'uploaded_action_required',
                               'processed_awaiting_tester', 'ready_to_test', 'processed_awaiting_review',
                               'beta_review_pending', 'beta_review_action_required',
                               'approved_awaiting_public_link', 'ready_for_external_testing'), 'Record upload intent first; an IPA is not evidence.')
        o = read(run / 'readback.json')
        s['stage'] = readback(o, s)
        if release_audience(s) == 'external' and o.get('external_group_id'):
            s['external_group_id'] = o['external_group_id']
        s['apple_readback'] = o
        write(state, s)
        print('Human Apple UI readback:', s['stage'], '(not an API-verified observation).')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['init', 'run', 'verify', 'upload', 'readback', 'status', 'api-preflight', 'api-reserve', 'api-build', 'api-upload', 'api-readback', 'api-recover-export'])
    p.add_argument('--run', required=True, help='Unique name under ignored tmp/docs/handoffs/testflight')
    p.add_argument('--audience', choices=['internal', 'external'], default='internal',
                   help='Init only: private by default; external requires explicit audience authorization.')
    p.add_argument('--group', help='Init only: exact external group name, distinct from Private Internal.')
    p.add_argument('--version')
    p.add_argument('--build', type=int)
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--via', choices=['organizer', 'cli'], default='organizer',
                   help='Upload route: organizer prints instructions; cli sends a real upload using the existing Xcode account.')
    p.add_argument('--auth-reference', type=Path, default=ROOT / 'tmp/docs/handoffs/nightly-testflight/auth-reference.json')
    p.add_argument('--export-logs', type=Path, help='Recovery only: preserved native export distribution logs.')
    p.add_argument('--previous-owner', help='Recovery only: archived owner of the failed current-day claim.')
    p.add_argument('--flightdeck', type=Path, default=ROOT.parent / 'flightdeck')
    p.add_argument('--read-only', action='store_true', help='API readback only: never assign a group; allows recovery without a daily claim.')
    p.add_argument('--poll-seconds', type=int, default=600)
    a = p.parse_args()
    require(0 <= a.poll_seconds <= 1800, 'Polling must be bounded to 0–1800 seconds.')
    if a.action.startswith('api-'):
        from nightly_testflight import safe_private
        safe_private(PRIVATE)
        safe_private(a.auth_reference)
    require(bool(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', a.run)), 'Use a simple unique run name.')
    require(a.action == 'init' or (a.audience == 'internal' and a.group is None),
            'Audience/group are immutable and can only be selected at init.')
    require(a.action == 'api-recover-export' or (not a.export_logs and not a.previous_owner), 'Recovery options apply only to api-recover-export.')
    require(not a.read_only or a.action == 'api-readback', '--read-only applies only to api-readback.')
    require(not a.dry_run or a.action == 'run', '--dry-run applies only to run.')
    require(a.via != 'cli' or a.action == 'upload', '--via cli applies only to upload.')
    require(not PRIVATE.is_symlink(), 'Private evidence root cannot be a symlink.')
    PRIVATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    run = PRIVATE / a.run
    require(not run.is_symlink(), 'Run cannot be a symlink.')
    if a.action.startswith('api-'):
        safe_private(PRIVATE / '.lock')
        safe_private(run / 'state.json')
        safe_private(run / 'state.new')
    require(not (PRIVATE / '.lock').is_symlink(), 'Release lock cannot be a symlink.')
    # One lock for all runs because Flutter output paths are shared.
    with (PRIVATE / '.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another release command is running; wait for it to finish.')
        execute(a, run)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print('Stopped:', error, file=sys.stderr)
        sys.exit(1)

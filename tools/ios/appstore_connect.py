"""Small scoped Apple client. Keys are read only by the JWT signing function."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://api.appstoreconnect.apple.com'
APP = os.environ.get('WMAPP_APPSTORE_APP_ID', '0000000000')
BUNDLE = 'com.wingmanbefree.wingmanApp'
GROUP = os.environ.get('WMAPP_TESTFLIGHT_PRIVATE_GROUP', 'Private Internal')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def owner_file(path):
    path = Path(path)
    require(not any(p.is_symlink() for p in [path, *path.parents]), 'Credential path contains symlink.')
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
            info.st_mode & 0o077 == 0, 'Credential/config must be owner-only regular files.')
    return path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Apple API redirect rejected.')


class Client:
    def __init__(self, config):
        self.config = json.loads(owner_file(config).read_text())
        c = self.config
        require(c.get('schema') == 1 and re.fullmatch(r'[A-Z0-9]{10}', c.get('key_id', '')) and
                re.fullmatch(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', c.get('issuer_id', '')), 'Invalid credential reference schema.')
        owner_file(c['key_path'])
        self.config_path = Path(config).absolute()
        # Use the host CA bundle explicitly on macOS; verification remains mandatory.
        cafile = os.environ.get('SSL_CERT_FILE') or ('/etc/ssl/cert.pem' if Path('/etc/ssl/cert.pem').is_file() else None)
        self.opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(
            context=ssl.create_default_context(cafile=cafile)))

    def token(self):
        import jwt
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        # No PEM, JWT, HTTP headers or raw Apple errors ever enter logs/state.
        key = serialization.load_pem_private_key(owner_file(self.config['key_path']).read_bytes(), password=None)
        require(isinstance(key, ec.EllipticCurvePrivateKey) and isinstance(key.curve, ec.SECP256R1),
                'Apple requires an ES256 P-256 signing key.')
        issued = int(time.time())
        return jwt.encode({'iss': self.config['issuer_id'], 'iat': issued, 'exp': issued + 600,
                           'aud': 'appstoreconnect-v1'}, key, algorithm='ES256',
                          headers={'kid': self.config['key_id'], 'typ': 'JWT'})

    def xcode_args(self):
        owner_file(self.config['key_path'])
        return ['-allowProvisioningUpdates', '-authenticationKeyPath', self.config['key_path'],
                '-authenticationKeyID', self.config['key_id'],
                '-authenticationKeyIssuerID', self.config['issuer_id']]

    def altool_args(self):
        owner_file(self.config['key_path'])
        return ['--api-key', self.config['key_id'], '--api-issuer', self.config['issuer_id'],
                '--p8-file-path', self.config['key_path']]

    def request(self, path, method='GET', payload=None):
        url = BASE + path if path.startswith('/') else path
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == 'https' and parsed.netloc == 'api.appstoreconnect.apple.com' and
                parsed.path.startswith('/v1/') and not parsed.fragment and not parsed.username and not parsed.password, 'Untrusted Apple API URL.')
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={'Authorization': 'Bearer ' + self.token(),
                                              'Content-Type': 'application/json'})
        try:
            with self.opener.open(req, timeout=45) as response:
                raw = response.read(16 * 1024 * 1024)
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raise ValueError(f'Apple API HTTP {error.code}; no mutation retry. Check role/agreements/service state.') from None
        except (urllib.error.URLError, TimeoutError):
            raise ValueError('Apple API network outcome uncertain; no mutation retry.') from None

    def all(self, path):
        rows, seen = [], set()
        while path:
            require(path not in seen and len(seen) < 10000, 'Invalid/unbounded Apple pagination.')
            seen.add(path)
            page = self.request(path)
            require(isinstance(page.get('data'), list), 'Apple collection response invalid.')
            rows.extend(page['data'])
            path = page.get('links', {}).get('next')
        require(len({r['id'] for r in rows}) == len(rows), 'Duplicate Apple pagination records; refresh history.')
        return rows

    def history(self):
        app = self.request(f'/v1/apps/{APP}')['data']
        require(app['id'] == APP and app['attributes']['bundleId'] == BUNDLE, 'Wrong Apple app/bundle.')
        # No processingState filter: processing builds participate in reservations.
        builds = self.all(f'/v1/builds?filter[app]={APP}&include=preReleaseVersion&limit=200')
        uploads = self.all('/v1/apps/' + APP + '/buildUploads?limit=200')
        versions = self.all(f'/v1/preReleaseVersions?filter[app]={APP}&limit=200')
        version_map = {v['id']: v['attributes'] for v in versions}
        result = []
        for b in builds:
            number = b['attributes']['version']
            require(re.fullmatch(r'[1-9][0-9]*', number), 'Noninteger Apple build number; manual reconciliation needed.')
            related = b['relationships']['preReleaseVersion']['data']['id']
            require(related in version_map, 'Build version absent from complete history.')
            v = version_map[related]
            require(v['platform'] == 'IOS', 'Unexpected build platform.')
            result.append({'id': b['id'], 'build': int(number), 'version': v['version'],
                           'processing': b['attributes']['processingState']})
        pending, inactive = [], []
        rules = self.config.get('inactive_uploads', {})
        for u in uploads:
            a = u['attributes']
            require(a['platform'] == 'IOS', 'Unexpected upload platform.')
            require(re.fullmatch(r'[1-9][0-9]*', a['cfBundleVersion']), 'Invalid upload build number.')
            require(re.fullmatch(r'\d+\.\d+\.\d+', a['cfBundleShortVersionString']), 'Invalid upload version.')
            state = a['state']['state']
            require(state in ('COMPLETE', 'FAILED', 'PROCESSING', 'AWAITING_UPLOAD'), 'Unknown upload state.')
            if state in ('COMPLETE', 'FAILED'):
                continue
            rule = rules.get(u['id'])
            # Never infer abandonment from age, a newer build, or AWAITING_UPLOAD alone.
            # Only exact reviewed legacy reservations with retained evidence qualify.
            if state == 'AWAITING_UPLOAD' and rule:
                evidence = self.evidence(rule)
                expected = {'version': a['cfBundleShortVersionString'], 'build': int(a['cfBundleVersion']),
                            'created_at': a['createdDate']}
                require(all(rule.get(k) == v for k, v in expected.items()), 'Legacy upload pin drift.')
                require(evidence.get('inactive_uploads', {}).get(u['id']) == expected,
                        'Legacy upload lacks exact reviewed evidence.')
                require(a['uploadedDate'] is None and not a['state']['errors'] and
                        not self.all(f'/v1/buildUploads/{u["id"]}/buildUploadFiles?limit=200'),
                        'Legacy reservation now has delivery evidence; reconcile again.')
                inactive.append(u['id'])
            else:
                pending.append(u['id'])
        pending_builds = [b['id'] for b in result if b['processing'] == 'PROCESSING']
        require(all(b['processing'] in ('VALID', 'PROCESSING', 'FAILED', 'INVALID') for b in result), 'Unknown build processing state.')
        return {'pending_build_ids': pending_builds, 'builds': builds, 'uploads': uploads, 'versions': versions, 'history': result,
                'pending_upload_ids': pending, 'inactive_upload_ids': inactive}

    def evidence(self, rule):
        from nightly_testflight import safe_private
        path = Path(rule['evidence_path'])
        safe_private(path)
        raw = owner_file(path).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == rule['evidence_sha256'], 'Reconciliation evidence changed.')
        evidence = json.loads(raw)
        require(evidence.get('schema') == 1 and evidence.get('app_id') == APP and
                evidence.get('basis') == 'reviewed_inactive_legacy_reservations', 'Invalid reconciliation evidence.')
        return evidence

    def local_reconciled(self, path):
        rule = self.config.get('reconciled_local_runs', {}).get(path.parent.name)
        if not rule:
            return False
        raw = owner_file(path).read_bytes()
        state_sha256 = hashlib.sha256(raw).hexdigest()
        require(state_sha256 == rule['state_sha256'], 'Reconciled local state changed.')
        proof = self.evidence(rule)
        cancelled = proof.get('cancelled_local_runs', {}).get(path.parent.name)
        delivered = proof.get('delivered_local_runs', {}).get(path.parent.name)
        if cancelled is not None:
            require(cancelled == state_sha256, 'Missing exact local cancellation evidence.')
        else:
            state = json.loads(raw)
            readback = state.get('api_readback', {})
            expected = {'state_sha256': state_sha256, 'app_id': state.get('app_id'),
                        'version': state.get('version'), 'build': state.get('build'),
                        'stage': state.get('stage'), 'build_id': readback.get('build_id'),
                        'internal_status': readback.get('internal_status')}
            require(state.get('stage') in ('api_action_required', 'api_testing') and
                    isinstance(readback.get('build_id'), str) and delivered == expected,
                    'Missing exact completed-delivery reconciliation evidence.')
        return True

    def audience(self):
        groups = self.all(f'/v1/apps/{APP}/betaGroups?limit=200')
        require(len(groups) == 1, 'Unexpected app audience: require only existing Private Internal group.')
        g = groups[0]
        a = g['attributes']
        require(a['name'] == GROUP and a['isInternalGroup'] is True and
                a.get('publicLinkEnabled') in (None, False) and a.get('publicLink') is None and a['hasAccessToAllBuilds'] is False,
                'Private group/manual distribution drift.')
        testers = self.all(f'/v1/betaGroups/{g["id"]}/betaTesters?limit=200')
        require(len(testers) == 1, 'Private audience must have exactly one tester.')
        t = testers[0]
        pin = self.config.get('pete_tester_id')
        require(bool(pin) and t['id'] == pin, 'Sole tester does not match verified Owner ID.')
        require(bool(self.config.get('private_group_id')) and g['id'] == self.config['private_group_id'],
                'Private group ID missing or drifted.')
        return {'group_id': g['id'], 'group': GROUP, 'internal': True, 'tester_count': 1,
                'sole_tester_is_owner': True, 'public_link': False, 'other_distribution_groups': [],
                'automatic_distribution_reviewed': True, 'manual_distribution': True}

    def preflight(self):
        h = self.history()
        h.update(audience=self.audience(), auth_ready=True, history_complete=True,
                 observed_at=dt.datetime.now(dt.timezone.utc).isoformat(), app_id=APP, bundle=BUNDLE)
        require(h['history'], 'Expected existing Apple history absent.')
        return h

    def exact(self, version, number):
        matches = [b for b in self.history()['history'] if b['build'] == number]
        require(len(matches) <= 1, 'Ambiguous Apple build number.')
        if not matches:
            return None
        require(matches[0]['version'] == version, 'Apple build number has another version.')
        return matches[0]

    def readback(self, version, number, assign=False):
        audience = self.audience()
        b = self.exact(version, number)
        if b is None:
            return {'stage': 'upload_pending', 'status': 'not_visible', 'upload_outcome_uncertain': True}
        ident = b['id']
        build = self.request(f'/v1/builds/{ident}')['data']
        attrs = build['attributes']
        require(attrs['version'] == str(number), 'Build identity changed.')
        if attrs['processingState'] != 'VALID':
            return {'stage': 'uploaded_processing' if attrs['processingState'] == 'PROCESSING' else
                    'uploaded_action_required', 'build_id': ident, 'processing': attrs['processingState']}
        require(attrs.get('buildAudienceType') == 'INTERNAL_ONLY', 'Build is not Internal Only.')
        detail = self.request(f'/v1/builds/{ident}/buildBetaDetail')['data']['attributes']
        beta = detail['internalBuildState']
        if beta not in ('READY_FOR_BETA_TESTING', 'IN_BETA_TESTING'):
            # Never infer an exemption from a previous build, patch false, or reuse a declaration.
            return {'stage': 'uploaded_action_required', 'build_id': ident, 'internal_status': beta,
                    'compliance': 'action_required', 'uses_non_exempt_encryption': attrs.get('usesNonExemptEncryption')}
        groups = self.all(f'/v1/betaGroups?filter[builds]={ident}&limit=200')
        require(all(g['id'] == audience['group_id'] for g in groups), 'Exact build has unexpected groups.')
        individuals = self.all(f'/v1/builds/{ident}/individualTesters?limit=200')
        require(not individuals, 'Exact build has individual tester distribution.')
        assigned = any(g['id'] == audience['group_id'] for g in groups)
        if assign and not assigned:
            self.audience()
            self.request(f'/v1/betaGroups/{audience["group_id"]}/relationships/builds', 'POST',
                         {'data': [{'type': 'builds', 'id': ident}]})
        # Independent readback from group side and fresh build status after any mutation.
        group_builds = self.all(f'/v1/betaGroups/{audience["group_id"]}/builds?limit=200')
        assigned = any(x['id'] == ident for x in group_builds)
        if assign:
            require(assigned, 'Assignment outcome uncertain; inspect exact group readback, do not repeat mutation.')
        self.audience()
        require(not self.all(f'/v1/builds/{ident}/individualTesters?limit=200'), 'Individual audience drift after assignment.')
        final_groups = self.all(f'/v1/betaGroups?filter[builds]={ident}&limit=200')
        require(all(g['id'] == audience['group_id'] for g in final_groups), 'Build audience drift after assignment.')
        beta = self.request(f'/v1/builds/{ident}/buildBetaDetail')['data']['attributes']['internalBuildState']
        testing = assigned and beta == 'IN_BETA_TESTING'
        return dict(audience, stage='api_testing' if testing else 'processed_awaiting_tester',
                    build_id=ident, version=version, build=number, internal_status=beta,
                    processing='VALID', compliance='accepted_by_apple',
                    uses_non_exempt_encryption=attrs.get('usesNonExemptEncryption'), assigned_to_group=assigned,
                    status='Testing' if testing else beta, pete_device_visibility_verified=False)

    def poll(self, version, number, seconds=900, interval=30, assign=False):
        require(0 <= seconds <= 1800 and 1 <= interval <= 60, 'Invalid bounded poll limits.')
        deadline = time.monotonic() + seconds
        while True:
            result = self.readback(version, number, assign=assign)
            if result['stage'] not in ('upload_pending', 'uploaded_processing', 'processed_awaiting_tester') or time.monotonic() >= deadline:
                return result
            time.sleep(min(interval, max(0, deadline - time.monotonic())))

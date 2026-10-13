#!/usr/bin/env python3
"""Bounded Wingman Nightly release from committed, isolated sources; broker only."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / 'tmp/docs/handoffs/zapstore-nightly'
PACKAGE = 'com.wingmanbefree.wingman_app.nightly'
NPUB = os.environ.get('WMAPP_ZAPSTORE_PUBLISHER_NPUB', '')
JAVA = '/Applications/Android Studio.app/Contents/jbr/Contents/Home'
KEYROOT = Path.home() / '.config/wmapp'
KEYSTORE = KEYROOT / 'wingman-nightly-release.p12'
PASSWORD = KEYROOT / 'wingman-nightly-release.password'
ZSP = Path.home() / 'go/bin/zsp'


def command(args, cwd=ROOT, env=None):
    return subprocess.check_output([str(x) for x in args], cwd=cwd, env=env, text=True).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def safe_private(path):
    path = path.absolute()
    if not path.is_relative_to(PRIVATE) or any(x.is_symlink() for x in [path, *path.parents]):
        raise ValueError('Evidence must remain under ignored private storage without symlinks.')
    subprocess.run(['git', '-C', str(ROOT), 'check-ignore', '-q', str(path.relative_to(ROOT))], check=True)
    if command(['git', 'ls-files', '--', str(path.relative_to(ROOT))]):
        raise ValueError('Evidence destination is tracked.')


def save(path, value):
    safe_private(path)
    tmp = path.with_suffix('.new')
    if tmp.is_symlink(): raise ValueError('Unsafe state temporary file.')
    tmp.write_text(json.dumps(value, indent=2) + '\n'); tmp.chmod(0o600); tmp.replace(path)


def reserve(ledger, day, owner, remote_max, base_version):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',base_version): raise ValueError('Exact committed source marketing version required.')
    if not owner or type(remote_max) is not int or remote_max < 0: raise ValueError('Verified owner/history required.')
    if ledger.get('schema') != 1: raise ValueError('Unsupported ledger.')
    runs = ledger['runs']
    if day in runs: raise ValueError('This Perth day already has a reservation; reconcile, never repeat.')
    if any(x['stage'] not in ('published', 'failed_before_delivery') for x in runs.values()):
        raise ValueError('Prior active or uncertain delivery requires exact reconciliation; no automatic expiry.')
    code = max([remote_max, int(dt.datetime.now(dt.timezone.utc).timestamp())] + [x['version_code'] for x in runs.values()]) + 1
    if code > 2100000000: raise ValueError('Android version code limit reached.')
    runs[day] = {'owner': owner, 'stage': 'reserved', 'version_code': code, 'version_name': f'{base_version}-nightly.{day.replace("-", "")}.{code}'}
    return runs[day]


def snapshot(repo, target):
    if command(['git', 'branch', '--show-current'], repo) != 'main': raise ValueError('Snapshot requires main.')
    commit = command(['git', 'rev-parse', 'HEAD'], repo)
    target.mkdir(mode=0o700)
    tar = target.with_suffix('.tar')
    with tar.open('xb') as stream:
        subprocess.run(['git', '-C', str(repo), 'archive', commit], stdout=stream, check=True)
    subprocess.run(['tar', '-xf', str(tar), '-C', str(target)], check=True)
    # Supply the exact source index to Git-based validation without adding
    # generated/ignored files or changing the shared repository index.
    command(['git','init',target])
    objects=Path(command(['git','rev-parse','--git-path','objects'],repo))
    if not objects.is_absolute(): objects=repo/objects
    (target/'.git/objects/info/alternates').write_text(str(objects.resolve())+'\n')
    command(['git','read-tree',commit],target)
    command(['git','update-ref','refs/heads/main',commit],target)
    command(['git','symbolic-ref','HEAD','refs/heads/main'],target)
    save(target.parent/(target.name+'-source.json'), {'commit':commit,'archive_sha256':digest(tar)})
    if command(['git', 'rev-parse', 'HEAD'], repo) != commit: raise ValueError('Source commit moved during snapshot.')
    return commit


def assets(directory):
    return {str(p.relative_to(directory)): digest(p) for p in sorted(directory.rglob('*')) if p.is_file()}


def private_key_reference(path):
    if not path.is_file() or any(x.is_symlink() for x in [path, *path.parents]) or path.stat().st_mode & 0o077:
        raise ValueError('Signing reference must be an owner-only regular file without symlinks.')


def require_resume(s, owner, run):
    if not owner or s['owner']!=owner: raise ValueError('Only the reservation owner can resume.')
    if s['stage']!='building' or any((run/x).exists() for x in ('app-release.apk','signed.json','proof-signed.json','broker-upload.log','relay-publish.log','signed-public-assets.json')):
        raise ValueError('Resume allowed only before signing/delivery, for retained exact source snapshots.')


def testflight_active(ledger):
    if ledger.get('schema') != 1 or not isinstance(ledger.get('days'), dict):
        raise ValueError('Invalid TestFlight coordination ledger.')
    return any(x['status']=='active' for x in ledger['days'].values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'prepare', 'public-assets', 'amend-listing', 'prepare-public', 'publish-public', 'resume-build', 'publish', 'readback', 'status'])
    parser.add_argument('--day', default=dt.datetime.now(ZoneInfo('Australia/Perth')).date().isoformat())
    parser.add_argument('--committed-source', action='store_true', help='First-publication only: preserve incompatible active edits and validate exact committed snapshots.')
    parser.add_argument('--flightdeck', type=Path, default=ROOT.parent / 'flightdeck')
    a = parser.parse_args()
    if dt.date.fromisoformat(a.day).isoformat() != a.day: raise ValueError('Invalid day.')
    safe_private(PRIVATE); PRIVATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ('.release.lock', 'ledger.json'):
        if (PRIVATE/name).is_symlink(): raise ValueError('Unsafe release storage.')
    if a.action=='status':
        path=PRIVATE/'ledger.json'
        print(path.read_text() if path.exists() else json.dumps({'schema':1,'runs':{}}));return
    with (PRIVATE/'.release.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        ledger_path = PRIVATE/'ledger.json'
        ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {'schema': 1, 'runs': {}}
        run = PRIVATE/a.day
        env = {**os.environ, 'JAVA_HOME': JAVA, 'AUTOPILOT_REPO': str(ROOT.parent/'autopilot'), 'RUSTUP_TOOLCHAIN':'stable'}
        def logged(args, cwd, label):
            with (run/(label+'.log')).open('xb') as output:
                result = subprocess.run([str(x) for x in args], cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
            if result.returncode: raise ValueError(label+' failed; inspect retained private log; no automatic delivery retry.')
        def update(stage):
            s['stage'] = stage; save(ledger_path, ledger); save(run/'state.json', s)
        if a.action == 'build':
            if a.day != dt.datetime.now(ZoneInfo('Australia/Perth')).date().isoformat(): raise ValueError('Build requires current Perth day.')
            if not env.get('FLIGHT_DECK_PG_APP_NPUB'): raise ValueError('Verified Flight Deck app identity required.')
            # A single scheduler session prepares source for both lanes. Manual builds
            # refuse an active TestFlight claim rather than compete with it.
            ios_ledger = ROOT/'tmp/docs/handoffs/nightly-testflight/ledger.json'
            if ios_ledger.exists() and testflight_active(json.loads(ios_ledger.read_text())):
                raise ValueError('TestFlight nightly is active; finish/reconcile that lane first.')
            for repo in (a.flightdeck, ROOT):
                if command(['git','status','--porcelain'],repo) and not a.committed_source: raise ValueError('Commit validated compatible source first; preserve concurrent work.')
            private_key_reference(KEYSTORE); private_key_reference(PASSWORD)
            history=json.loads(command(['bun',ROOT/'tools/zapstore_broker.ts','history',PRIVATE]))
            source_commit=command(['git','rev-parse','HEAD'])
            source_version=re.search(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+',command(['git','show',source_commit+':app/pubspec.yaml']),re.MULTILINE)
            if not source_version: raise ValueError('Committed source version missing.')
            s=reserve(ledger,a.day,os.environ.get('SESSION_ID'),history['maxVersionCode'],source_version.group(1));s['planned_source_commit']=source_commit; s['excluded_uncommitted_source']={str(repo.name):command(['git','status','--porcelain'],repo) for repo in (a.flightdeck,ROOT)}; save(ledger_path,ledger)
            run.mkdir(mode=0o700);update('building')
            fd=run/'flightdeck';wm=run/'wmapp'
            s['flightdeck_commit']=snapshot(a.flightdeck,fd);update('building')
            meta=json.loads((fd/'.build-meta.json').read_text());notes=json.loads((fd/'release-notes.json').read_text())
            number=max([meta['absoluteVersion']]+[x['buildNumber'] for x in notes['releases']])
            env.update(FLIGHTDECK_BUILD_NUMBER=str(number),FLIGHTDECK_BUILD_ID=f"wmapp-{s['flightdeck_commit'][:12]}-{number}",SOURCE_DATE_EPOCH=command(['git','log','-1','--format=%ct'],a.flightdeck),FLIGHT_DECK_DIR=str(fd))
            logged(['bun','install','--frozen-lockfile'],fd,'fd-install')
            for script in ('check:public-source','test','build','verify:dist'): logged(['bun','run',script],fd,'fd-'+script.replace(':','-'))
            s['flightdeck_version']=json.loads((fd/'dist/version.json').read_text());s['flightdeck_assets']=assets(fd/'dist')
            if s['flightdeck_version']['buildId'] != env['FLIGHTDECK_BUILD_ID']: raise ValueError('Flight Deck build ID mismatch.')
            if command(['git','rev-parse','HEAD'])!=s['planned_source_commit']: raise ValueError('WMAPP commit moved during Flight Deck validation; preserve and stop.')
            s['source_commit']=snapshot(ROOT,wm);update('building')
            logged([wm/'tools/update_flightdeck_bundle.sh','--use-existing-dist'],wm,'bundle')
            if assets(wm/'app/assets/flightdeck') != s['flightdeck_assets']: raise ValueError('Bundled assets differ.')
            env.update(WMAPP_ANDROID_CHANNEL='nightly',WMAPP_ANDROID_KEYSTORE=str(KEYSTORE),WMAPP_ANDROID_STORE_PASSWORD=PASSWORD.read_text(),WMAPP_ANDROID_KEY_PASSWORD=PASSWORD.read_text(),WMAPP_ANDROID_KEY_ALIAS='wingman-nightly')
            logged(['cargo','build','--locked','--release','-p','wmapp-drive-fs'],wm,'drive-fs-build')
            for args,label in [(['flutter','pub','get'],'pub'),(['flutter','analyze'],'analyze'),(['flutter','test'],'flutter-test'),(['flutter','build','apk','--release','--target-platform','android-arm64','--build-name',s['version_name'],'--build-number',str(s['version_code'])],'apk-build')]: logged(args,wm/'app',label)
            import shutil
            shutil.copyfile(wm/'app/build/app/outputs/flutter-apk/app-release.apk',run/'app-release.apk')
            s['apk_sha256']=digest(run/'app-release.apk')
            logged([wm/'app/android/gradlew','testDebugUnitTest'],wm/'app/android','android-unit-tests')
            update('built')
        else:
            s=ledger['runs'][a.day]
            if a.action!='readback' and s['owner']!=os.environ.get('SESSION_ID'): raise ValueError('Only reservation owner can mutate release.')
            if a.action=='resume-build':
                require_resume(s,os.environ.get('SESSION_ID'),run)
                fd=run/'flightdeck';wm=run/'wmapp'
                for name,key in [('flightdeck','flightdeck_commit'),('wmapp','source_commit')]:
                    proof=json.loads((run/(name+'-source.json')).read_text())
                    if digest(run/(name+'.tar'))!=proof['archive_sha256']: raise ValueError('Source archive changed.')
                    s[key]=proof['commit']
                s['flightdeck_version']=json.loads((fd/'dist/version.json').read_text());s['flightdeck_assets']=assets(fd/'dist')
                if assets(wm/'app/assets/flightdeck')!=s['flightdeck_assets']: raise ValueError('Bundled Flight Deck differs.')
                private_key_reference(KEYSTORE);private_key_reference(PASSWORD)
                env.update(WMAPP_ANDROID_CHANNEL='nightly',WMAPP_ANDROID_KEYSTORE=str(KEYSTORE),WMAPP_ANDROID_STORE_PASSWORD=PASSWORD.read_text(),WMAPP_ANDROID_KEY_PASSWORD=PASSWORD.read_text(),WMAPP_ANDROID_KEY_ALIAS='wingman-nightly',RUSTUP_TOOLCHAIN='stable')
                update('building')
                logged(['cargo','build','--locked','--release','-p','wmapp-drive-fs'],wm,'resume-drive-fs-build')
                for args,label in [(['flutter','analyze'],'resume-analyze'),(['flutter','test'],'resume-flutter-test'),(['flutter','build','apk','--release','--target-platform','android-arm64','--build-name',s['version_name'],'--build-number',str(s['version_code'])],'resume-apk-build')]: logged(args,wm/'app',label)
                import shutil
                shutil.copyfile(wm/'app/build/app/outputs/flutter-apk/app-release.apk',run/'app-release.apk')
                s['apk_sha256']=digest(run/'app-release.apk')
                logged([wm/'app/android/gradlew','testDebugUnitTest'],wm/'app/android','resume-android-unit-tests');update('built')
            elif a.action=='prepare':
                if s['stage']!='built': raise ValueError('Preparation requires built state.')
                private_key_reference(KEYSTORE);private_key_reference(PASSWORD)
                if not re.fullmatch(r'npub1[a-z0-9]{58}', NPUB): raise ValueError('Verified WMAPP_ZAPSTORE_PUBLISHER_NPUB required.')
                env.update(SIGN_WITH=NPUB,KEYSTORE_PASSWORD=PASSWORD.read_text())
                command([JAVA+'/bin/keytool','-exportcert','-keystore',KEYSTORE,'-storepass:file',PASSWORD,'-alias','wingman-nightly','-file',run/'certificate.der'],env=env)
                s['certificate_sha256']=digest(run/'certificate.der')
                command([ZSP,'utils','extract-apk',run/'app-release.apk'],env=env)
                import shutil
                shutil.copyfile(run/'app-release_icon.png',run/'icon.png')
                import prepare_zapstore_release as prep
                # Reuse the stable inspector's full APK/VPN/ABI/ZIP checks, with
                # exact independently pinned nightly identity for this process.
                prep.EXPECTED_PACKAGE_ID=PACKAGE;prep.EXPECTED_CERTIFICATE_SHA256=s['certificate_sha256']
                metadata=prep.ApkInspector().inspect(run/'app-release.apk',run/'icon.png')
                if metadata.version_code!=s['version_code'] or metadata.version_name!=s['version_name']: raise ValueError('Reserved version mismatch.')
                badging=command([prep.find_android_tools()[0],'dump','badging',run/'app-release.apk'])
                if "application-label:'Wingman Nightly'" not in badging: raise ValueError('Nightly visible name mismatch.')
                notes=f"Wingman Nightly {a.day}\n\nWMAPP source: {s['source_commit']}\nFlight Deck source: {s['flightdeck_commit']}\nFlight Deck build: {s['flightdeck_version']['buildId']}\n"
                (run/'notes.md').write_text(notes)
                config=(ROOT/'zapstore-nightly.yaml').read_text().replace('./app/build/app/outputs/flutter-apk/app-release.apk',str(run/'app-release.apk')).replace('./docs/deploy/nightly-zapstore-notes.md',str(run/'notes.md'))
                (run/'zapstore.yaml').write_text(config)
                with (run/'unsigned.jsonl').open('x') as out,(run/'upload-manifest.txt').open('x') as err:
                    subprocess.run([str(ZSP),'--json','publish',str(run/'zapstore.yaml'),'--offline','--quiet','--no-compress','--channel','nightly','--commit',s['source_commit']],env=env,stdout=out,stderr=err,check=True)
                logged(['bun',ROOT/'tools/zapstore_broker.ts','sign',run,s['certificate_sha256']],ROOT,'broker-sign')
                # Broker chooses current timestamp. Generate a fresh keystore proof
                # and only accept exact timestamp equality; no event is published here.
                for attempt in range(3):
                    proof=command([ZSP,'--json','identity','--link-key',KEYSTORE,'--key-alias','wingman-nightly','--offline'],env=env)
                    (run/'proof-unsigned.json').write_text(proof)
                    r=subprocess.run(['bun',str(ROOT/'tools/zapstore_broker.ts'),'proof',str(run),s['certificate_sha256']],env=env,capture_output=True,text=True)
                    if r.returncode==0: break
                    if 'timestamp changed' not in r.stderr: raise ValueError(r.stderr.strip())
                else: raise ValueError('Certificate proof timestamp cannot match broker; no publication.')
                s['source_archive_sha256']=digest(run/'wmapp.tar');s['flightdeck_archive_sha256']=digest(run/'flightdeck.tar');update('prepared')
            elif a.action=='public-assets':
                if s['stage']!='prepared': raise ValueError('Public assets require prepared state; reconcile uncertain GitHub outcome before retry.')
                proof={k:s[k] for k in ('version_name','version_code','source_commit','flightdeck_commit','flightdeck_version','flightdeck_assets','apk_sha256','certificate_sha256','source_archive_sha256','flightdeck_archive_sha256')}
                proof.update(package=PACKAGE,publisher=NPUB)
                (run/'build-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
                release='nightly-'+a.day+'-'+str(s['version_code'])
                existing=subprocess.run(['gh','release','view',release,'--repo','OtherStuffAI/wingman-nightly'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                if existing.returncode==0: raise ValueError('GitHub release already exists; reconcile exact hashes, never overwrite.')
                update('public_assets_pending')
                logged(['gh','release','create',release,'--repo','OtherStuffAI/wingman-nightly','--title','Wingman Nightly '+a.day,'--notes-file',run/'notes.md',run/'app-release.apk',run/'wmapp.tar',run/'flightdeck.tar',run/'build-proof.json'],ROOT, 'github-assets')
                s['public_release_url']='https://github.com/OtherStuffAI/wingman-nightly/releases/tag/'+release
                public=run/'github-readback';public.mkdir(mode=0o700)
                logged(['gh','release','download',release,'--repo','OtherStuffAI/wingman-nightly','--dir',public],ROOT,'github-assets-readback')
                for filename in ('app-release.apk','wmapp.tar','flightdeck.tar','build-proof.json'):
                    if digest(public/filename)!=digest(run/filename): raise ValueError('Public GitHub asset hash mismatch.')
                update('prepared')
            elif a.action=='amend-listing':
                if s['stage']!='published': raise ValueError('Only a confirmed release can receive an intentional listing metadata correction.')
                update('listing_update_pending')
                logged(['bun',ROOT/'tools/zapstore_broker.ts','amend-listing',run,s['certificate_sha256']],ROOT,'listing-amendment')
                update('published')
            elif a.action=='prepare-public':
                if s['stage']!='prepared' or not s.get('public_release_url'): raise ValueError('Verified public source release required.')
                if (run/'github-icon.log').exists(): raise ValueError('Reconcile existing icon upload before retry.')
                release=s['public_release_url'].split('/')[-1]
                logged(['gh','release','upload',release,'--repo','OtherStuffAI/wingman-nightly',run/'icon.png'],ROOT,'github-icon')
                icon_dir=run/'github-icon-readback';icon_dir.mkdir(mode=0o700)
                logged(['gh','release','download',release,'--repo','OtherStuffAI/wingman-nightly','--pattern','icon.png','--dir',icon_dir],ROOT,'github-icon-readback')
                if digest(icon_dir/'icon.png')!=digest(run/'icon.png'): raise ValueError('Public icon hash mismatch.')
                import prepare_zapstore_release as prep
                prep.EXPECTED_PACKAGE_ID=PACKAGE;prep.EXPECTED_CERTIFICATE_SHA256=s['certificate_sha256']
                prep.ApkInspector().inspect(run/'github-readback/app-release.apk',run/'icon.png')
                logged(['bun',ROOT/'tools/zapstore_broker.ts','sign-public',run,s['certificate_sha256']],ROOT,'broker-sign-public')
                s['asset_host']='github';s['icon_sha256']=digest(run/'icon.png');update('prepared_public')
            elif a.action=='publish-public':
                if s['stage']!='prepared_public': raise ValueError('Verified public GitHub assets required; never retry delivery.')
                update('delivery_pending')
                logged(['bun',ROOT/'tools/zapstore_broker.ts','publish-public',run,s['certificate_sha256']],ROOT,'relay-publish-public')
                update('published')
            elif a.action=='publish':
                if s['stage']!='prepared' or not s.get('public_release_url'): raise ValueError('Verified public source assets required; never retry delivery.')
                update('delivery_pending')
                logged(['bun',ROOT/'tools/zapstore_broker.ts','upload',run,s['certificate_sha256']],ROOT,'broker-upload')
                # Verify downloaded APK signature/certificate as well as public hash.
                import urllib.request,prepare_zapstore_release as prep
                with urllib.request.urlopen('https://cdn.zapstore.dev/'+s['apk_sha256'], context=__import__('ssl').create_default_context(cafile='/etc/ssl/cert.pem')) as response,(run/'public.apk').open('xb') as out:
                    import shutil;shutil.copyfileobj(response,out)
                prep.EXPECTED_PACKAGE_ID=PACKAGE;prep.EXPECTED_CERTIFICATE_SHA256=s['certificate_sha256']
                prep.ApkInspector().inspect(run/'public.apk',run/'icon.png')
                if digest(run/'public.apk')!=s['apk_sha256']: raise ValueError('Public APK hash mismatch.')
                logged(['bun',ROOT/'tools/zapstore_broker.ts','publish',run,s['certificate_sha256']],ROOT,'relay-publish')
                update('published')
            elif a.action=='readback':
                logged(['bun',ROOT/'tools/zapstore_broker.ts','readback',run,s['certificate_sha256']],ROOT,'relay-recovery')
                # Readback does not by itself complete APK/public listing verification.
        print(json.dumps(s,indent=2))

if __name__=='__main__':
    try: main()
    except (ValueError,OSError,subprocess.CalledProcessError,KeyError) as error: sys.exit('Stopped: '+str(error))

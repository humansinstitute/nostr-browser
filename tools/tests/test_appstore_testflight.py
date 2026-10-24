"""Consequential Apple API and runner safety tests; no Apple mutations."""
import contextlib
import datetime as dt
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ios'))
from appstore_connect import Client, APP, BUNDLE, GROUP, owner_file
import testflight_api_release as api
import testflight_release as release
import nightly_testflight as nightly


def client():
    c = Client.__new__(Client)
    c.config = {'pete_tester_id': 'tester', 'private_group_id': 'private'}
    return c


def build(number='10', version_id='v'):
    return {'id': 'b' + number, 'attributes': {'version': number, 'processingState': 'VALID'},
            'relationships': {'preReleaseVersion': {'data': {'id': version_id}}}}


def upload(number='11', version='0.1.8', state='AWAITING_UPLOAD'):
    return {'id': 'u' + number, 'attributes': {'cfBundleVersion': number,
            'cfBundleShortVersionString': version, 'platform': 'IOS', 'createdDate': '2026-01-01T00:00:00Z',
            'uploadedDate': None, 'state': {'state': state, 'errors': []}}}


def history(c, uploads=None):
    c.request = Mock(return_value={'data': {'id': APP, 'attributes': {'bundleId': BUNDLE}}})
    c.all = Mock(side_effect=[[build()], uploads or [],
                             [{'id': 'v', 'attributes': {'version': '0.1.7', 'platform': 'IOS'}}]])


class AppleTests(unittest.TestCase):
    def test_token_signature_scope_and_expiry(self):
        import jwt
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        key = ec.generate_private_key(ec.SECP256R1())
        with tempfile.TemporaryDirectory() as d:
            p = Path(d).resolve() / 'key.p8'
            p.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption())); p.chmod(0o600)
            c = client(); c.config.update(key_path=str(p), issuer_id='issuer', key_id='ABCDEFGHIJ')
            token = c.token()
            claims = jwt.decode(token, key.public_key(), algorithms=['ES256'], audience='appstoreconnect-v1', issuer='issuer')
            self.assertEqual(claims['exp'] - claims['iat'], 600)
            self.assertEqual(jwt.get_unverified_header(token)['kid'], 'ABCDEFGHIJ')

    def test_owner_file_rejects_world_readable_and_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d).resolve() / 'key'; p.write_text('fixture'); p.chmod(0o644)
            with self.assertRaises(ValueError): owner_file(p)
            p.chmod(0o600); self.assertEqual(owner_file(p), p)
            link = Path(d).resolve() / 'link'; link.symlink_to(p)
            with self.assertRaises(ValueError): owner_file(link)

    def test_tls_verification_and_xcode_auth(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d).resolve() / 'key'; p.write_text('fixture'); p.chmod(0o600)
            ref = Path(d).resolve() / 'ref'; ref.write_text(json.dumps({'schema': 1, 'key_id': 'ABCDEFGHIJ',
                'issuer_id': 'a87ef7ff-fa15-4673-953f-a0e026c37259', 'key_path': str(p)})); ref.chmod(0o600)
            c = Client(ref)
            https = next(h for h in c.opener.handlers if type(h).__name__ == 'HTTPSHandler')
            import ssl
            self.assertEqual(https._context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(https._context.check_hostname)
            self.assertIn('-authenticationKeyIssuerID', c.xcode_args())

    def test_pagination_all_pages_cycle_duplicate_and_untrusted_next(self):
        c = client(); c.request = Mock(side_effect=[{'data': [{'id':'1'}], 'links': {'next':'/v1/next'}}, {'data':[{'id':'2'}]}])
        self.assertEqual(len(c.all('/v1/first')), 2)
        c.request = Mock(return_value={'data': [], 'links': {'next':'/v1/first'}})
        with self.assertRaises(ValueError): c.all('/v1/first')
        c.request = Mock(return_value={'data':[{'id':'same'}, {'id':'same'}]})
        with self.assertRaises(ValueError): c.all('/v1/first')
        c = client(); c.token = Mock()
        for url in ['https://evil.test/v1/a', 'http://api.appstoreconnect.apple.com/v1/a',
                    'https://api.appstoreconnect.apple.com:443/v1/a']:
            with self.assertRaises(ValueError): c.request(url)
        c.token.assert_not_called()

    def test_history_includes_uploads_and_pending_number(self):
        c = client(); history(c, [upload('20')]); h = c.history()
        self.assertEqual(api.numbers(h), [10,20]); self.assertEqual(h['pending_upload_ids'], ['u20'])
        self.assertIn('include=preReleaseVersion', c.all.call_args_list[0].args[0])

    def test_legacy_requires_exact_evidence_and_empty_files(self):
        c = client(); u = upload('9', '0.1.7'); history(c,[u])
        self.assertEqual(c.history()['pending_upload_ids'], ['u9'])
        expected = {'version':'0.1.7','build':9,'created_at':u['attributes']['createdDate']}
        c.config['inactive_uploads'] = {'u9':expected}
        c.evidence = Mock(return_value={'inactive_uploads':{'u9':expected}})
        history(c,[u]); c.all.side_effect = list(c.all.side_effect) + [[]]
        self.assertEqual(c.history()['inactive_upload_ids'], ['u9'])
        history(c,[u]); c.all.side_effect = list(c.all.side_effect) + [[{'id':'file'}]]
        with self.assertRaises(ValueError): c.history()
        u['attributes']['uploadedDate'] = '2026-01-01'; history(c,[u])
        with self.assertRaises(ValueError): c.history()

    def test_unknown_history_and_wrong_app_fail_closed(self):
        c=client(); history(c,[upload(state='NEW_STATE')])
        with self.assertRaises(ValueError): c.history()
        history(c); c.request.return_value['data']['attributes']['bundleId']='wrong'
        with self.assertRaises(ValueError): c.history()

    def test_audience_pins_manual_private_and_no_public_link(self):
        c=client()
        group={'id':'private', 'attributes':{'name':GROUP,'isInternalGroup':True,
            'publicLinkEnabled':None,'publicLink':None,'hasAccessToAllBuilds':False}}
        def setup(): c.all=Mock(side_effect=[[group],[{'id':'tester'}]])
        setup(); self.assertTrue(c.audience()['manual_distribution'])
        for field,value in [('publicLink','https://testflight.apple.com/join/x'), ('hasAccessToAllBuilds',True),('isInternalGroup',False)]:
            old=group['attributes'][field];group['attributes'][field]=value;setup()
            with self.assertRaises(ValueError):c.audience()
            group['attributes'][field]=old
        c.all=Mock(side_effect=[[group],[{'id':'wrong'}]])
        with self.assertRaises(ValueError):c.audience()

    def test_readback_processing_compliance_and_assignment(self):
        c=client(); c.audience=Mock(return_value={'group_id':'private'})
        c.exact=Mock(return_value={'id':'b10'})
        attrs={'version':'10','processingState':'PROCESSING','buildAudienceType':'INTERNAL_ONLY'}
        c.request=Mock(return_value={'data':{'attributes':attrs}})
        self.assertEqual(c.readback('0.1.7',10)['stage'],'uploaded_processing')
        attrs['processingState']='INVALID'
        self.assertEqual(c.readback('0.1.7',10)['stage'],'failed_processing')
        attrs['processingState']='VALID'
        c.all=Mock(side_effect=[[],[]])
        c.request=Mock(side_effect=[{'data':{'attributes':attrs}}, {'data':{'attributes':{'internalBuildState':'MISSING_EXPORT_COMPLIANCE'}}}])
        self.assertEqual(c.readback('0.1.7',10,assign=True)['stage'],'uploaded_action_required')
        self.assertEqual(c.request.call_count,2)
        c.request=Mock(side_effect=[{'data':{'attributes':attrs}}, {'data':{'attributes':{'internalBuildState':'READY_FOR_BETA_TESTING'}}}, {},
                                   {'data':{'attributes':{'internalBuildState':'IN_BETA_TESTING'}}}])
        c.all=Mock(side_effect=[[],[],[{'id':'b10'}],[],[{'id':'private'}]])
        result=c.readback('0.1.7',10,assign=True)
        self.assertEqual(result['stage'],'api_testing');self.assertFalse(result['pete_device_visibility_verified'])
        self.assertEqual(c.request.call_args_list[2].args[1],'POST')

    def test_prior_compliance_action_is_rechecked_live_without_blocking_fresh_upload(self):
        c=client()
        with tempfile.TemporaryDirectory() as temp:
            state=Path(temp).resolve()/'state.json'
            value=dict(api=True,app_id=APP,version='0.1.7',build=10,stage='api_action_required',upload_command_completed_at='now')
            state.write_text(json.dumps(value));state.chmod(0o600)
            c.readback=Mock(return_value=dict(processing='VALID',build_id='exact',stage='uploaded_action_required'))
            self.assertTrue(c.local_reconciled(state))
            c.readback.assert_called_once_with('0.1.7',10,assign=False)
            self.assertEqual(json.loads(state.read_text()),value)
            for result in [dict(stage='upload_pending'),dict(processing='INVALID',build_id='exact',stage='uploaded_action_required')]:
                c.readback.return_value=result
                with self.assertRaises(ValueError):c.local_reconciled(state)


class RunnerTests(unittest.TestCase):
    def test_reservation_uses_upload_version_and_local_number(self):
        c=client(); history(c,[upload('30','0.2.0','COMPLETE')]);c.audience=Mock(return_value={})
        source={'nbrowser':'a'*40,'flightdeck':'b'*40}
        with tempfile.TemporaryDirectory() as d, patch.object(release,'PRIVATE',Path(d)), patch.object(api,'local_states',return_value=iter([(Path(d)/'old/state.json',{'build':40,'stage':'initialized'})])), patch.object(api,'require_daily_claim',return_value={'source':source}):
            s=api.reserve(release,Path(d)/'new',c)
            self.assertEqual((s['build'],s['version']),(41,'0.2.0'))
            self.assertEqual(s['source'],source)

    def test_pending_barriers_do_not_create_reservation(self):
        c=client();history(c,[upload()]);c.audience=Mock(return_value={})
        with tempfile.TemporaryDirectory() as d, patch.object(release,'PRIVATE',Path(d)), patch.object(api,'require_daily_claim',return_value={'source':{'nbrowser':'a'*40,'flightdeck':'b'*40}}):
            run=Path(d)/'new'
            with self.assertRaises(ValueError):api.reserve(release,run,c)
            self.assertFalse(run.exists())
        c.local_reconciled=Mock(return_value=False)
        with patch.object(api,'local_states',return_value=iter([(Path('/old/state.json'),{'stage':'upload_pending'})])):
            with self.assertRaises(ValueError):api.delivery_barrier(release,None,c)

    def test_upload_persists_barrier_before_command_and_no_retry(self):
        c=client();c.preflight=Mock(return_value={'versions':[{'attributes':{'platform':'IOS','version':'0.1.7'}}], 'pending_upload_ids':[],'builds':[build()],'uploads':[]})
        c.xcode_args=Mock(return_value=['-authenticationKeyPath','private-reference'])
        with tempfile.TemporaryDirectory() as d:
            run=Path(d);s={'api':True,'app_id':APP,'audience':'internal','build':11,'version':'0.1.7','stage':'exported','artifact':{'sha256':'fixture'}}
            release.write(run/'state.json',s)
            a=SimpleNamespace(action='api-upload',auth_reference='unused')
            def fail(args,run,label):
                self.assertEqual(release.read(run/'state.json')['stage'],'upload_pending')
                raise ValueError('uncertain delivery')
            with patch.object(api,'Client',return_value=c), patch.object(api,'require_daily_claim'), patch.object(api,'delivery_barrier'), patch.object(release,'project_settings'), patch.object(release,'no_other_delivery'), patch.object(release,'validate_artifacts',return_value=s['artifact']), patch.object(release,'logged',side_effect=fail) as logged:
                with self.assertRaises(ValueError):api.execute(release,a,run)
                with self.assertRaises(ValueError):api.execute(release,a,run)
                self.assertEqual(logged.call_count,1)

    def test_readback_runner_interface_mapping(self):
        c=client();c.readback=Mock(return_value={'stage':'uploaded_processing','build_id':'exact'})
        with tempfile.TemporaryDirectory() as d:
            run=Path(d);release.write(run/'state.json',{'api':True,'app_id':APP,'audience':'internal','build':11,'version':'0.1.7','stage':'upload_pending'})
            a=SimpleNamespace(action='api-readback',auth_reference='unused',poll_seconds=0,read_only=True)
            with patch.object(api,'Client',return_value=c), patch.object(release,'project_settings'), contextlib.redirect_stdout(io.StringIO()):api.execute(release,a,run)
            c.readback.assert_called_once_with('0.1.7',11,assign=False)
            self.assertEqual(release.read(run/'state.json')['stage'],'api_processing')

    def test_current_marketing_version_drift_blocks_before_packaging_or_upload(self):
        h={'pending_upload_ids':[],'builds':[build()],'uploads':[],
           'versions':[{'attributes':{'platform':'IOS','version':'0.2.0'}}]}
        with self.assertRaises(ValueError):api.reservation_gate(release,h,{'build':11,'version':'0.1.7'})
        api.reservation_gate(release,h,{'build':11,'version':'0.2.0'})

    def test_api_dry_run_rejected_before_client_or_mutations(self):
        for action in ['api-reserve','api-build','api-upload','api-readback']:
            with patch.object(api,'Client') as make_client:
                with self.assertRaises(ValueError):api.execute(release,SimpleNamespace(action=action,dry_run=True),Path('/unused'))
                make_client.assert_not_called()
            with patch.object(sys,'argv',['testflight_release.py',action,'--run','unused','--dry-run']), patch.object(nightly,'safe_private'), patch.object(release,'execute') as execute:
                with self.assertRaises(ValueError):release.main()
                execute.assert_not_called()

    def test_assignment_readback_requires_claim_before_apple_mutation(self):
        c=client();c.readback=Mock()
        a=SimpleNamespace(action='api-readback',auth_reference='unused',read_only=False)
        with patch.object(api,'Client',return_value=c), patch.object(api,'require_daily_claim',side_effect=ValueError('claim required')):
            with self.assertRaises(ValueError):api.execute(release,a,Path('/unused'))
            c.readback.assert_not_called()

    def test_upload_preconditions_with_reconciled_cancelled_local_build9(self):
        c=client();c.preflight=Mock(return_value={'versions':[{'attributes':{'platform':'IOS','version':'0.1.7'}}], 'pending_upload_ids':[],'builds':[build()],
            'uploads':[upload('9','0.1.7'),upload('10','0.1.7','COMPLETE')]})
        c.local_reconciled=Mock(return_value=True);c.xcode_args=Mock(return_value=[])
        with tempfile.TemporaryDirectory() as d, patch.object(release,'PRIVATE',Path(d)), patch.object(nightly,'safe_private'):
            root=Path(d);old=root/'cancelled-build9';old.mkdir()
            old_state={'app_id':APP,'build':9,'version':'0.1.7','stage':'upload_pending'}
            release.write(old/'state.json',old_state);original=(old/'state.json').read_bytes()
            run=root/'nightly11';run.mkdir();state={'api':True,'app_id':APP,'audience':'internal',
                'build':11,'version':'0.1.7','stage':'exported','artifact':{'sha256':'fixture'}}
            release.write(run/'state.json',state)
            def upload_once(args,upload_run,label):
                self.assertEqual(release.read(upload_run/'state.json')['stage'],'upload_pending')
                self.assertEqual(label,'upload')
            # Both real barriers run here; only signature checking and the actual
            # Xcode mutation are substituted. The cancelled state is untouched.
            with patch.object(api,'Client',return_value=c), patch.object(api,'require_daily_claim'), patch.object(release,'project_settings'), patch.object(release,'validate_artifacts',return_value=state['artifact']), patch.object(release,'logged',side_effect=upload_once) as logged:
                api.execute(release,SimpleNamespace(action='api-upload',auth_reference='unused'),run)
                logged.assert_called_once()
            self.assertEqual((old/'state.json').read_bytes(),original)
            self.assertIn('upload_command_completed_at',release.read(run/'state.json'))

    def test_reviewed_old_build_does_not_block_higher_upload_same_build_still_blocks(self):
        c=client();c.local_reconciled=Mock(return_value=True)
        with tempfile.TemporaryDirectory() as d, patch.object(release,'PRIVATE',Path(d)), patch.object(nightly,'safe_private'):
            root=Path(d);old=root/'old';old.mkdir();release.write(old/'state.json',{'app_id':APP,'build':9,'stage':'upload_pending'})
            new=root/'new';new.mkdir()
            api.delivery_barrier(release,new,c)
            release.no_other_delivery(new,{'app_id':APP,'build':11})
            with self.assertRaises(ValueError):release.no_other_delivery(new,{'app_id':APP,'build':9})

    def test_state_symlink_cannot_overwrite_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);evidence=root/'evidence';evidence.write_text('preserve')
            state=root/'state.json';state.symlink_to(evidence)
            with self.assertRaises(ValueError):release.write(state,{'new':True})
            self.assertEqual(evidence.read_text(),'preserve')

    def test_build_requires_app_identity_before_any_snapshot(self):
        c=client()
        with tempfile.TemporaryDirectory() as d:
            source={'nbrowser':'a'*40,'flightdeck':'b'*40}
            run=Path(d);release.write(run/'state.json',{'api':True,'app_id':APP,'audience':'internal',
                'build':11,'version':'0.1.7','stage':'initialized','source':source})
            a=SimpleNamespace(action='api-build',auth_reference='unused')
            with patch.object(api,'Client',return_value=c), patch.object(api,'require_daily_claim'), patch.object(release,'project_settings'), patch.dict(os.environ,{},clear=True), patch.object(api,'snapshot') as snapshot:
                with self.assertRaises(ValueError):api.execute(release,a,run)
                snapshot.assert_not_called()
                self.assertEqual(release.read(run/'state.json')['stage'],'initialized')

    def test_build_orders_isolated_fd_before_wm_and_validates_signatures(self):
        c=client();c.preflight=Mock(return_value={'versions':[{'attributes':{'platform':'IOS','version':'0.1.7'}}], 'pending_upload_ids':[],'builds':[build()],'uploads':[]})
        c.xcode_args=Mock(return_value=[])
        with tempfile.TemporaryDirectory() as d:
            source={'nbrowser':'a'*40,'flightdeck':'a'*40}
            run=Path(d);release.write(run/'state.json',{'api':True,'app_id':APP,'audience':'internal',
                'build':11,'version':'0.1.7','stage':'initialized','source':source})
            a=SimpleNamespace(action='api-build',auth_reference='unused',flightdeck=Path('/fd'))
            actions=[]
            def snapshot(r,repo,target,commit=None):
                actions.append('snapshot-'+target.name);target.mkdir()
                if target.name=='flightdeck':
                    (target/'.build-meta.json').write_text('{"absoluteVersion":2246}')
                    (target/'release-notes.json').write_text('{"releases":[]}')
                return 'a'*40
            def run_command(args,**kw):
                actions.append(' '.join(map(str,args)))
                if args==['bun','run','build']:
                    dist=kw['cwd']/'dist';dist.mkdir()
                    (dist/'version.json').write_text(json.dumps({'buildId':kw['env']['FLIGHTDECK_BUILD_ID']}))
                if str(args[0]).endswith('update_flightdeck_bundle.sh'):
                    import shutil
                    shutil.copytree(run/'flightdeck/dist',run/'wmapp/app/assets/flightdeck')
                return SimpleNamespace(returncode=0)
            def signatures(*args):actions.append('signed-both-targets')
            def command(args):
                if 'remote' in args:
                    return release.SOURCE_REPOSITORY.encode()
                return b'100'
            with patch.object(api,'Client',return_value=c), patch.object(api,'require_daily_claim',return_value={'source':source}), patch.object(api,'delivery_barrier'), patch.object(release,'project_settings'), patch.dict(os.environ,{'FLIGHT_DECK_PG_APP_NPUB':'verified-fixture'}), patch.object(nightly,'source_identity',return_value=source), patch.object(api,'snapshot',side_effect=snapshot), patch.object(release,'command',side_effect=command), patch.object(api.subprocess,'run',side_effect=run_command), patch.object(release,'signed_app',side_effect=signatures), patch.object(release,'validate_artifacts',return_value={'sha256':'fixture'}), patch('release_sources.source_lock',return_value=__import__('contextlib').nullcontext()), patch('testflight_export_recovery.retain_export_logs'):
                api.execute(release,a,run)
            self.assertLess(actions.index('snapshot-wmapp'),actions.index('bun run build'))
            self.assertLess(actions.index('bun run test:release'),actions.index('bun run build'))
            self.assertLess(actions.index('signed-both-targets'),next(i for i,x in enumerate(actions) if '-exportArchive' in x))
            self.assertEqual(release.read(run/'state.json')['stage'],'exported')
            self.assertEqual(release.read(run/'state.json')['source_repository'],
                             release.SOURCE_REPOSITORY)

    def test_reconciliation_evidence_and_local_state_hash_drift(self):
        import hashlib
        c=client()
        with tempfile.TemporaryDirectory() as d, patch.object(nightly,'safe_private'):
            root=Path(d).resolve();run=root/'cancelled';run.mkdir();state=run/'state.json';state.write_text('{}');state.chmod(0o600)
            digest=hashlib.sha256(state.read_bytes()).hexdigest()
            proof=root/'proof';proof.write_text(json.dumps({'schema':1,'app_id':APP,
                'basis':'reviewed_inactive_legacy_reservations','cancelled_local_runs':{'cancelled':digest}}));proof.chmod(0o600)
            rule={'state_sha256':digest,'evidence_path':str(proof),'evidence_sha256':hashlib.sha256(proof.read_bytes()).hexdigest()}
            c.config['reconciled_local_runs']={'cancelled':rule}
            self.assertTrue(c.local_reconciled(state))
            state.write_text('{"changed":true}')
            with self.assertRaises(ValueError):c.local_reconciled(state)
            proof.write_text('{}')
            with self.assertRaises(ValueError):c.evidence(rule)

    def test_completed_delivery_reconciliation_requires_exact_terminal_readback(self):
        import hashlib
        c=client()
        with tempfile.TemporaryDirectory() as d, patch.object(nightly,'safe_private'):
            root=Path(d).resolve();run=root/'build14';run.mkdir();state=run/'state.json'
            value={'app_id':APP,'version':'0.1.7','build':14,'stage':'api_testing',
                   'api_readback':{'build_id':'build-id','internal_status':'IN_BETA_TESTING'}}
            release.write(state,value);digest=hashlib.sha256(state.read_bytes()).hexdigest()
            delivered={'state_sha256':digest,'app_id':APP,'version':'0.1.7','build':14,
                       'stage':'api_testing','build_id':'build-id','internal_status':'IN_BETA_TESTING'}
            proof=root/'proof';proof.write_text(json.dumps({'schema':1,'app_id':APP,
                'basis':'reviewed_inactive_legacy_reservations','delivered_local_runs':{'build14':delivered}}));proof.chmod(0o600)
            rule={'state_sha256':digest,'evidence_path':str(proof),
                  'evidence_sha256':hashlib.sha256(proof.read_bytes()).hexdigest()}
            c.config['reconciled_local_runs']={'build14':rule}
            self.assertTrue(c.local_reconciled(state))
            delivered['internal_status']='READY_FOR_BETA_TESTING'
            proof.write_text(json.dumps({'schema':1,'app_id':APP,
                'basis':'reviewed_inactive_legacy_reservations','delivered_local_runs':{'build14':delivered}}))
            rule['evidence_sha256']=hashlib.sha256(proof.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):c.local_reconciled(state)

    def test_daily_mutation_requires_exact_owner_active_day(self):
        with tempfile.TemporaryDirectory() as d, patch.object(nightly,'PRIVATE',Path(d)), patch.object(nightly,'safe_private'), patch.dict(os.environ,{'SESSION_ID':'owner'}):
            day=dt.datetime.now(nightly.ZoneInfo('Australia/Perth')).date().isoformat()
            p=Path(d)/'ledger.json';p.write_text(json.dumps({'schema':2,'days':{day:{'attempts':[{'owner':'other','status':'active'}]}}}))
            with self.assertRaises(ValueError):api.require_daily_claim()
            p.write_text(json.dumps({'schema':2,'days':{day:{'attempts':[{'owner':'owner','status':'active'}]}}}));api.require_daily_claim()
            p.write_text(json.dumps({'schema':2,'days':{day:{'attempts':[{'owner':'owner','status':'testing'}]}}}))
            with self.assertRaises(ValueError):api.require_daily_claim()

if __name__=='__main__':unittest.main()

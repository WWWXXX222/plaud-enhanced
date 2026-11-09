import base64
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
from urllib.error import HTTPError, URLError
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import backend as b
import openai_transcription as o
import openai_archive as a
import plaud_account as p

PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
FID='of_'+'a'*32


class OpenAIPipelineTests(unittest.TestCase):
    def test_network_diagnostic_keeps_type_without_sensitive_exception_text(self):
        secret = 'DUMMY-TEST-SECRET'
        with patch.object(o.request,'build_opener') as opener:
            opener.return_value.open.side_effect = URLError(ConnectionResetError(secret))
            with self.assertRaises(o.RetryableTranscriptionError) as caught:
                o.audio_request(self.dir/'imported.m4a',o.PRIMARY,[],secret)
        self.assertEqual(caught.exception.transport_error_type,'ConnectionResetError')
        self.assertNotIn(secret,str(caught.exception))

    def test_transcription_respects_the_users_configured_proxy(self):
        response=Mock(status=200,headers={'x-request-id':'test-only'})
        response.read.return_value=b'{"text":"original language"}'
        response.__enter__=Mock(return_value=response);response.__exit__=Mock(return_value=False)
        proxies={'https':'http://127.0.0.1:7897'}
        with patch.object(o.request,'getproxies',return_value=proxies), patch.object(o.request,'build_opener') as opener:
            opener.return_value.open.return_value=response
            result,receipt=o.audio_request(self.dir/'imported.m4a',o.PRIMARY,[],'DUMMY-TEST-KEY')
            handler=next(x for x in opener.call_args.args if isinstance(x,o.request.ProxyHandler))
            self.assertEqual(handler.proxies,proxies)
            self.assertTrue(any(isinstance(x,o.NoRedirect) for x in opener.call_args.args))
            self.assertEqual(result['text'],'original language')
            self.assertEqual(receipt['request_id'],'test-only')

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)
        self.dir=self.root/('mm_'+str(uuid.uuid4())); self.dir.mkdir(); self.vault=self.root/'vault'
        self.m=dict(id=self.dir.name,title='Synthetic bilingual test',created_at='2026-10-18T13:00:00-07:00',participants='Synthetic roles',purpose='Test only',notes='No real tasks',images=['images/test.png'],audio_files=['imported.m4a'],capture_state='captured',capture_mode='import',is_test=True,cloud_upload=True,source='Plaud',transcription_engine='openai',plaud_file_id=FID,plaud_account_id='account-A',include_plaud_summary=False,language='zh')
        b.atomic(self.dir/'meeting.json',self.m);b.atomic(self.dir/'images/test.png',PNG)
        b.atomic(self.dir/'imported.m4a',b'synthetic audio');b.atomic(self.dir/'plaud-upload.mp3',b'prepared audio')
        b.atomic(self.dir/'upload-audio.json',{})
        b.atomic(self.dir/'cloud-upload.json',dict(phase='complete',file_id=FID[3:],account_id='account-A',audio_sha256=b.digest(self.dir/'plaud-upload.mp3')))
        self.calls=[]
        self.patches=[patch.object(b,'duration',return_value=56.12),patch.object(p,'ACCOUNT_CACHE',self.root/'account.json'),
                      patch.object(p,'bridge',lambda vault: p.queue_module().Bridge(vault,self.root/'runtime',self.root/'absent.json'))]
        for item in self.patches:item.start()
    def tearDown(self):
        for item in self.patches:item.stop()
        self.tmp.cleanup()
    def caller(self,audio,model,fields,key):
        self.calls.append((model,fields))
        self.assertNotIn('prompt',dict(fields));self.assertNotIn('known_speaker_names',dict(fields))
        if model==o.PRIMARY:return {'text':'梅负责 rollback test。今天不要上线。','languages':[{'code':'zh'}]}, {'http_status':200,'request_id':'test-only'}
        return {'text':'没负责 rollback test。','segments':[{'start':0,'end':2,'speaker':'A','text':'没负责 rollback test。'}]}, {'http_status':200,'request_id':'test-only'}
    def ready(self):
        result=o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',self.caller)
        b.report(self.dir,'complete','test');return result
    def test_openai_without_plaud_uses_local_identity_and_no_upload_receipt(self):
        self.m.update(cloud_upload=False, source='MeetingMemory', plaud_file_id=None, plaud_account_id=None)
        b.atomic(self.dir/'meeting.json', self.m)
        (self.dir/'cloud-upload.json').unlink()
        self.ready()
        receipt=a.submit(self.dir,self.vault)
        self.assertEqual(receipt['file_id'],self.m['id'])
        self.assertFalse((Path(receipt['raw_dir'])/'plaud-upload-receipt.json').exists())
        self.assertEqual(a.submit(self.dir,self.vault),receipt)

    def test_manual_speaker_notes_archive_once_without_rewriting_evidence(self):
        self.ready()
        original=(self.dir/'transcript.txt').read_bytes()
        annotation=dict(label='A',name='Alex',source='timeline',start=0,end=2,
            text_sha256='a'*64,scope='segment',updated_at='test')
        b.atomic(self.dir/'speaker-annotations.json',dict(version=1,meeting_id=self.m['id'],segments={'timeline:fixture':annotation},groups={}))
        receipt=a.submit(self.dir,self.vault)
        job=b.read(receipt['job_path']);raw=Path(receipt['raw_dir'])
        self.assertIn('Alex',job['context']['notes']);self.assertIn('user-manual',job['context']['notes'])
        self.assertFalse(job['context']['speaker_identity_verified'])
        self.assertEqual((raw/'transcript.txt').read_bytes(),original)
        before=(raw/'context.json').read_bytes()
        annotation['name']='Changed later'
        b.atomic(self.dir/'speaker-annotations.json',dict(version=1,meeting_id=self.m['id'],segments={'timeline:fixture':annotation},groups={}))
        self.assertEqual(a.submit(self.dir,self.vault),receipt)
        self.assertEqual((raw/'context.json').read_bytes(),before)
        self.assertEqual(len(list(self.vault.glob('meeting-inbox/plaud/*/job.json'))),1)

    def test_original_text_and_uncertain_timeline_stay_separate(self):
        result=self.ready()
        self.assertEqual((self.dir/'transcript.txt').read_text(),'梅负责 rollback test。今天不要上线。\n')
        self.assertEqual(result['text'],'梅负责 rollback test。今天不要上线。')
        self.assertEqual(result['segments'][0]['text'],'没负责 rollback test。')
        self.assertEqual(result['segments'][0]['speaker_status'],'unconfirmed')
        self.assertIn('待确认',result['segments'][0]['speaker'])
        self.assertIn('not_alignment',result['timestamp_role'])
    def test_resume_reuses_both_successful_calls_without_charges(self):
        self.ready();self.calls=[];self.ready();self.assertEqual(self.calls,[])
    def test_missing_reference_preserves_original_text_and_archives_uncertainty_evidence(self):
        evidence='openai/fixture-vad-proof.json'
        b.atomic(self.dir/evidence,dict(no_speech_detected=False,transcription=[]))
        def caller(audio,model,fields,key):
            if model==o.TIMELINE:return {'text':'','segments':[]},{'http_status':200}
            return self.caller(audio,model,fields,key)
        with patch.object(o,'verify_no_speech',return_value=dict(no_speech_detected=False,evidence_files=[evidence])):
            result=o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',caller)
        self.assertEqual(result['text'],'梅负责 rollback test。今天不要上线。')
        self.assertEqual(result['coverage'][0]['status'],'transcribed')
        gap=result['segments'][0]
        self.assertEqual(gap['role'],'unresolved_listening_reference')
        self.assertEqual(gap['speaker_status'],'unconfirmed')
        self.assertEqual(gap['timestamp_status'],'audio_window_only')
        self.assertIn('系统标注',gap['text'])
        self.assertEqual(len(result['reference_gaps']),1)
        self.assertEqual(result['reference_gaps'][0]['end_seconds'],56.12)
        b.report(self.dir,'complete','test')
        receipt=b.submit(self.dir,self.vault)
        raw=Path(receipt['raw_dir']);manifest=b.read(raw/'manifest.json')
        self.assertEqual(b.read(raw/'transcript.json')['reference_gaps'],result['reference_gaps'])
        self.assertEqual(manifest['sha256'][evidence],b.digest(self.dir/evidence))
        self.assertEqual((raw/'transcript.txt').read_text(),'梅负责 rollback test。今天不要上线。\n')
    def test_timeline_failure_resumes_without_repeating_primary(self):
        def fail(audio,model,fields,key):
            if model==o.TIMELINE:raise ValueError('simulated interruption')
            return self.caller(audio,model,fields,key)
        with self.assertRaises(ValueError):o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',fail)
        self.assertFalse((self.dir/'transcript.json').exists())
        self.calls=[];self.ready();self.assertEqual([c[0] for c in self.calls],[o.TIMELINE])
    def test_claim_preserves_provenance_and_summary_off(self):
        self.ready();b.atomic(self.dir/'plaud-summary.md','Must not archive this cached summary')
        receipt=b.submit(self.dir,self.vault);self.assertEqual(b.submit(self.dir,self.vault),receipt)
        q=p.bridge(self.vault);job=q.claim(FID);raw=Path(job['raw_dir']);manifest=b.read(raw/'manifest.json')
        self.assertEqual(manifest['source'],'OpenAI');self.assertEqual(manifest['primary_model'],o.PRIMARY)
        self.assertEqual(manifest['speaker_status'],'unconfirmed');self.assertIn('not_alignment',manifest['timestamp_role'])
        self.assertIsNone(manifest['plaud_summary']);self.assertFalse((raw/'plaud-summary.md').exists())
        self.assertEqual((raw/'transcript.txt').read_bytes(),(self.dir/'transcript.txt').read_bytes())
        analysis=raw/'analysis.md';digest=self.vault/'digest.md';b.atomic(analysis,'Synthetic test analysis');b.atomic(digest,'Synthetic test digest')
        q.finish(FID,[analysis,digest]);self.assertEqual(b.read(q.job_path(FID))['state'],'done')
    def test_missing_image_or_changed_text_never_publishes(self):
        self.ready();self.m['images']=[];b.atomic(self.dir/'meeting.json',self.m)
        with self.assertRaises(ValueError):b.submit(self.dir,self.vault)
        self.m['images']=['images/test.png'];b.atomic(self.dir/'meeting.json',self.m);b.atomic(self.dir/'transcript.txt','edited')
        with self.assertRaises(ValueError):b.submit(self.dir,self.vault)
        self.assertFalse((self.vault/'meeting-inbox/plaud'/FID/'job.json').exists())
    def test_history_never_fetches_plaud_transcript_over_openai(self):
        self.ready();client=Mock()
        client.account.return_value={'id':'account-A'}
        client.detail.return_value={'id':FID,'duration':'56s','name':'Test','transcript':'available','summary':'available'}
        before=(self.dir/'transcript.txt').read_bytes()
        p.import_recording(FID,'account-A',client,self.vault,self.root)
        client.run.assert_not_called();self.assertEqual((self.dir/'transcript.txt').read_bytes(),before)
        receipt=b.submit(self.dir,self.vault)
        result=p.import_recording(FID,'account-A',client,self.vault,self.root/'fresh')
        fresh=self.root/'fresh'/result['meeting']['id']
        self.assertEqual(result['meeting']['transcription_engine'],'openai')
        self.assertEqual((fresh/'transcript.txt').read_bytes(),before);client.run.assert_not_called()
    def test_oversized_or_nonfinite_timestamps_rejected(self):
        for end in (999,float('nan')):
            with self.assertRaises(ValueError):o.reference_segments({'segments':[{'start':0,'end':end,'speaker':'A','text':'test'}]},0,56,0,False)
    def test_chunk_labels_never_claim_cross_chunk_identity(self):
        raw={'segments':[{'start':1,'end':2,'speaker':'A','text':'hello'}]}
        segment=o.reference_segments(raw,90,56,1,True)[0]
        self.assertEqual(segment['start_seconds'],91)
        self.assertEqual(segment['speaker'],'第 2 段 · 说话人 A（待确认）')
    def test_provider_error_does_not_echo_key(self):
        secret='sk-DUMMY-TEST-NOT-A-KEY'
        failure=HTTPError(o.ENDPOINT,401,'bad',{},io.BytesIO(json.dumps({'error':{'message':secret,'code':'invalid_api_key'}}).encode()))
        with patch.object(o.request,'build_opener') as opener:
            opener.return_value.open.side_effect=failure
            with self.assertRaises(ValueError) as caught:o.audio_request(self.dir/'imported.m4a',o.PRIMARY,[],secret)
        self.assertNotIn(secret,str(caught.exception))


if __name__=='__main__':unittest.main()

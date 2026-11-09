import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import backend as b
import plaud_account as p

PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
FID='of_0123456789abcdef0123456789abcdef'
TRANSCRIPT='[00:01 - 00:04] Speaker 1: Simulated meeting.\n[00:05] Speaker 2: Test only.\n'
class FakeClient:
    def __init__(self,identity='account-A',available=True):self.identity=identity;self.available=available;self.summary_available=True;self.calls=[]
    def account(self):return dict(id=self.identity,name='Test account',email='test@example.invalid',connected=True,checked_at='2026-10-17')
    def detail(self,fid):return dict(id=fid,name='Original title',created_at='2026-10-17T12:00:00',start_at='2026-10-17T12:00:00',duration='10s',transcript='available' if self.available else 'unavailable',summary='available' if self.available and self.summary_available else 'unavailable')
    def run(self,*args,**kwargs):
        self.calls.append(args[0])
        if args[0]=='file':return '\n'.join(f'  {k}: {v}' for k,v in self.detail(args[1]).items())
        if args[0] in ['transcript','summary']:
            Path(args[args.index('-o')+1]).write_text(TRANSCRIPT if args[0]=='transcript' else '# Original Plaud summary\nTest only.\n');return ''
        raise AssertionError(args)

class PlaudIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.vault=self.root/'vault';self.client=FakeClient()
        self.cache=patch.object(p,'ACCOUNT_CACHE',self.root/'account.json');self.cache.start()
        self.factory=p.bridge
        def bridge(vault=self.vault):
            q=self.factory(vault);q.cli_run=self.client.run;return q
        self.bridgepatch=patch.object(p,'bridge',bridge);self.bridgepatch.start()
    def tearDown(self):self.bridgepatch.stop();self.cache.stop();self.tmp.cleanup()
    def load(self):
        r=p.import_recording(FID,'account-A',self.client,self.vault,self.root/'meetings')
        return self.root/'meetings'/r['meeting']['id']
    def context(self,d):
        m=b.read(d/'meeting.json');m.update(participants='Test reader',purpose='Simulated adapter test',notes='Do not create real tasks',images=['images/test.png']);b.atomic(d/'meeting.json',m);b.atomic(d/'images/test.png',PNG)
    def test_manual_speaker_annotations_reach_plaud_context(self):
        d=self.load();self.context(d)
        value=dict(label='B',name='梅',source='system',start=1,end=4,text_sha256='a'*64,scope='segment',updated_at='test')
        b.atomic(d/'speaker-annotations.json',dict(version=1,meeting_id=d.name,segments={'live:fixture':value},groups={}))
        receipt=p.submit(d,self.vault,self.client)
        self.assertIn('梅',b.read(receipt['job_path'])['context']['notes'])
        self.assertEqual((Path(receipt['raw_dir'])/'transcript.txt').read_text(),TRANSCRIPT)
        self.assertEqual(p.submit(d,self.vault,self.client),receipt)

    def test_list_parsing_and_pagination(self):
        text='Files on this page: 2\n  '+FID+'  A name with  spaces…                  2026-10-17    1h02m\n  of_abcdef0123456789abcdef0123456789  第二条录音                            2026-10-16    3m12s\nPage 1\n'
        result=p.parse_files(text,1,2);self.assertEqual(len(result['records']),2);self.assertTrue(result['has_more']);self.assertIn('spaces',result['records'][0]['title'])
        with self.assertRaises(p.PlaudError):p.parse_files(text.replace('page: 2','page: 3'),1,2)
    def test_import_is_idempotent_and_never_queues_without_context(self):
        d=self.load();self.context(d);again=self.load();self.assertEqual(d,again)
        self.assertEqual(b.read(d/'meeting.json')['purpose'],'Simulated adapter test')
        self.assertEqual(b.read(d/'transcript.json')['segments'][1]['end_seconds'],None)
        self.assertEqual(b.read(d/'transcript.json')['segments'][0]['speaker'],'Speaker 1')
        self.assertEqual(b.read(d/'progress.json')['state'],'complete')
        self.assertFalse(list((self.vault/'meeting-inbox').glob('**/job.json')))
    def test_default_sends_transcript_without_waiting_for_summary(self):
        self.client.summary_available=False
        d=self.load();self.context(d)
        self.assertEqual(b.read(d/'progress.json')['state'],'complete')
        receipt=p.submit(d,self.vault,self.client);q=p.bridge(self.vault);q.claim(FID)
        raw=Path(receipt['raw_dir']);manifest=b.read(raw/'manifest.json')
        self.assertFalse(manifest['include_plaud_summary']);self.assertIsNone(manifest['plaud_summary'])
        self.assertFalse((raw/'plaud-summary.md').exists());self.assertNotIn('summary',self.client.calls)
        fresh=p.import_recording(FID,'account-A',self.client,self.vault,self.root/'fresh')['meeting']
        self.assertFalse(fresh['include_plaud_summary'])
        self.assertTrue((self.root/'fresh'/fresh['id']/'transcript.txt').exists())

    def test_view_only_does_not_send_cached_summary(self):
        d=self.load();self.context(d);p.view_summary(d,self.client)
        self.assertTrue((d/'plaud-summary.md').exists())
        self.assertFalse(b.read(d/'meeting.json')['include_plaud_summary'])
        self.client.calls=[];receipt=p.submit(d,self.vault,self.client)
        self.assertFalse((Path(receipt['raw_dir'])/'plaud-summary.md').exists())
        self.assertNotIn('summary',self.client.calls)

    def test_opt_in_waits_until_summary_ready_and_opt_out_unblocks(self):
        self.client.summary_available=False;d=self.load();self.context(d)
        m=b.read(d/'meeting.json');m['include_plaud_summary']=True;b.atomic(d/'meeting.json',m)
        p.refresh_recording(d,self.client)
        self.assertEqual(b.read(d/'progress.json')['state'],'waiting_plaud')
        with self.assertRaises(p.PlaudError):p.submit(d,self.vault,self.client)
        m['include_plaud_summary']=False;b.atomic(d/'meeting.json',m);p.refresh_recording(d,self.client)
        self.assertEqual(b.read(d/'progress.json')['state'],'complete')

    def test_account_switch_is_rejected_before_copy(self):
        with self.assertRaises(p.PlaudError):p.import_recording(FID,'other-account',self.client,self.vault,self.root/'meetings')
        self.assertFalse((self.root/'meetings').exists())
        self.assertNotEqual(p.local_id('a',FID),p.local_id('b',FID))
    def test_waiting_recording_never_becomes_ready(self):
        self.client.available=False;d=self.load();self.context(d)
        self.assertEqual(b.read(d/'progress.json')['state'],'waiting_plaud')
        with self.assertRaises(p.PlaudError):p.submit(d,self.vault,self.client)
        self.assertFalse(list((self.vault/'meeting-inbox').glob('**/job.json')))
    def test_submit_uses_canonical_id_and_retains_originals(self):
        d=self.load();self.context(d)
        m=b.read(d/'meeting.json');m['include_plaud_summary']=True;b.atomic(d/'meeting.json',m);p.refresh_recording(d,self.client)
        receipt=p.submit(d,self.vault,self.client)
        job=b.read(receipt['job_path']);self.assertEqual(job['file_id'],FID);self.assertEqual(job['state'],'ready')
        raw=Path(receipt['raw_dir']);self.assertEqual((raw/'transcript.txt').read_text(),TRANSCRIPT);self.assertIn('Original Plaud summary',(raw/'plaud-summary.md').read_text())
        self.assertEqual(p.submit(d,self.vault,self.client),receipt)
        self.assertEqual(len(list((self.vault/'meeting-inbox/plaud').glob('*/job.json'))),1)
        self.assertEqual(job['context']['participants'],'Test reader')
    def test_existing_archive_reconnects_without_overwrite(self):
        d=self.load();self.context(d);receipt=p.submit(d,self.vault,self.client);job=b.read(receipt['job_path']);job.update(state='done',outputs=['existing-analysis.md']);b.atomic(Path(receipt['job_path']),job)
        before=Path(receipt['job_path']).read_bytes();r=p.import_recording(FID,'account-A',self.client,self.vault,self.root/'fresh')
        fresh=self.root/'fresh'/r['meeting']['id'];self.assertTrue((fresh/'submission.json').exists());self.assertEqual(Path(receipt['job_path']).read_bytes(),before)
        self.assertEqual(r['meeting']['participants'],'Test reader');self.assertEqual(len(r['meeting']['images']),1)
    def test_traversal_image_never_reaches_queue(self):
        d=self.load();self.context(d);m=b.read(d/'meeting.json');m['images']=['../outside.png'];b.atomic(d/'meeting.json',m);(d.parent/'outside.png').write_bytes(PNG)
        with self.assertRaises(ValueError):p.submit(d,self.vault,self.client)
        self.assertFalse(list((self.vault/'meeting-inbox').glob('**/job.json')))
    def test_cli_failure_never_exposes_stderr_or_credentials(self):
        def failed(*args,**kwargs):return subprocess.CompletedProcess(args,2,stdout='',stderr='secret credential must not escape')
        with self.assertRaises(p.PlaudError) as exc:p.Client(failed).account()
        self.assertNotIn('secret',str(exc.exception));self.assertIn('授权',str(exc.exception))

    def test_uploaded_recording_reopens_in_original_folder_and_test_flag_reaches_manifest(self):
        d=self.load();self.context(d)
        m=b.read(d/'meeting.json');m.update(is_test=True,cloud_upload=True);b.atomic(d/'meeting.json',m)
        moved=d.with_name('mm_11111111-2222-3333-4444-555555555555');d.rename(moved)
        m['id']=moved.name;b.atomic(moved/'meeting.json',m)
        result=p.import_recording(FID,'account-A',self.client,self.vault,self.root/'meetings')
        self.assertEqual(result['meeting']['id'],moved.name)
        receipt=p.submit(moved,self.vault,self.client)
        job=b.read(receipt['job_path']);self.assertTrue(job['is_test'])
        p.bridge(self.vault).claim(FID)
        self.assertTrue(b.read(Path(receipt['raw_dir'])/'manifest.json')['is_test'])

if __name__=='__main__':unittest.main()

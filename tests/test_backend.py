import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import backend as b
spec=importlib.util.spec_from_file_location('queue_bridge',Path(__file__).resolve().parents[1]/'bridge.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')

class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.id='mm_'+str(uuid.uuid4());self.dir=self.root/self.id;self.dir.mkdir()
        self.vault=self.root/'vault'
        self.m=dict(id=self.id,title='SIMULATED TEST',created_at='2026-10-17T12:00:00-07:00',participants='Test reader',purpose='Test only',notes='No real actions',images=['images/test.png'],audio_files=['microphone.caf'],capture_state='captured',is_test=True)
        b.atomic(self.dir/'meeting.json',self.m);b.atomic(self.dir/'progress.json',dict(state='complete'))
        b.atomic(self.dir/'images/test.png',PNG)
        for name in ['transcript.txt','audio.wav','microphone.caf','whisper-original.json']:b.atomic(self.dir/name,'test fixture')
        b.atomic(self.dir/'transcript.json',dict(duration=1,segments=[dict(start_seconds=0,end_seconds=1,text='Test')]))
    def tearDown(self):self.tmp.cleanup()
    def test_native_source_flows_through_existing_queue(self):
        receipt=b.submit(self.dir,self.vault)
        self.assertEqual(b.submit(self.dir,self.vault),receipt)
        q=bridge.Bridge(self.vault,self.root/'runtime',self.root/'missing.json');self.assertEqual(len(q.ready()),1)
        j=q.claim(self.id);self.assertEqual(j['source'],'MeetingMemory')
        manifest=b.read(Path(j['raw_dir'])/'manifest.json')
        self.assertIsNone(manifest['upstream_summary']);self.assertTrue(manifest['is_test']);self.assertIn('audio.wav',manifest['sha256'])
        self.assertEqual(b.read(Path(j['raw_dir'])/'meeting-metadata.json')['duration'],1)
        analysis=Path(j['raw_dir'])/'analysis.md';digest=self.vault/'source.md';analysis.write_text('Test analysis');digest.write_text('Test digest')
        q.finish(self.id,[analysis,digest]);self.assertEqual(q.jobs()[0]['state'],'done');self.assertEqual(q.ready(),[])
        self.assertTrue((Path(receipt['raw_dir'])/'images'/manifest['images'][0].split('/')[-1]).exists())
    def test_no_ready_job_when_required_data_missing(self):
        for field in ['participants','purpose','images']:
            m=dict(self.m);m[field]=[] if field=='images' else '';b.atomic(self.dir/'meeting.json',m)
            with self.assertRaises(ValueError):b.submit(self.dir,self.vault)
            self.assertFalse((self.vault/'meeting-inbox/plaud'/self.id/'job.json').exists())
    def test_incomplete_transcript_never_submits(self):
        b.atomic(self.dir/'progress.json',dict(state='processing'))
        with self.assertRaises(ValueError):b.submit(self.dir,self.vault)
    def test_paths_do_not_escape_meeting(self):
        outside=self.root/'outside.png';outside.write_bytes(PNG);self.m['images']=['../outside.png'];b.atomic(self.dir/'meeting.json',self.m)
        with self.assertRaises(ValueError):b.submit(self.dir,self.vault)
    def test_timestamp_validation(self):
        raw=dict(transcription=[dict(offsets={'from':1230,'to':2700},text='hello')])
        self.assertEqual(b.normalize_segments(raw,3)[0]['start_seconds'],1.23)
        raw['transcription'][0]['offsets']['to']=9000
        with self.assertRaises(ValueError):b.normalize_segments(raw,3)
        with self.assertRaises(ValueError):b.normalize_segments({'transcription':[]},3)

if __name__=='__main__':unittest.main()

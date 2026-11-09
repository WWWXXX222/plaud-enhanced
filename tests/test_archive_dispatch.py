import concurrent.futures
import tempfile
from pathlib import Path
import unittest
import uuid
from unittest.mock import patch
import backend as b
import archive_dispatch as a

class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name).resolve()
        self.id='mm_'+str(uuid.uuid4());self.meeting=self.root/'data/meetings'/self.id;self.vault=self.root/'vault'
        self.fid='of_'+'b'*32;self.job=self.vault/'meeting-inbox/plaud'/self.fid/'job.json'
        b.atomic(self.meeting/'meeting.json',dict(id=self.id,auto_archive=True,capture_state='captured',created_at='2026-10-21T12:00:00Z'))
        b.atomic(self.meeting/'submission.json',dict(file_id=self.fid,job_path=str(self.job)))
        b.atomic(self.job,dict(state='ready',assets_ready=True,local_meeting_id=self.id))
    def tearDown(self):self.tmp.cleanup()
    def test_repeated_publish_does_not_queue_or_create_writers(self):
        with patch('subprocess.Popen',side_effect=AssertionError('must not spawn')),patch('subprocess.run',side_effect=AssertionError('must not enqueue')):
            first=a.dispatch(self.meeting,self.vault);path=self.meeting/'archive-trigger.json';stamp=path.stat().st_mtime_ns
            for _ in range(50):self.assertEqual(a.dispatch(self.meeting,self.vault),first)
            self.assertEqual(path.stat().st_mtime_ns,stamp)
        self.assertEqual(first['state'],'native_ready');self.assertEqual(first['attempts'],0)
    def test_legacy_retry_receipt_migrates_once(self):
        event=__import__('hashlib').sha256((a.THREAD_ID+'|'+self.fid).encode()).hexdigest()[:24]
        b.atomic(self.meeting/'archive-trigger.json',dict(event_id=event,backend='exec-resume-v1',state='pending',attempts=41,retry_at=9999999999))
        s=a.dispatch(self.meeting,self.vault);self.assertEqual(s['state'],'native_ready');self.assertEqual(s['previous_attempts'],41)
        self.assertEqual(s['retry_at'],0)
        j=b.read(self.job);j['state']='processing';b.atomic(self.job,j)
        self.assertEqual(a.dispatch(self.meeting,self.vault)['previous_attempts'],41)
    def test_wrong_receipt_cannot_start_or_overwrite(self):
        b.atomic(self.meeting/'submission.json',dict(file_id=self.fid,job_path=str(self.root/'other.json')))
        with self.assertRaises(ValueError):a.dispatch(self.meeting,self.vault)
        self.assertFalse((self.meeting/'archive-trigger.json').exists())
    def test_source_identity_must_match(self):
        j=b.read(self.job);j['local_meeting_id']='different';b.atomic(self.job,j)
        with self.assertRaises(ValueError):a.dispatch(self.meeting,self.vault)
    def test_native_receipt_tracks_canonical_processing_and_done(self):
        for source,target in [('ready','native_ready'),('processing','native_processing'),('done','done')]:
            j=b.read(self.job);j['state']=source;b.atomic(self.job,j)
            self.assertEqual(a.dispatch(self.meeting,self.vault)['state'],target)
        self.assertEqual(a.native_pending(self.root,self.vault)['jobs'],[])
    def test_incomplete_assets_do_not_publish(self):
        j=b.read(self.job);j['assets_ready']=False;b.atomic(self.job,j)
        self.assertEqual(a.dispatch(self.meeting,self.vault),{})
        self.assertEqual(a.native_pending(self.root,self.vault)['jobs'],[])
    def test_interrupted_processing_is_returned_under_same_id(self):
        j=b.read(self.job);j['state']='processing';b.atomic(self.job,j)
        jobs=a.native_pending(self.root,self.vault)['jobs']
        self.assertEqual(len(jobs),1);self.assertEqual(jobs[0]['file_id'],self.fid);self.assertEqual(jobs[0]['state'],'processing')
    def test_native_check_only_reads_app_files(self):
        with patch.object(b,'lock',side_effect=AssertionError('native reader must not need app-directory write access')):
            result=a.native_pending(self.root,self.vault)
        self.assertEqual(len(result['jobs']),1);self.assertEqual(result['errors'],[])
        self.assertFalse((self.meeting/'archive-trigger.json').exists())
    def test_unsubmitted_historical_and_unfinished_capture_are_excluded(self):
        m=b.read(self.meeting/'meeting.json');m['capture_state']='recording';b.atomic(self.meeting/'meeting.json',m)
        self.assertEqual(a.native_pending(self.root,self.vault)['jobs'],[])
        m.update(auto_archive=False,capture_state='captured');b.atomic(self.meeting/'meeting.json',m)
        (self.meeting/'submission.json').unlink()
        self.assertEqual(a.native_pending(self.root,self.vault)['jobs'],[])
    def test_explicit_historical_submission_is_consumed_once(self):
        m=b.read(self.meeting/'meeting.json');m['auto_archive']=False;b.atomic(self.meeting/'meeting.json',m)
        jobs=a.native_pending(self.root,self.vault)['jobs']
        self.assertEqual([j['file_id'] for j in jobs],[self.fid])
        j=b.read(self.job);j['state']='done';b.atomic(self.job,j)
        self.assertEqual(a.native_pending(self.root,self.vault)['jobs'],[])
    def test_invalid_material_receipt_surfaces_an_actionable_error(self):
        b.atomic(self.meeting/'submission.json',dict(file_id=self.fid,job_path='/tmp/wrong-job.json'))
        result=a.native_pending(self.root,self.vault)
        self.assertEqual(len(result['errors']),1);self.assertEqual(result['jobs'],[])
    def test_concurrent_refreshes_share_one_unchanged_event(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            results=list(pool.map(lambda _:a.dispatch(self.meeting,self.vault),range(40)))
        self.assertTrue(all(r==results[0] for r in results));self.assertEqual(results[0]['attempts'],0)

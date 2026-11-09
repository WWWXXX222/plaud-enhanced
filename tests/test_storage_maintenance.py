import json
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import backend as b
import archive_runner as runner
import retained_evidence as ev
import storage_maintenance as storage


class StorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.audio_tmp = tempfile.TemporaryDirectory()
        cls.audio = Path(cls.audio_tmp.name)/'sample.mp3'
        subprocess.run([str(b.FFMPEG), '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
                        '-ar', '32000', '-ac', '1', '-b:a', '96k', str(cls.audio)], check=True)
        cls.duration = b.duration(cls.audio)

    @classmethod
    def tearDownClass(cls): cls.audio_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve(); self.vault = self.root/'vault'
        self.mid = 'mm_' + str(uuid.uuid4()); self.fid = 'of_' + uuid.uuid4().hex
        self.directory = self.root/'data/meetings'/self.mid
        self.raw = self.vault/'personal-memory/raw-inputs/work/openai'/self.fid
        self.jobpath = self.vault/'meeting-inbox/plaud'/self.fid/'job.json'
        # Production completion stamps have second precision. Keep boundary
        # fixtures exact rather than rounding through ISO microseconds.
        self.now = int(time.time())
        self.completed = self.now - 2*86400
        self.m = dict(id=self.mid, capture_state='captured', cloud_upload=True, plaud_file_id=self.fid,
                      plaud_account_id='test-account', audio_files=['microphone.caf','system.caf'], auto_archive=True)
        b.atomic(self.directory/'meeting.json', self.m)
        b.atomic(self.directory/'progress.json', dict(state='complete'))
        hashes = {}
        self.files = {'microphone.caf':b'microphone original', 'system.caf':b'system original',
                      'transcript.txt':'今天不发布。Do not ship today.', 'transcript.json':'{}',
                      'transcript-timeline.md':'[00:00:01] 说话人待确认', 'context.json':'{}',
                      'meeting-metadata.json':'{}', 'openai/generation/audio-0000.mp3':b'chunk audio',
                      'openai/generation/0000-result.json':'{"text":"今天不发布"}',
                      'documents/document.pdf':b'protected document', 'images/image.png':b'protected image'}
        for name, payload in self.files.items():
            b.atomic(self.directory/name, payload); b.copy_atomic(self.directory/name, self.raw/name)
            hashes[name] = b.digest(self.raw/name)
        for base in [self.directory,self.raw]: b.copy_atomic(self.audio,base/'plaud-upload.mp3')
        self.audio_hash = b.digest(self.audio); hashes['plaud-upload.mp3'] = self.audio_hash
        b.atomic(self.directory/'upload-audio.json',dict(duration=self.duration,sha256=self.audio_hash))
        b.atomic(self.directory/'cloud-upload.json',dict(phase='complete',file_id=self.fid[3:],account_id='test-account',audio_sha256=self.audio_hash))
        self.manifest = dict(file_id=self.fid, local_meeting_id=self.mid, audio='plaud-upload.mp3',transcript='transcript.txt',
                             transcript_json='transcript.json',timeline='transcript-timeline.md',metadata='meeting-metadata.json',
                             context='context.json',sha256=hashes,include_plaud_summary=False)
        b.atomic(self.raw/'manifest.json',self.manifest)
        self.summary = self.vault/'personal-memory/knowledge-catalog/sources/test.md'
        for p in [self.raw/'analysis.md',self.raw/'retrieval-notes.md',self.summary]: b.atomic(p,'# Simulated result\n今天不发布。')
        self.job = dict(file_id=self.fid,local_meeting_id=self.mid,state='done',raw_dir=str(self.raw),
                        completed_at=self.iso(self.completed),outputs=[str(self.raw/'analysis.md'),str(self.summary)],
                        include_plaud_summary=False)
        b.atomic(self.jobpath,self.job)
        b.atomic(self.directory/'archive-trigger.json',dict(state='done'))
        self.submission = dict(file_id=self.fid,job_path=str(self.jobpath),raw_dir=str(self.raw))
        b.atomic(self.directory/'submission.json',self.submission)
        _, hashes = runner.evidence(self.job,self.vault)
        b.atomic(self.directory/'archive-evidence.json',dict(raw_dir=str(self.raw),sha256=hashes))
        self.manifest_before = (self.raw/'manifest.json').read_bytes()

    def tearDown(self): self.tmp.cleanup()
    def iso(self,stamp): return __import__('datetime').datetime.fromtimestamp(stamp,__import__('datetime').timezone.utc).isoformat()
    def run_cleanup(self,**kw): return storage.run(self.root,self.vault,now=self.now,**kw)
    def ctx(self): return storage.context(self.directory,self.vault,storage.settings(self.root),self.now)
    def validate(self):
        saved=b.read(self.directory/'archive-evidence.json')
        self.assertTrue(runner.validate_completion(b.read(self.jobpath),self.vault,self.raw,saved['sha256']))
        self.assertEqual((self.raw/'manifest.json').read_bytes(),self.manifest_before)
        self.assertEqual(b.read(self.directory/'submission.json'),self.submission)
        for name in ['transcript.txt','transcript.json','transcript-timeline.md','documents/document.pdf','images/image.png']:
            self.assertEqual(b.digest(self.raw/name),self.manifest['sha256'][name])
            self.assertEqual(b.digest(self.directory/name),self.manifest['sha256'][name])
        self.assertEqual(b.digest(self.directory/'plaud-upload.mp3'),self.audio_hash)
        self.assertEqual(b.digest(self.raw/'plaud-upload.mp3'),self.audio_hash)

    def test_default_scan_is_read_only_and_dedup_preserves_original(self):
        report=storage.scan(self.root,self.vault,self.now)
        self.assertTrue(report['enabled']);self.assertEqual(report['raw_retention_days'],7)
        self.assertGreater(report['candidate_bytes'],0);self.assertTrue((self.directory/'system.caf').exists())
        before=b.read(self.directory/'meeting.json')
        result=self.run_cleanup();self.assertGreater(result['cleaned_bytes'],0)
        self.assertFalse((self.directory/'system.caf').exists());self.assertTrue((self.raw/'system.caf').exists())
        self.assertFalse((self.raw/'openai/generation/audio-0000.mp3').exists())
        self.assertTrue((self.raw/'openai/generation/0000-result.json').exists())
        self.assertEqual(b.read(self.directory/'meeting.json'),before);self.validate()
        again=self.run_cleanup();self.assertEqual(again['cleaned_bytes'],0)

    def test_expired_raw_and_cache_retirement_is_validated(self):
        self.job['completed_at']=self.iso(self.now-8*86400);b.atomic(self.jobpath,self.job)
        self.run_cleanup()
        for base in [self.directory,self.raw]:
            for name in ev.RAW_TRACKS:self.assertFalse((base/name).exists())
        self.validate()
        with self.assertRaises(ValueError):storage.pin(self.root,self.directory,True,self.vault)

    def test_pin_and_forever_keep_one_original(self):
        self.job['completed_at']=self.iso(self.now-40*86400);b.atomic(self.jobpath,self.job)
        storage.pin(self.root,self.directory,True,self.vault)
        self.run_cleanup();self.assertTrue((self.raw/'system.caf').exists());self.validate()
        storage.pin(self.root,self.directory,False,self.vault)
        storage.configure(self.root,True,0)
        self.run_cleanup();self.assertTrue((self.raw/'system.caf').exists())
        storage.configure(self.root,True,30)
        self.run_cleanup();self.assertFalse((self.raw/'system.caf').exists());self.validate()

    def test_retention_begins_at_archive_completion_and_boundary(self):
        self.job['completed_at']=self.iso(self.now-7*86400+1);b.atomic(self.jobpath,self.job)
        self.run_cleanup();self.assertTrue((self.raw/'system.caf').exists())
        storage.run(self.root,self.vault,now=self.now+1)
        self.assertFalse((self.raw/'system.caf').exists());self.validate()

    def test_longer_retention_after_interruption_is_honored(self):
        self.job['completed_at']=self.iso(self.now-8*86400);b.atomic(self.jobpath,self.job)
        ctx=self.ctx();storage.prepare_plan(ctx,storage.candidates(ctx),self.now)
        storage.configure(self.root,True,30)
        self.run_cleanup()
        self.assertTrue((self.raw/'system.caf').exists())
        self.assertFalse((self.directory/'system.caf').exists())
        self.validate()
        self.assertEqual(b.read(self.directory/storage.PLAN)['state'],'done')

    def test_safe_path_accepts_string_roots_without_looping(self):
        self.assertEqual(ev.safe_path(str(self.raw),'system.caf'),self.raw/'system.caf')

    def test_recording_any_meeting_defers_cleanup(self):
        other=self.root/'data/meetings'/('mm_'+str(uuid.uuid4()))
        b.atomic(other/'meeting.json',dict(id=other.name,capture_state='recording'))
        result=self.run_cleanup()
        self.assertEqual(result['cleaned_bytes'],0);self.assertIn('录音',result['message'])
        self.assertTrue((self.directory/'system.caf').exists())

    def test_incomplete_upload_transcript_or_archive_are_never_deleted(self):
        for path,key,value in [(self.directory/'cloud-upload.json','phase','uploading'),
                               (self.directory/'progress.json','state','processing'),
                               (self.jobpath,'state','processing'),(self.directory/'archive-trigger.json','state','running')]:
            before=b.read(path);b.atomic(path,dict(before,**{key:value}))
            self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)
            self.assertTrue((self.directory/'system.caf').exists());b.atomic(path,before)

    def test_lock_and_disabled_automatic_do_not_remove(self):
        for name in ['.processing.lock','.archive-run.lock']:
            with b.lock(self.directory/name): self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)
        with b.lock(self.root/'.storage.lock'):self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)
        storage.configure(self.root,False,7)
        self.assertEqual(self.run_cleanup(automatic=True)['cleaned_bytes'],0)
        self.assertTrue((self.directory/'system.caf').exists())

    def test_installer_defers_while_storage_worker_owns_lock(self):
        import app_signing
        with b.lock(self.root/'.storage.lock'), patch.object(app_signing,'require_quiet'):
            with self.assertRaises(RuntimeError):
                with app_signing.installation_window(self.root,[]): pass

    def test_duplicate_hash_mismatch_or_missing_compressed_copy_blocks_all_removal(self):
        original=(self.directory/'system.caf').read_bytes()
        b.atomic(self.directory/'system.caf',b'different bytes')
        self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)
        self.assertTrue((self.raw/'openai/generation/audio-0000.mp3').exists())
        b.atomic(self.directory/'system.caf',original)
        (self.directory/'plaud-upload.mp3').unlink()
        self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)

    def test_primary_duration_mismatch_blocks_removal(self):
        m=b.read(self.directory/'upload-audio.json');m['duration']=100;b.atomic(self.directory/'upload-audio.json',m)
        self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)

    def test_unchanged_evidence_still_detects_tampered_text_after_cleanup(self):
        self.run_cleanup();self.validate()
        b.atomic(self.raw/'transcript.txt','今天发布')
        with self.assertRaises(ValueError):self.validate()

    def test_unsealed_receipt_cannot_authorize_model_deletion(self):
        hashes=b.read(self.directory/'archive-evidence.json')['sha256']
        b.atomic(self.raw/ev.RECEIPT,dict(version=1,file_id=self.fid,retained_audio=dict(path='plaud-upload.mp3',sha256=self.audio_hash),
                   retired={'system.caf':dict(sha256=hashes['system.caf'],reason='expired_raw')}))
        (self.raw/'system.caf').unlink()
        with self.assertRaises(ValueError):runner.verify_originals(self.raw,hashes)

    def test_retention_receipt_tampering_is_detected(self):
        self.run_cleanup()
        record=b.read(self.raw/ev.RECEIPT);record['retired']['transcript.txt']=dict(sha256=self.manifest['sha256']['transcript.txt'],reason='completed_cache')
        b.atomic(self.raw/ev.RECEIPT,record)
        with self.assertRaises(ValueError):self.validate()

    def test_crash_after_proof_before_snapshot_and_after_unlink_resume(self):
        ctx=self.ctx();plan=storage.prepare_plan(ctx,storage.candidates(ctx),self.now)
        # Exact crash window: proof saved, baseline snapshot not yet updated.
        b.atomic(self.raw/ev.RECEIPT,plan['proof'])
        real_unlink=Path.unlink;did_crash=[]
        def crash_after_unlink(path,*args,**kwargs):
            value=real_unlink(path,*args,**kwargs)
            if path.name=='system.caf' and not did_crash:
                did_crash.append(True);raise RuntimeError('simulated process crash')
            return value
        with patch.object(Path,'unlink',crash_after_unlink):
            with self.assertRaises(RuntimeError):storage.apply_plan(ctx,plan,self.root)
        self.assertTrue(did_crash)
        self.run_cleanup();self.validate()
        self.assertEqual(b.read(self.directory/storage.PLAN)['state'],'done')

    def test_new_recording_during_cleanup_stops_and_recovers(self):
        ctx=self.ctx();plan=storage.prepare_plan(ctx,storage.candidates(ctx),self.now)
        with patch.object(storage,'require_idle',side_effect=storage.Deferred('new recording')):
            with self.assertRaises(storage.Deferred):storage.apply_plan(ctx,plan,self.root)
        self.assertTrue((self.directory/'system.caf').exists())
        self.run_cleanup();self.validate()

    def test_symlink_and_bad_receipt_paths_preserve_files(self):
        outside=self.root/'outside.mp3';b.atomic(outside,'outside')
        (self.directory/'openai/generation/evil.mp3').symlink_to(outside)
        self.assertEqual(self.run_cleanup()['cleaned_bytes'],0);self.assertEqual(outside.read_text(),'outside')
        (self.directory/'openai/generation/evil.mp3').unlink()
        value=b.read(self.directory/'submission.json');value['job_path']=str(outside);b.atomic(self.directory/'submission.json',value)
        self.assertEqual(self.run_cleanup()['cleaned_bytes'],0)

    def test_local_unsealed_audio_cache_removal_preserves_json_and_imports(self):
        b.atomic(self.directory/'openai/old/retry.mp3',b'old cache')
        b.atomic(self.directory/'imported.m4a',b'user original')
        self.run_cleanup()
        self.assertFalse((self.directory/'openai/old/retry.mp3').exists())
        self.assertTrue((self.directory/'imported.m4a').exists());self.validate()


if __name__ == '__main__': unittest.main()

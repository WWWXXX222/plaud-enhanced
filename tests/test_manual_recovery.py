import os
import subprocess
import time
import unittest
from unittest.mock import Mock, patch

import backend as b
import archive_dispatch as a
import archive_runner as r
import openai_transcription as o
import test_archive_events as events
import test_reference_recovery as references


class SliceRecoveryTests(unittest.TestCase):
    setUp = references.ReferenceRecoveryTests.setUp
    tearDown = references.ReferenceRecoveryTests.tearDown

    def test_encoder_padding_failure_recovers_same_range_then_reuses_cache(self):
        target = self.folder/'tail.mp3'; calls = []
        original = b.digest(self.audio)
        def encode(command, **kwargs):
            calls.append(command)
            if '-sample_fmt' not in command:
                return Mock(returncode=234, stderr=b'libmp3lame: inadequate AVFrame plane padding')
            self.assertEqual(command[command.index('-sample_fmt')+1], 's16p')
            target.with_suffix('.partial.mp3').write_bytes(b'encoded tail')
            return Mock(returncode=0, stderr=b'')
        with patch.object(o.subprocess, 'run', side_effect=encode), patch.object(b, 'duration', return_value=144.7718045):
            o.slice_reference_audio(self.audio, target, 144.7718045, 144.7718045)
            o.slice_reference_audio(self.audio, target, 144.7718045, 144.7718045)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][:-1], calls[1][:-3])
        self.assertEqual(b.digest(self.audio), original)
        self.assertTrue(target.exists())

    def test_other_encoder_errors_keep_diagnostic_without_accepting_partial_audio(self):
        target = self.folder/'tail.mp3'
        with patch.object(o.subprocess, 'run', return_value=Mock(returncode=1, stderr=b'unknown encoder')) as encode:
            with self.assertRaises(o.RetryableTranscriptionError):
                o.slice_reference_audio(self.audio, target, 0, 60)
        self.assertEqual(encode.call_count, 1)
        self.assertFalse(target.exists())
        self.assertIn('unknown encoder', b.read(target.with_suffix('.slice-error.json'))['message'])


class ManualRecoveryTests(unittest.TestCase):
    setUp = events.EventTests.setUp
    tearDown = events.EventTests.tearDown
    row = events.EventTests.row
    succeed = events.EventTests.succeed

    def publish(self):
        with patch.object(r, 'kick'): a.dispatch(self.directory, self.vault)

    def test_retry_preserves_identity_attempts_and_originals(self):
        self.publish(); r.checkpoint(self.directory, state='pending', attempts=5, retry_at=time.time()+1000)
        before = b.read(self.directory/'archive-trigger.json'); source = b.digest(self.raw/'transcript.txt')
        with patch.object(r, 'kick', return_value={'state':'active'}):
            for _ in range(3): self.assertEqual(r.recover(self.directory, self.vault)['state'], 'resuming')
        after = b.read(self.directory/'archive-trigger.json')
        self.assertEqual(after['event_id'], before['event_id']); self.assertEqual(after['attempts'], 5)
        self.assertEqual(after['retry_at'], 0); self.assertEqual(b.read(self.jobpath)['state'], 'ready')
        self.assertEqual(b.digest(self.raw/'transcript.txt'), source)
        self.assertEqual(len(list((self.vault/'meeting-inbox/plaud').glob('*/job.json'))), 1)

    def test_done_disabled_blocked_and_bad_evidence_do_not_start(self):
        self.publish()
        with patch.object(r, 'kick') as launch:
            r.checkpoint(self.directory, state='blocked', message='evidence failure')
            self.assertEqual(r.recover(self.directory, self.vault)['state'], 'blocked')
            r.checkpoint(self.directory, state='pending')
            b.atomic(self.root/'settings.json', dict(archive_mode='app-background', archive_auto_trigger=False))
            self.assertEqual(r.recover(self.directory, self.vault)['state'], 'held')
            b.atomic(self.root/'settings.json', dict(archive_mode='app-background', archive_auto_trigger=True))
            b.atomic(self.raw/'transcript.txt', 'tampered')
            with self.assertRaises(ValueError): r.recover(self.directory, self.vault)
            j=b.read(self.jobpath); j['state']='done'; b.atomic(self.jobpath,j)
            self.assertEqual(r.recover(self.directory, self.vault)['state'], 'done')
            launch.assert_not_called()

    def test_healthy_live_worker_is_not_restarted_but_stale_one_gets_owned_request(self):
        self.publish(); r.checkpoint(self.directory, state='running', attempts=3, started_at=b.stamp())
        now = time.time(); event = b.read(self.directory/'archive-trigger.json')['event_id']
        with b.lock(self.directory/'.archive-run.lock', nonblocking=True), patch.object(r, 'kick') as launch:
            self.assertEqual(r.recover(self.directory, self.vault, now)['state'], 'active')
            self.assertFalse((self.directory/'archive-restart-request.json').exists())
            self.assertEqual(r.recover(self.directory, self.vault, now+601)['state'], 'restarting')
            self.assertEqual(r.recover(self.directory, self.vault, now+602)['state'], 'restarting')
            request = b.read(self.directory/'archive-restart-request.json')
            self.assertEqual(request['event_id'], event); self.assertEqual(request['attempt'], 3)
            launch.assert_not_called()

    def test_recovery_request_stops_owned_group_and_is_not_reused_for_next_attempt(self):
        self.publish()
        fake=self.root/'fake-codex'; fake.write_text('#!/bin/sh\nsleep 60\n'); fake.chmod(0o700)
        r.checkpoint(self.directory, state='running', attempts=3, started_at=b.stamp())
        event=b.read(self.directory/'archive-trigger.json')['event_id']
        b.atomic(self.directory/'archive-restart-request.json', dict(event_id=event, attempt=3))
        job=b.read(self.jobpath); job['job_path']=str(self.jobpath)
        with patch.object(r, 'CLI', fake):
            start=time.monotonic()
            self.assertEqual(r.execute(self.directory, job, self.vault, (self.fd,), timeout=3), 125)
            self.assertLess(time.monotonic()-start, 3)
            r.checkpoint(self.directory, attempts=4)
            with self.assertRaises(subprocess.TimeoutExpired):
                r.execute(self.directory, job, self.vault, (self.fd,), timeout=1.1)

    def test_manual_restart_continues_same_job_without_backoff_then_finishes(self):
        self.publish()
        self.assertEqual(r.attempt(self.directory,self.row(),self.vault,self.fd,lambda *args:125), 'manual_restart')
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['retry_at'], 0)
        r.attempt(self.directory,self.row(),self.vault,self.fd,self.succeed)
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['state'], 'done')
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['attempts'], 2)


if __name__ == '__main__': unittest.main()

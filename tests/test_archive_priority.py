"""User priority changes order, never evidence, active work, or retry policy."""
import fcntl
import os
from pathlib import Path
import shutil
import signal
import time
import unittest
import uuid
from unittest.mock import patch, Mock

import backend as b
import archive_runner as r
import test_archive_events as fixtures


class PriorityTests(unittest.TestCase):
    setUp = fixtures.EventTests.setUp
    tearDown = fixtures.EventTests.tearDown

    def add_job(self, minute):
        mid = 'mm_' + str(uuid.uuid4())
        fid = 'of_' + uuid.uuid4().hex
        directory = self.root/'data/meetings'/mid
        raw = self.raw.with_name(fid)
        shutil.copytree(self.raw, raw)
        manifest = b.read(raw/'manifest.json'); manifest['file_id'] = fid
        b.atomic(raw/'manifest.json', manifest)
        path = self.jobpath.parent.with_name(fid)/'job.json'
        job = b.read(self.jobpath)
        job.update(file_id=fid, local_meeting_id=mid, raw_dir=str(raw), state='ready')
        b.atomic(path, job)
        b.atomic(directory/'meeting.json', dict(id=mid, capture_state='captured',
                 auto_archive=True, created_at=f'2026-10-27T10:{minute:02}:00Z'))
        b.atomic(directory/'submission.json', dict(file_id=fid, job_path=str(path)))
        with patch.object(r, 'kick'): r.publish(directory, self.vault)
        return directory, fid

    def test_priority_preserves_original_job_and_backoff(self):
        second, fid = self.add_job(10)
        path = self.vault/'meeting-inbox/plaud'/fid/'job.json'
        before = path.read_bytes()
        r.checkpoint(second, state='pending', attempts=3, retry_at=time.time()+1000)
        with patch.object(r, 'kick'):
            r.prioritize(second, self.vault)
            receipt = b.read(second/'archive-trigger.json')
            for _ in range(10): self.assertEqual(r.publish(second, self.vault), receipt)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(receipt['attempts'], 3)
        self.assertEqual([j['file_id'] for _, j in r.candidates(self.root, self.vault)], [self.fid])
        r.checkpoint(second, retry_at=0)
        self.assertEqual(r.candidates(self.root, self.vault)[0][1]['file_id'], fid)

    def test_busy_drain_applies_new_priority_at_next_boundary(self):
        second, second_id = self.add_job(10)
        third, third_id = self.add_job(20)
        rt = r.runtime(self.root)
        b.atomic(rt/'wake.json', dict(generation='first'))
        fd = os.open(rt/'worker.lock', os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        calls = []
        def execute(directory, job, vault, leases):
            fid = job['file_id']; raw = Path(job['raw_dir']); calls.append(fid)
            if len(calls) == 1:
                self.assertEqual(r.prioritize(third, vault)['runner']['state'], 'active')
                self.assertEqual(b.read(Path(job['job_path']))['state'], 'processing')
            source = vault/'personal-memory/knowledge-catalog/sources'/f'{fid}.md'
            b.atomic(raw/'analysis.md', '# 模拟分析')
            b.atomic(raw/'retrieval-notes.md', '模拟检索')
            b.atomic(source, '模拟来源')
            r.bridge(vault).finish(fid, [str(raw/'analysis.md'), str(source)])
            return 0
        original = signal.getsignal(signal.SIGTERM)
        try:
            with patch.object(r.subprocess, 'Popen', side_effect=AssertionError('no competing worker')):
                r.drain(self.root, self.vault, fd, execute)
        finally: signal.signal(signal.SIGTERM, original)
        self.assertEqual(calls, [self.fid, third_id, second_id])
        self.assertEqual(r.kick(self.root, self.vault)['state'], 'idle')

    def test_done_is_not_requeued_and_blocked_is_not_bypassed(self):
        r.checkpoint(self.directory, state='blocked')
        with self.assertRaises(ValueError): r.prioritize(self.directory, self.vault)
        job = b.read(self.jobpath); job['state'] = 'done'; b.atomic(self.jobpath, job)
        before = (self.directory/'archive-trigger.json').read_bytes()
        with patch.object(r, 'kick', side_effect=AssertionError('done cannot start')):
            self.assertEqual(r.prioritize(self.directory, self.vault)['state'], 'done')
        self.assertEqual((self.directory/'archive-trigger.json').read_bytes(), before)

    def test_busy_meeting_lock_does_not_spin(self):
        rt = r.runtime(self.root); b.atomic(rt/'wake.json', dict(generation='first'))
        fd = os.open(rt/'worker.lock', os.O_CREAT | os.O_RDWR, 0o600)
        executor = Mock(side_effect=AssertionError('busy meeting'))
        original = signal.getsignal(signal.SIGTERM)
        try:
            with b.lock(self.directory/'.archive-run.lock'):
                r.drain(self.root, self.vault, fd, executor)
        finally: signal.signal(signal.SIGTERM, original)
        executor.assert_not_called()


if __name__ == '__main__': unittest.main()

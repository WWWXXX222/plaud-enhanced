"""Desktop occupancy must never lead to an external thread writer."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
import backend as b
import archive_dispatch as a
import test_archive_dispatch as fixtures

class NativeProcessTests(unittest.TestCase):
    setUp=fixtures.DispatchTests.setUp
    tearDown=fixtures.DispatchTests.tearDown
    def test_loaded_desktop_chat_does_not_block_delivery(self):
        b.atomic(self.meeting/'archive-codex-events.jsonl','Error: thread already has an active writer\n')
        with b.lock(self.vault/'meeting-inbox/plaud'/('.codex-session-'+a.THREAD_ID+'.lock')):
            with patch('subprocess.Popen',side_effect=AssertionError('competing writer')):
                self.assertEqual(a.dispatch(self.meeting,self.vault)['state'],'native_ready')
        self.assertEqual(len(a.native_pending(self.root,self.vault)['jobs']),1)
    def test_old_worker_entrypoint_is_a_safe_one_shot_migration(self):
        r=subprocess.run([sys.executable,a.__file__,'--worker',str(self.meeting),'--vault',str(self.vault)],capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(r.stdout)['state'],'native_ready')
        self.assertFalse((self.meeting/'archive-codex-events.jsonl').exists())
    def test_separate_processes_publish_exactly_one_event(self):
        command=[sys.executable,a.__file__,'--worker',str(self.meeting),'--vault',str(self.vault)]
        workers=[subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(8)]
        results=[]
        for w in workers:
            out,err=w.communicate(timeout=10);self.assertEqual(w.returncode,0,err);results.append(json.loads(out))
        self.assertTrue(all(r==results[0] for r in results))
        self.assertEqual(results[0]['attempts'],0)

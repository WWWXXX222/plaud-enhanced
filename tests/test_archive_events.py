import concurrent.futures
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch, Mock

import backend as b
import archive_runner as r
import archive_dispatch as a


class EventTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.vault = self.root/'vault'
        self.mid = 'mm_'+str(uuid.uuid4())
        self.fid = 'of_'+uuid.uuid4().hex
        self.directory = self.root/'data/meetings'/self.mid
        self.jobpath = self.vault/'meeting-inbox/plaud'/self.fid/'job.json'
        self.raw = self.vault/'personal-memory/raw-inputs/work/test'/self.fid
        b.atomic(self.root/'settings.json', dict(archive_mode='app-background', archive_auto_trigger=True))
        b.atomic(self.directory/'meeting.json', dict(id=self.mid, auto_archive=True, capture_state='captured'))
        b.atomic(self.directory/'submission.json', dict(file_id=self.fid, job_path=str(self.jobpath)))
        b.atomic(self.raw/'transcript.txt', '模拟测试：今天不发布。Not today. Speaker 待确认。')
        b.atomic(self.raw/'transcript-timeline.md', '[00:00] Speaker 待确认：今天不发布。Not today.')
        b.atomic(self.raw/'manifest.json', dict(file_id=self.fid, transcript='transcript.txt',
                 include_plaud_summary=False, is_test=True, sha256={'transcript.txt':b.digest(self.raw/'transcript.txt')}))
        b.atomic(self.jobpath, dict(file_id=self.fid, local_meeting_id=self.mid, state='ready', assets_ready=True,
                 source='OpenAI', title='事件回归（模拟）', recorded_at='2026-10-25T10:00:00Z', raw_dir=str(self.raw),
                 context=dict(images=[], is_test=True, auto_archive=True), include_plaud_summary=False, is_test=True))
        self.fd = os.open(self.root/'test.lock', os.O_CREAT|os.O_RDWR, 0o600)
    def tearDown(self):
        os.close(self.fd)
        self.tmp.cleanup()
    def row(self): return a.native_pending(self.root,self.vault)['jobs'][0]
    def succeed(self, directory, job, vault, lease):
        digest = self.vault/'personal-memory/knowledge-catalog/sources/reports'/f'test-{self.fid}.md'
        b.atomic(self.raw/'analysis.md','# 模拟归档验证\n保留否定语义。')
        b.atomic(self.raw/'retrieval-notes.md','检索测试知识库，无真实历史依据。')
        b.atomic(digest,'# 明确的模拟测试来源')
        r.bridge(vault).finish(self.fid,[str(self.raw/'analysis.md'),str(digest)])
        return 0
    def test_idle_and_disabled_do_not_spawn(self):
        j=b.read(self.jobpath);j['state']='done';b.atomic(self.jobpath,j)
        with patch.object(subprocess,'Popen',side_effect=AssertionError('idle must not spawn')):
            self.assertEqual(r.kick(self.root,self.vault)['state'],'idle')
            b.atomic(self.root/'settings.json',dict(archive_mode='app-background',archive_auto_trigger=False))
            self.assertEqual(r.kick(self.root,self.vault)['state'],'disabled')
    def test_concurrent_events_start_exactly_one_inherited_lease(self):
        held=[]
        def start(*args,**kwargs):
            held.append(os.dup(kwargs['pass_fds'][0]))
            return Mock(pid=123)
        try:
            with patch.object(subprocess,'Popen',side_effect=start) as spawn:
                with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
                    states=list(pool.map(lambda _:r.kick(self.root,self.vault)['state'],range(40)))
            self.assertEqual(spawn.call_count,1)
            self.assertEqual(states.count('started'),1)
            self.assertEqual(states.count('active'),39)
        finally:
            for fd in held:os.close(fd)
    def test_repeated_publish_preserves_attempt_and_backoff(self):
        with patch.object(r,'kick'):
            first=a.dispatch(self.directory,self.vault)
            r.checkpoint(self.directory,state='pending',attempts=3,retry_at=time.time()+1000)
            saved=b.read(self.directory/'archive-trigger.json')
            for _ in range(30):self.assertEqual(a.dispatch(self.directory,self.vault),saved)
        self.assertEqual(first['state'],'queued')
    def test_success_then_duplicate_has_one_execution_and_stable_source(self):
        exec=Mock(side_effect=self.succeed)
        row=self.row()
        r.attempt(self.directory,row,self.vault,self.fd,exec)
        r.attempt(self.directory,row,self.vault,self.fd,exec)
        self.assertEqual(exec.call_count,1)
        self.assertEqual(b.read(self.jobpath)['state'],'done')
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['state'],'done')
        with patch.object(subprocess,'Popen',side_effect=AssertionError('completed')):
            self.assertEqual(r.kick(self.root,self.vault)['state'],'idle')
    def test_interruption_resumes_same_processing_job(self):
        def fail(*args):
            b.atomic(self.raw/'continuation.md','partial work')
            return 1
        row=self.row()
        r.attempt(self.directory,row,self.vault,self.fd,fail)
        self.assertEqual(b.read(self.jobpath)['state'],'processing')
        self.assertEqual(r.candidates(self.root,self.vault),[])
        r.checkpoint(self.directory,retry_at=0)
        r.attempt(self.directory,self.row(),self.vault,self.fd,self.succeed)
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['attempts'],2)
        self.assertEqual((self.raw/'continuation.md').read_text(),'partial work')
        self.assertEqual(len(list((self.vault/'meeting-inbox/plaud').glob('*/job.json'))),1)
    def test_timeout_preserves_evidence_and_backoff(self):
        before=b.digest(self.raw/'transcript.txt')
        r.attempt(self.directory,self.row(),self.vault,self.fd,Mock(side_effect=subprocess.TimeoutExpired('codex',1)))
        receipt=b.read(self.directory/'archive-trigger.json')
        self.assertEqual(receipt['state'],'pending')
        self.assertGreater(receipt['retry_at'],time.time())
        self.assertEqual(b.digest(self.raw/'transcript.txt'),before)
    def test_exit_zero_without_verified_outputs_is_not_done(self):
        r.attempt(self.directory,self.row(),self.vault,self.fd,lambda *args:0)
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['state'],'pending')
        self.assertEqual(b.read(self.jobpath)['state'],'processing')
    def test_tampered_source_stops_before_calling_model(self):
        b.atomic(self.raw/'transcript.txt','wrong')
        exec=Mock()
        r.attempt(self.directory,self.row(),self.vault,self.fd,exec)
        exec.assert_not_called()
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['state'],'blocked')
    def test_modified_source_on_retry_cannot_reset_the_baseline(self):
        r.attempt(self.directory,self.row(),self.vault,self.fd,lambda *args:1)
        b.atomic(self.raw/'transcript.txt','changed')
        m=b.read(self.raw/'manifest.json');m['sha256']['transcript.txt']=b.digest(self.raw/'transcript.txt');b.atomic(self.raw/'manifest.json',m)
        exec=Mock()
        r.attempt(self.directory,self.row(),self.vault,self.fd,exec)
        exec.assert_not_called()
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['state'],'blocked')
    def test_no_false_completion_after_launcher_crash(self):
        r.attempt(self.directory,self.row(),self.vault,self.fd,self.succeed)
        r.checkpoint(self.directory,state='running')
        with patch.object(subprocess,'Popen',side_effect=AssertionError('reconcile only')):
            self.assertEqual(r.kick(self.root,self.vault)['state'],'idle')
        self.assertEqual(b.read(self.directory/'archive-trigger.json')['state'],'done')
    def test_invalid_model_done_is_not_published_as_success(self):
        def bad(*args):
            j=b.read(self.jobpath);j['state']='done';j['outputs']=[];b.atomic(self.jobpath,j);return 0
        r.attempt(self.directory,self.row(),self.vault,self.fd,bad)
        self.assertEqual(a.dispatch(self.directory,self.vault)['state'],'blocked')
    def test_native_heartbeat_cannot_consume_after_switch(self):
        out=subprocess.check_output([sys.executable,a.__file__,'--native-pending','--root',str(self.root),'--vault',str(self.vault)],text=True)
        self.assertEqual(__import__('json').loads(out)['jobs'],[])
        self.assertEqual(len(r.candidates(self.root,self.vault)),1)
    def test_held_setting_and_result_preference_are_independent(self):
        with patch.object(r,'kick'):
            r.save_settings(self.root,False,'codex')
            self.assertEqual(a.dispatch(self.directory,self.vault)['state'],'held')
            r.save_settings(self.root,True,'codex')
            self.assertEqual(a.dispatch(self.directory,self.vault)['state'],'queued')
        self.assertTrue(r.enabled(self.root))
        self.assertEqual(r.settings(self.root)['archive_result_view'],'codex')
    def test_cli_is_ephemeral_sandboxed_and_never_resumes_desktop(self):
        cmd=r.codex_command(self.vault,self.raw/'result.md')
        self.assertIn('--ephemeral',cmd);self.assertIn('workspace-write',cmd);self.assertIn('approval_policy="never"',cmd)
        for forbidden in ('resume','queue','--dangerously-bypass-approvals-and-sandbox','--ignore-rules','--ignore-user-config',a.THREAD_ID):
            self.assertNotIn(forbidden,cmd)
    def test_lease_survives_launcher_close_until_child_exits(self):
        path=self.root/'inherited.lock';fd=os.open(path,os.O_CREAT|os.O_RDWR,0o600)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(0.3)'],pass_fds=(fd,))
        os.close(fd)
        other=os.open(path,os.O_RDWR)
        try:
            with self.assertRaises(BlockingIOError):fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
            child.wait(timeout=3)
            fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
        finally:os.close(other)
    def test_timeout_terminates_real_process_group(self):
        fake=self.root/'fake-codex';fake.write_text('#!/bin/sh\nsleep 60\n');fake.chmod(0o700)
        job=b.read(self.jobpath);job['job_path']=str(self.jobpath)
        with patch.object(r,'CLI',fake):
            with self.assertRaises(subprocess.TimeoutExpired):r.execute(self.directory,job,self.vault,(self.fd,),timeout=0.1)
    def test_existing_system_proxy_is_followed_without_overwriting_explicit_choice(self):
        with patch.dict(os.environ,{'HTTPS_PROXY':'http://explicit.invalid'},clear=True),patch.object(r.urllib.request,'getproxies',return_value={'https':'http://system.invalid','http':'http://system.invalid'}):
            env=r.codex_environment()
        self.assertEqual(env['HTTPS_PROXY'],'http://explicit.invalid')
        self.assertEqual(env['HTTP_PROXY'],'http://system.invalid')
    def test_new_event_during_busy_drain_is_not_lost_or_duplicated(self):
        rt=r.runtime(self.root)
        b.atomic(rt/'wake.json',dict(generation='first'))
        fd=os.open(rt/'worker.lock',os.O_CREAT|os.O_RDWR,0o600)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        called=[]
        def execute(directory,job,vault,lease):
            fid=job['file_id'];raw=Path(job['raw_dir']);called.append(fid)
            digest=vault/'personal-memory/knowledge-catalog/sources/reports'/f'{fid}.md'
            b.atomic(raw/'analysis.md','# 模拟分析')
            b.atomic(raw/'retrieval-notes.md','模拟检索')
            b.atomic(digest,'模拟来源')
            r.bridge(vault).finish(fid,[str(raw/'analysis.md'),str(digest)])
            if len(called)==1:
                import shutil
                mid='mm_'+str(uuid.uuid4());newfid='of_'+uuid.uuid4().hex
                d=self.root/'data/meetings'/mid;p=vault/'meeting-inbox/plaud'/newfid/'job.json'
                newraw=raw.with_name(newfid);shutil.copytree(raw,newraw)
                m=b.read(newraw/'manifest.json');m['file_id']=newfid;b.atomic(newraw/'manifest.json',m)
                j=dict(job);j.update(file_id=newfid,local_meeting_id=mid,raw_dir=str(newraw),state='ready',outputs=[])
                b.atomic(p,j)
                b.atomic(d/'meeting.json',dict(id=mid,capture_state='captured',auto_archive=True))
                b.atomic(d/'submission.json',dict(file_id=newfid,job_path=str(p)))
                with patch.object(subprocess,'Popen',side_effect=AssertionError('existing drain owns queue')):
                    r.publish(d,vault)
            return 0
        import signal
        original=signal.getsignal(signal.SIGTERM)
        try:r.drain(self.root,self.vault,fd,execute)
        finally:signal.signal(signal.SIGTERM,original)
        self.assertEqual(len(called),2);self.assertEqual(len(set(called)),2)
        self.assertEqual(r.kick(self.root,self.vault)['state'],'idle')
    def test_bad_receipt_does_not_start_model_or_get_reset(self):
        p=self.directory/'archive-trigger.json';p.write_text('{broken')
        with patch.object(subprocess,'Popen',side_effect=AssertionError('invalid receipt')):
            self.assertEqual(r.kick(self.root,self.vault)['state'],'idle')
        self.assertEqual(p.read_text(),'{broken')
    def test_orphan_supervisor_retains_lease_then_enforces_timeout(self):
        import shlex
        started=self.root/'fake-started'
        fake=self.root/'fake-codex'
        fake.write_text('#!/bin/sh\ntouch '+shlex.quote(str(started))+'\nsleep 60\n');fake.chmod(0o700)
        harness=self.root/'supervisor.py'
        harness.write_text('import sys,functools\nsys.path.insert(0,'+repr(str(Path(r.__file__).parent))+')\nimport archive_runner as r\nr.CLI=r.Path('+repr(str(fake))+')\nr.execute=functools.partial(r.execute,timeout=1.2)\nr.main()\n')
        lease=self.root/'orphan.lock'
        launcher=self.root/'launcher.py'
        launcher.write_text('import os,fcntl,subprocess,sys,time\nfd=os.open('+repr(str(lease))+',os.O_CREAT|os.O_RDWR,0o600)\nfcntl.flock(fd,fcntl.LOCK_EX)\nsubprocess.Popen([sys.executable,'+repr(str(harness))+',"--supervise",'+repr(str(self.directory))+',"--vault",'+repr(str(self.vault))+',"--lease-fds",str(fd)],pass_fds=(fd,),start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\ntime.sleep(30)\n')
        parent=subprocess.Popen([sys.executable,str(launcher)])
        other=None
        try:
            deadline=time.monotonic()+5
            while not started.exists() and time.monotonic()<deadline:time.sleep(0.02)
            self.assertTrue(started.exists())
            parent.kill();parent.wait(timeout=3)
            other=os.open(lease,os.O_RDWR)
            with self.assertRaises(BlockingIOError):fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
            released=False;deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                try:
                    fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB);released=True;break
                except BlockingIOError:time.sleep(0.02)
            self.assertTrue(released,'orphan watchdog must terminate the hanging child and release its lease')
        finally:
            if parent.poll() is None:parent.kill();parent.wait()
            if other is not None:os.close(other)

if __name__ == '__main__':unittest.main()

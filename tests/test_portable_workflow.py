import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend as b
import runtime_config as c
import archive_runner as r
import archive_dispatch as a
import local_recovery
import local_transcription
from bridge import Bridge

class PortableWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name).resolve()
        self.vault = self.root/'My Knowledge'; self.fid = 'mm_'+str(uuid.uuid4())
        self.directory = self.root/'data/meetings'/self.fid
        self.directory.mkdir(parents=True)
        b.atomic(self.root/'settings.json', dict(archive_mode='app-background', archive_auto_trigger=True, archive_provider='claude'))
        b.atomic(self.directory/'meeting.json', dict(id=self.fid, title='Synthetic bilingual review',
            created_at='2026-11-09T12:00:00Z', participants='', purpose='', notes='', images=[],
            capture_state='captured', transcription_engine='local', cloud_upload=False, auto_archive=True,
            audio_files=['microphone.caf'], is_test=True))
        for name in ('microphone.caf','audio.wav','whisper-original.json'): b.atomic(self.directory/name,'synthetic fixture')
        b.atomic(self.directory/'transcript.txt','今天不发布。Do not ship today.\n')
        b.atomic(self.directory/'transcript.json', dict(duration=10, segments=[dict(start_seconds=0,end_seconds=10,text='今天不发布。Do not ship today.')]))
        b.report(self.directory,'complete','synthetic')
    def tearDown(self): self.tmp.cleanup()
    def test_new_vault_and_configured_path(self):
        self.assertEqual(c.vault_path(self.root), self.root/'Vault')
        b.atomic(self.root/'settings.json', {'vault_path':str(self.vault)})
        self.assertEqual(c.vault_path(self.root), self.vault)
    def test_no_plaud_archive_is_idempotent_and_preserves_evidence(self):
        receipt=b.submit(self.directory,self.vault)
        self.assertEqual(receipt,b.submit(self.directory,self.vault))
        self.assertEqual(receipt['file_id'],self.fid)
        queue=Bridge(self.vault,self.root/'runtime',self.root/'no-account')
        job=queue.claim(self.fid); job['file_id']=self.fid
        raw,hashes=r.evidence(job,self.vault)
        self.assertEqual((raw/'transcript.txt').read_text(),'今天不发布。Do not ship today.\n')
        summary=self.vault/'personal-memory/knowledge-catalog/sources'/f'{self.fid}.md'
        index=summary.parent.parent/'index.md'
        for path in [raw/'analysis.md',raw/'retrieval-notes.md',summary,index]: b.atomic(path,'Synthetic result')
        b.atomic(raw/'archive-outputs.json',[str(raw/'analysis.md'),str(summary),str(index)])
        with patch.object(r,'bridge',return_value=queue): r.complete_outputs(job,self.vault)
        final=b.read(receipt['job_path'])
        self.assertTrue(r.validate_completion(final,self.vault,raw,hashes))
        self.assertEqual(len(list(self.vault.glob('meeting-inbox/plaud/*/job.json'))),1)
        self.assertFalse((raw/'plaud-upload-receipt.json').exists())
    def test_outputs_outside_vault_cannot_complete(self):
        receipt=b.submit(self.directory,self.vault); queue=Bridge(self.vault,self.root/'runtime',self.root/'no-account')
        job=queue.claim(self.fid);raw=Path(job['raw_dir']);outside=self.root/'outside.md'; b.atomic(outside,'outside')
        b.atomic(raw/'archive-outputs.json',[str(raw/'analysis.md'),str(outside)])
        with self.assertRaises(ValueError): r.complete_outputs(job,self.vault)
        self.assertEqual(b.read(receipt['job_path'])['state'],'processing')
    def test_claude_uses_explicit_local_tools_without_permission_bypass(self):
        with patch.object(c,'executable',return_value=Path('/fake/claude')):
            cmd=r.analysis_command('claude',self.vault,self.root/'output.md')
        self.assertIn('--print',cmd); self.assertIn('--no-session-persistence',cmd)
        self.assertNotIn('--dangerously-skip-permissions',cmd)
        self.assertNotIn('Bash',cmd[cmd.index('--tools')+1]); self.assertIn('--strict-mcp-config',cmd)
    def test_idle_recovery_does_not_call_transcriber_or_model(self):
        b.submit(self.directory,self.vault)
        with patch.object(b,'transcribe') as asr,patch.object(a,'handoff') as handoff:
            local_recovery.recover(self.root,self.vault)
            asr.assert_not_called();handoff.assert_not_called()
    def test_active_recording_defers_recovery(self):
        m=b.read(self.directory/'meeting.json'); m['capture_state']='recording';b.atomic(self.directory/'meeting.json',m)
        with patch.object(b,'transcribe') as asr:
            local_recovery.recover(self.root,self.vault);asr.assert_not_called()
    def test_batch_rejects_invalid_timestamps(self):
        with self.assertRaises(ValueError): local_transcription.validate({'segments':[dict(text='bad',start_seconds=8,end_seconds=3)]},10)

if __name__ == '__main__': unittest.main()

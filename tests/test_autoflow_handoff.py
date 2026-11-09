from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
import backend as b
import archive_dispatch as a
import test_openai_pipeline as fixtures

class HandoffRecoveryTests(unittest.TestCase):
    setUp=fixtures.OpenAIPipelineTests.setUp
    tearDown=fixtures.OpenAIPipelineTests.tearDown
    caller=fixtures.OpenAIPipelineTests.caller
    ready=fixtures.OpenAIPipelineTests.ready
    def test_complete_pipeline_resumes_same_job_without_another_message(self):
        target=self.root/'data/meetings'/self.dir.name;target.parent.mkdir(parents=True);shutil.move(self.dir,target);self.dir=target
        self.m.update(auto_archive=True,participants='',purpose='',images=[]);b.atomic(self.dir/'meeting.json',self.m)
        original=b.digest(self.dir/'imported.m4a');self.ready()
        with patch('subprocess.Popen',side_effect=AssertionError('no CLI or queue')):
            for _ in range(20):a.handoff(self.dir,self.vault)
        receipt=b.read(self.dir/'submission.json');raw=Path(receipt['raw_dir']);q=fixtures.p.bridge(self.vault)
        q.claim(fixtures.FID);analysis=raw/'analysis.md';b.atomic(analysis,'Partial verified research')
        # Interrupted native analysis is discovered on a subsequent scheduled check.
        pending=a.native_pending(self.root,self.vault)['jobs'];self.assertEqual(len(pending),1)
        self.assertEqual(pending[0]['state'],'processing');self.assertEqual(analysis.read_text(),'Partial verified research')
        q.claim(fixtures.FID);digest=self.vault/'digest.md';b.atomic(analysis,'Completed synthetic analysis');b.atomic(digest,'Synthetic digest')
        q.finish(fixtures.FID,[analysis,digest])
        for _ in range(20):a.handoff(self.dir,self.vault)
        self.assertEqual(a.native_pending(self.root,self.vault)['jobs'],[])
        self.assertEqual(b.read(self.dir/'archive-trigger.json')['state'],'done')
        self.assertEqual(b.read(self.dir/'submission.json'),receipt)
        self.assertEqual(len(list((self.vault/'meeting-inbox/plaud').glob('*/job.json'))),1)
        self.assertEqual(b.digest(self.dir/'imported.m4a'),original)
        for rel,digest in b.read(raw/'manifest.json')['sha256'].items():self.assertEqual(b.digest(raw/rel),digest)
        self.assertEqual(len(self.calls),2)

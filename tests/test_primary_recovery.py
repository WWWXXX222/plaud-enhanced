import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import backend as b
import openai_transcription as o
from speech_segmentation import join_primary


class PrimaryRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.directory=Path(self.tmp.name)
        self.folder=self.directory/'openai'/'fixture';self.folder.mkdir(parents=True)
        self.audio=self.directory/'audio.mp3';self.audio.write_bytes(b'original')
        self.fields=[('response_format','json'),('languages[]','zh'),('languages[]','en')]
    def tearDown(self):self.tmp.cleanup()
    def audio_slice(self,part,target,start,span):target.write_text(f'{start}:{span}')
    def test_empty_parent_splits_with_overlap_preserves_negation_and_resumes_cache(self):
        calls=[]
        overlap='今天不发布，Please keep the original language.'
        def caller(audio,model,fields,key):
            calls.append(audio.name);self.assertEqual(fields,self.fields)
            if audio==self.audio:return {'text':''},{'http_status':200}
            start,span=map(float,audio.read_text().split(':'))
            return {'text':('会议开始。'+overlap) if start==0 else (overlap+'明天再检查。')},{'http_status':200}
        with patch.object(o,'verify_no_speech',return_value={'no_speech_detected':False,'evidence_files':[]}), patch.object(o,'slice_reference_audio',side_effect=self.audio_slice):
            first=o.primary_responses(self.directory,self.audio,self.fields,'',caller,self.folder,0,120,0,False)
            second=o.primary_responses(self.directory,self.audio,self.fields,'',caller,self.folder,0,120,0,False)
        self.assertEqual(len(calls),3);self.assertEqual(first,second)
        self.assertEqual(first[0][1]['offset_seconds']+first[0][1]['span_seconds']-first[1][1]['offset_seconds'],20)
        text,joins=join_primary([dict(text=raw['text'],start=meta['offset_seconds'],end=meta['offset_seconds']+meta['span_seconds']) for raw,meta,_ in first])
        self.assertEqual(text,'会议开始。'+overlap+'明天再检查。')
        self.assertEqual(joins[0]['status'],'exact_overlap_deduplicated')
        self.assertEqual(len(list((self.folder/'rejected').glob('*.json'))),1)
    def test_saved_empty_parent_is_not_requested_again_and_children_keep_absolute_time(self):
        b.atomic(self.folder/'rejected'/'0002-gpt-transcribe-fixture.json',dict(response={'text':''},receipt={'http_status':200},
            failure=dict(model=o.PRIMARY,audio_sha256=b.digest(self.audio),parameters=[list(x) for x in self.fields],offset_seconds=300,span_seconds=120)))
        def caller(audio,*args):
            self.assertNotEqual(audio,self.audio)
            return {'text':'Keep 中文原文。'},{'http_status':200}
        with patch.object(o,'slice_reference_audio',side_effect=self.audio_slice):
            results=o.primary_responses(self.directory,self.audio,self.fields,'',caller,self.folder,300,120,2,True)
        self.assertEqual(results[0][1]['offset_seconds'],300)
        self.assertEqual(results[-1][1]['offset_seconds']+results[-1][1]['span_seconds'],420)
    def test_rate_limit_does_not_split_primary_or_accept_missing_words(self):
        with patch.object(o.time,'sleep'),patch.object(o,'slice_reference_audio') as split:
            with self.assertRaises(o.RetryableTranscriptionError):
                o.primary_responses(self.directory,self.audio,self.fields,'',lambda *args:(_ for _ in ()).throw(o.RetryableTranscriptionError('rate limit')),self.folder,0,120,0,False)
        split.assert_not_called()

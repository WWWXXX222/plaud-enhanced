import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import speech_segmentation as s
import openai_transcription as o
import test_openai_pipeline as fixtures


class BoundaryTests(unittest.TestCase):
    def test_same_77_second_recording_is_not_cut_at_negation(self):
        f=fixtures.OpenAIPipelineTests(); f.setUp()
        try:
            with patch.object(o.b,'duration',return_value=77.508):
                audio,duration,folder,parts=o.prepare_parts(f.dir,f.m)
            self.assertEqual(parts,[(audio,0.0,77.508)])
            self.assertEqual(audio.read_bytes(),(f.dir/'imported.m4a').read_bytes())
            self.assertIn(s.POLICY,folder.name)
        finally:f.tearDown()

    def test_long_audio_uses_pause_and_covers_tail(self):
        ranges=s.plan_ranges(1250,[(594,596),(1190,1192)])
        self.assertEqual(ranges,[(0.0,595),(595,1250)])
        self.assertEqual(ranges[0][1],ranges[1][0])

    def test_continuous_speech_overlaps_and_cannot_silently_drop_negation(self):
        ranges=s.plan_ranges(1250,[])
        self.assertEqual(ranges,[(0.0,600.0),(580.0,1180.0),(1160.0,1250)])
        text,joins=s.join_primary([dict(text='今天不。',start=0,end=600),dict(text='发布。',start=580,end=650)])
        self.assertIn('今天不。',text);self.assertIn('发布。',text)
        self.assertIn('不可单独作为决定依据',text)
        self.assertFalse(joins[0]['decision_extraction_allowed'])

    def test_exact_overlap_preserves_bilingual_negation(self):
        phrase='This is only a test，今天不发布。'
        text,joins=s.join_primary([dict(text='开场。'+phrase,start=0,end=600),
                                  dict(text=phrase+'Release date 待确认。',start=580,end=650)])
        self.assertEqual(text,'开场。'+phrase+'Release date 待确认。')
        self.assertEqual(joins[0]['status'],'exact_overlap_deduplicated')

    def test_speaker_fragment_and_merged_introductions_are_not_identity_claims(self):
        raw={'segments':[dict(start=1,end=6,speaker='A',text='我是林，今天讨论 API。'),
                         dict(start=6,end=6.5,speaker='B',text='T I'),
                         dict(start=7,end=12,speaker='A',text='我是测试负责人梅，我负责 rollback。')]}
        before=copy.deepcopy(raw)
        segments=s.annotate_speakers(o.reference_segments(raw,0,20,0,False))
        self.assertIn('可能合并多人',segments[0]['speaker'])
        self.assertIn('短片段',segments[1]['speaker'])
        self.assertEqual([x['raw_speaker'] for x in segments],['A','B','A'])
        self.assertTrue(all(x['speaker_status']=='unconfirmed' for x in segments))
        self.assertEqual([x['text'] for x in segments],[x['text'] for x in raw['segments']])
        self.assertEqual(raw,before)

    def test_label_identity_does_not_cross_chunks(self):
        a=o.reference_segments({'segments':[dict(start=0,end=4,speaker='A',text='我是林。')]},0,10,0,True)
        b=o.reference_segments({'segments':[dict(start=0,end=4,speaker='A',text='我是梅。')]},10,10,1,True)
        self.assertTrue(all(not x['speaker_issues'] for x in s.annotate_speakers(a+b)))


if __name__=='__main__':unittest.main()

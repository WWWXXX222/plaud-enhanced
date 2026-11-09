import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import openai_transcription as o
import test_openai_pipeline as fixtures

class PointTimestampTests(unittest.TestCase):
    def test_point_references_keep_text_and_do_not_invent_duration(self):
        for stamp in [0.0,26.74,60.0]:
            raw={'segments':[{'start':stamp,'end':stamp,'speaker':'A','text':'嗯'}]}; before=copy.deepcopy(raw)
            result=o.reference_segments(raw,600,60,10,True)
            self.assertEqual(result[0]['start_seconds'],600+stamp)
            self.assertEqual(result[0]['end_seconds'],600+stamp)
            self.assertEqual(result[0]['timestamp_status'],'point_duration_unknown')
            self.assertEqual(result[0]['text'],'嗯');self.assertEqual(raw,before)
    def test_invalid_intervals_still_rejected(self):
        for start,end in [(2,1),(-1,0),(61,61),(0,999),(0,float('nan')),(True,1)]:
            with self.assertRaises(ValueError):o.reference_segments({'segments':[{'start':start,'end':end,'speaker':'A','text':'x'}]},0,60,0,False)
    def test_real_shape_completes_and_cache_is_reused(self):
        fixture=fixtures.OpenAIPipelineTests();fixture.setUp()
        try:
            calls=[]
            def caller(audio,model,fields,key):
                calls.append(model)
                if model==o.PRIMARY:return fixture.caller(audio,model,fields,key)
                return {'text':'嗯 好','segments':[{'start':0.0,'end':0.0,'speaker':'A','text':'嗯'},{'start':0.0,'end':5.9,'speaker':'B','text':'好'}]},{'http_status':200,'request_id':'synthetic-test'}
            with patch.object(o.time,'sleep') as sleep:
                out=o.transcribe(fixture.dir,'sk-DUMMY-TEST-NOT-A-KEY',caller)
                self.assertEqual(len(out['segments']),2)
                self.assertIn('时长未确定',(fixture.dir/'transcript-timeline.md').read_text())
                o.transcribe(fixture.dir,'sk-DUMMY-TEST-NOT-A-KEY',caller)
                self.assertEqual(calls,[o.PRIMARY,o.TIMELINE]);sleep.assert_not_called()
        finally:fixture.tearDown()

if __name__=='__main__':unittest.main()

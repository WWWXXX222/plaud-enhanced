import test_openai_pipeline as fixtures
from unittest.mock import patch
import backend as b
import openai_transcription as o


class RecoveryTests(fixtures.OpenAIPipelineTests):
    def test_empty_nonspeech_tail_does_not_block_the_meeting(self):
        audio = (self.dir/'imported.m4a').resolve()
        folder = self.dir.resolve()/'openai'/'fixture'
        folder.mkdir(parents=True)
        tail = self.dir.resolve()/'tail.mp3'; tail.write_bytes(b'nonspeech tail')
        def response(part, model, fields, key):
            if part == tail:
                return {'text': ''}, {'http_status':200, 'request_id':'tail'}
            return self.caller(part, model, fields, key)
        with patch.object(o,'prepare_parts',return_value=(audio,80,folder,[(audio,0,56),(tail,56,24)])), patch.object(o,'verify_no_speech',create=True,return_value={'no_speech_detected':True,'evidence_files':[]}):
            result = o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',response)
        self.assertEqual(result['coverage'][-1]['status'],'no_speech_detected')
        self.assertEqual(result['coverage'][-1]['end_seconds'],80)
        self.assertEqual(len(result['segments']),1)
        self.assertIn('今天不要上线',result['text'])

    def test_timeout_is_retried_without_restarting_completed_primary(self):
        attempts=[]
        def response(audio, model, fields, key):
            attempts.append(model)
            if model == o.TIMELINE and attempts.count(model)==1: raise TimeoutError('temporary')
            return self.caller(audio,model,fields,key)
        with patch.object(o.time,'sleep'):
            o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',response)
        self.assertEqual(attempts,[o.PRIMARY,o.TIMELINE,o.TIMELINE])

    def test_new_automatic_meeting_does_not_require_context_or_images(self):
        self.ready()
        self.m.update(auto_archive=True,participants='',purpose='',images=[])
        b.atomic(self.dir/'meeting.json',self.m)
        receipt=b.submit(self.dir,self.vault)
        context=b.read(__import__('pathlib').Path(receipt['raw_dir'])/'context.json')
        self.assertEqual(context['participants'],'')
        self.assertEqual(context['purpose'],'')
        self.assertEqual(context['missing_fields'],['participants','purpose','images'])
        self.assertEqual(context['source'],'optional-user-context')

    def test_empty_long_response_requires_smaller_windows_before_publication(self):
        attempts=[]
        def empty(*args):
            attempts.append(True)
            return {'text':''},{'http_status':200}
        folder=self.dir/'openai'/'fixture';folder.mkdir(parents=True)
        with patch.object(o,'verify_no_speech',return_value={'no_speech_detected':False,'evidence_files':[]}):
            with self.assertRaises(o.RetryableTranscriptionError) as caught:
                o.request_with_recovery(self.dir,self.dir/'imported.m4a',o.PRIMARY,[],'',empty,folder,0,120,0,False)
        self.assertTrue(caught.exception.shrinkable)
        self.assertEqual(len(attempts),1)
        self.assertFalse((self.dir/'transcript.json').exists())

    def test_short_unrecognized_tail_is_explicitly_partial_and_preserved_in_archive(self):
        audio=(self.dir/'imported.m4a').resolve()
        folder=self.dir.resolve()/'openai'/'fixture';folder.mkdir(parents=True)
        tail=self.dir.resolve()/'tail.mp3';tail.write_bytes(b'possible noise or speech')
        def response(part,model,fields,key):
            if part==tail:return {'text':''},{'http_status':200}
            return self.caller(part,model,fields,key)
        with patch.object(o,'prepare_parts',return_value=(audio,80,folder,[(audio,0,56),(tail,56,24)])), patch.object(o,'verify_no_speech',return_value={'no_speech_detected':False,'evidence_files':[]}):
            result=o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',response)
        self.assertFalse(result['primary_text_complete'])
        self.assertEqual(result['coverage'][-1]['status'],'unresolved_primary')
        self.assertEqual(result['transcription_gaps'][0]['start_seconds'],56)
        self.assertEqual(result['transcription_gaps'][0]['end_seconds'],80)
        self.assertIn('今天不要上线',result['text'])
        self.assertIn('系统标注',result['text'])
        self.assertEqual(result['segments'][-1]['role'],'unresolved_primary_transcription')
        self.assertNotIn(o.TIMELINE,[r['model'] for r in b.read(self.dir/'openai-result.json')['requests'] if r['offset_seconds']==56])
        b.report(self.dir,'complete','test')
        with patch.object(b,'duration',return_value=80):receipt=b.submit(self.dir,self.vault)
        packaged=b.read(__import__('pathlib').Path(receipt['raw_dir'])/'transcript.json')
        self.assertFalse(packaged['primary_text_complete'])
        self.assertEqual(packaged['transcription_gaps'],result['transcription_gaps'])

    def test_recovered_words_are_marked_unconfirmed_in_text_timeline_and_archive(self):
        original=(self.dir/'imported.m4a').resolve()
        def response(audio,model,fields,key):
            if model==o.PRIMARY and audio==original:return {'text':''},{'http_status':200}
            return self.caller(audio,model,fields,key)
        def audio_slice(part,target,start,span):target.write_text(f'{start}:{span}')
        with patch.object(o,'verify_no_speech',return_value={'no_speech_detected':False,'evidence_files':[]}), patch.object(o,'slice_reference_audio',side_effect=audio_slice):
            result=o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',response)
        self.assertFalse(result['primary_text_complete'])
        self.assertEqual(len(result['transcription_review_windows']),2)
        self.assertEqual(result['transcription_gaps'],[])
        self.assertTrue(result['text'].startswith('【系统标注：'))
        self.assertIn('不能据此确认会议事实或决定',result['text'])
        self.assertIn('梅负责 rollback test。今天不要上线。',result['text'])
        self.assertEqual(sum(s['role']=='primary_recovery_review' for s in result['segments']),2)
        b.report(self.dir,'complete','test');receipt=b.submit(self.dir,self.vault)
        packaged=b.read(__import__('pathlib').Path(receipt['raw_dir'])/'transcript.json')
        self.assertEqual(packaged['transcription_review_windows'],result['transcription_review_windows'])
        self.assertFalse(packaged['primary_text_complete'])

    def test_invalid_key_is_not_retried(self):
        attempts=[]
        def invalid(*args):
            attempts.append(True);raise ValueError('OpenAI 密钥无效')
        with patch.object(o.time,'sleep') as sleep:
            with self.assertRaises(ValueError):o.transcribe(self.dir,'sk-DUMMY-TEST-NOT-A-KEY',invalid)
        self.assertEqual(len(attempts),1);sleep.assert_not_called()

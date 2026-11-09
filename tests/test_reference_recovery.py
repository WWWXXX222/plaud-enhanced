import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import backend as b
import openai_transcription as o
from speech_segmentation import annotate_speakers


class ReferenceRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)
        self.folder = self.directory/'openai'/'fixture'
        self.folder.mkdir(parents=True)
        self.audio = self.directory/'audio.mp3'
        self.audio.write_bytes(b'fixture audio')
        self.fields = [('response_format', 'diarized_json'), ('chunking_strategy', 'auto')]

    def tearDown(self):
        self.tmp.cleanup()

    def test_equal_raw_starts_with_fractional_offset_are_not_backwards(self):
        raw = {'segments': [dict(start=530.356, end=531, text='a', speaker='A'),
                            dict(start=530.356, end=532, text='b', speaker='B')]}
        result = o.reference_segments(raw, 598.7828595000001, 600.905672, 1, True)
        self.assertEqual(result[0]['start_seconds'], result[1]['start_seconds'])
        raw['segments'][1]['start'] = 530.3559
        with self.assertRaises(ValueError):
            o.reference_segments(raw, 598.7828595000001, 600.905672, 1, True)

    def test_recover_valid_rejected_response_without_another_request(self):
        raw = {'text': '今天不发布。Keep the original language.', 'segments': [
            dict(start=530.356, end=531, text='今天不发布。', speaker='A'),
            dict(start=530.356, end=532, text='Keep the original language.', speaker='B')]}
        evidence = self.folder/'rejected'/'0001-gpt-4o-transcribe-diarize-fixture.json'
        failure = dict(model=o.TIMELINE, audio_sha256=b.digest(self.audio),
                       parameters=[list(x) for x in self.fields], offset_seconds=598.7828595000001,
                       span_seconds=600.905672)
        b.atomic(evidence, dict(response=raw, receipt={'http_status': 200, 'request_id': 'fixture'}, failure=failure))
        with patch.object(o, 'audio_request', side_effect=AssertionError('must reuse evidence')) as caller:
            result = o.load_response(self.directory, self.audio, o.TIMELINE, self.fields, '', caller,
                                     self.folder, 598.7828595000001, 600.905672, 1, True,
                                     '0001-'+o.TIMELINE, cached_only=True)
        self.assertEqual(result[0], raw)
        self.assertEqual(result[1]['recovered_from'], str(evidence.relative_to(self.directory)))
        self.assertTrue(evidence.exists())

    def test_wrong_audio_rejected_response_is_never_recovered(self):
        evidence = self.folder/'rejected'/'0000-gpt-4o-transcribe-diarize-fixture.json'
        b.atomic(evidence, dict(response={'text':'wrong audio', 'segments':[
            dict(start=0, end=1, speaker='A', text='wrong audio')]}, receipt={'http_status':200},
            failure=dict(model=o.TIMELINE, audio_sha256='wrong', parameters=[list(x) for x in self.fields],
                         offset_seconds=0, span_seconds=60)))
        self.assertIsNone(o.load_response(self.directory, self.audio, o.TIMELINE, self.fields, '', None,
                                         self.folder, 0, 60, 0, False, '0000-'+o.TIMELINE, cached_only=True))

    def test_long_reference_is_bounded_and_resumes_successful_children(self):
        calls = []
        def audio_slice(part, target, start, span):
            target.write_bytes(f'{start}:{span}'.encode())
        def caller(audio, model, fields, key):
            start, span = map(float, audio.read_text().split(':'))
            calls.append(start)
            self.assertLessEqual(span, 150)
            return {'text':'今天不发布。', 'segments':[dict(start=0, end=1, text='今天不发布。', speaker='A')]}, {'http_status':200}
        with patch.object(o, 'slice_reference_audio', side_effect=audio_slice):
            first = o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                                         self.folder, 598.7828595, 600.905672, 1, True)
            second = o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                                          self.folder, 598.7828595, 600.905672, 1, True)
        self.assertEqual(len(calls), 5)
        self.assertEqual(first, second)
        spans = [x[1] for x in first]
        self.assertAlmostEqual(spans[0]['offset_seconds'], 598.7828595)
        self.assertAlmostEqual(spans[-1]['offset_seconds']+spans[-1]['span_seconds'], 1199.6885315)
        for a, z in zip(spans, spans[1:]):
            self.assertAlmostEqual(a['offset_seconds']+a['span_seconds'], z['offset_seconds'])

    def test_fractional_endpoint_rounding_recovers_without_discarding_cache(self):
        span = 419.87629649999997
        rounded_end = span * 3 / 3
        self.assertNotEqual(rounded_end, span)
        name = '0001-' + o.TIMELINE
        plan_path = self.folder / (name + '.split.json')
        plan = dict(audio_sha256=b.digest(self.audio), offset_seconds=589.43,
                    span_seconds=span, policy='bounded-reference-v1',
                    ranges=[[0, span/3], [span/3, span*2/3], [span*2/3, rounded_end]])
        b.atomic(plan_path, plan)
        calls = []
        def caller(*args):
            calls.append(True)
            return {'text':'今天不发布。Keep 中文。', 'segments':[
                dict(start=0, end=1, text='今天不发布。Keep 中文。', speaker='A')]}, {'http_status':200}
        def slice_audio(part, target, start, length):
            target.write_text(f'{start}:{length}')
        with patch.object(o, 'slice_reference_audio', side_effect=slice_audio):
            first = o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                self.folder, 589.43, span, 1, True)
            again = o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                self.folder, 589.43, span, 1, True)
        self.assertEqual(len(calls), 3)
        self.assertEqual(first, again)
        self.assertEqual(b.read(plan_path), plan)

    def test_fractional_new_plan_ends_at_exact_span(self):
        span = 419.87629649999997
        def slice_audio(part, target, start, length):
            target.write_text(f'{start}:{length}')
        response = {'text':'中文 English', 'segments':[dict(start=0,end=1,text='中文 English',speaker='A')]}
        with patch.object(o, 'slice_reference_audio', side_effect=slice_audio):
            o.timeline_responses(self.directory, self.audio, self.fields, '',
                lambda *args:(response, {'http_status':200}), self.folder, 0, span, 0, False)
        self.assertEqual(b.read(self.folder/('0000-'+o.TIMELINE+'.split.json'))['ranges'][-1][1], span)

    def test_real_endpoint_gap_is_not_treated_as_roundoff(self):
        span = 419.87629649999997
        plan = dict(audio_sha256=b.digest(self.audio),offset_seconds=0,span_seconds=span,
                    ranges=[[0,140],[140,280],[280,span-0.000001]])
        b.atomic(self.folder/('0000-'+o.TIMELINE+'.split.json'),plan)
        with patch.object(o,'slice_reference_audio', side_effect=AssertionError('invalid plan')):
            with self.assertRaisesRegex(ValueError, '未覆盖完整音频'):
                o.timeline_responses(self.directory,self.audio,self.fields,'',None,
                    self.folder,0,span,0,False)

    def test_request_budget_survives_worker_restarts(self):
        calls = []
        def fail(*args):
            calls.append(True)
            raise TimeoutError('fixture timeout')
        with patch.object(o.time, 'sleep'):
            for _ in range(2):
                with self.assertRaises(o.RetryableTranscriptionError):
                    o.request_with_recovery(self.directory, self.audio, o.TIMELINE, self.fields, '', fail,
                                            self.folder, 0, 30, 0, False)
            with self.assertRaises(o.RetryableTranscriptionError):
                o.request_with_recovery(self.directory, self.audio, o.TIMELINE, self.fields, '', fail,
                                        self.folder, 0, 30, 0, False)
        self.assertEqual(len(calls), 6)
        # A prolonged outage cools down across process restarts, then probes the
        # same window again. It must never become a permanent manual-stop state.
        budget_path=next(self.folder.glob('attempts-*.json'))
        budget=b.read(budget_path)
        self.assertGreater(budget['retry_at'],o.time.time())
        response={'text':'原文保留。', 'segments':[dict(start=0,end=1,text='原文保留。',speaker='A')]}
        with patch.object(o.time,'time',return_value=budget['retry_at']+1):
            result=o.request_with_recovery(self.directory,self.audio,o.TIMELINE,self.fields,'',
                lambda *args:(response,{'http_status':200}),self.folder,0,30,0,False)
        self.assertEqual(result[0],response)
        self.assertEqual(b.read(budget_path)['failures'],0)

    def test_failed_reference_splits_once_then_reuses_children_on_restart(self):
        calls = []
        def audio_slice(part, target, start, span):
            target.write_bytes(f'{start}:{span}'.encode())
        def caller(audio, model, fields, key):
            calls.append(audio.name)
            if audio == self.audio: raise TimeoutError('long request')
            return {'text':'今天不发布。', 'segments':[dict(start=0, end=1, text='今天不发布。', speaker='A')]}, {'http_status':200}
        with patch.object(o, 'slice_reference_audio', side_effect=audio_slice), patch.object(o.time, 'sleep'):
            for _ in range(2):
                result = o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                                              self.folder, 0, 120, 0, False)
        self.assertEqual(len(result), 2)
        self.assertEqual(len(calls), 5)  # three failed parent calls, two successful children

    def test_subchunk_labels_do_not_imply_the_same_person(self):
        raw = {'segments':[dict(start=0, end=4, speaker='A', text='我是甲。')]}
        first = o.reference_segments(raw,0,60,0,True)[0]
        raw['segments'][0]['text'] = '我是乙。'
        second = o.reference_segments(raw,60,60,0,True)[0]
        first['speaker_scope'], second['speaker_scope'] = 'child-a', 'child-b'
        result = annotate_speakers([first,second])
        self.assertTrue(all(s['speaker_status'] == 'unconfirmed' for s in result))
        self.assertTrue(all(not s['speaker_issues'] for s in result))

    def test_rate_limit_does_not_multiply_requests_by_splitting(self):
        with patch.object(o.time, 'sleep'), patch.object(o, 'slice_reference_audio') as split:
            with self.assertRaises(o.RetryableTranscriptionError):
                o.timeline_responses(self.directory, self.audio, self.fields, '',
                    lambda *args: (_ for _ in ()).throw(o.RetryableTranscriptionError('rate limited')),
                    self.folder, 0, 120, 0, False)
        split.assert_not_called()

    def test_interruption_keeps_completed_sibling_and_resumes_only_missing_one(self):
        calls = []
        def audio_slice(part, target, start, span):
            target.write_bytes(f'{start}:{span}'.encode())
        def caller(audio, model, fields, key):
            calls.append(audio.name)
            if len(calls) == 2: raise ValueError('simulated worker interruption')
            return {'text':'原文 English', 'segments':[dict(start=0, end=1, text='原文 English', speaker='A')]}, {'http_status':200}
        with patch.object(o, 'slice_reference_audio', side_effect=audio_slice):
            with self.assertRaises(ValueError):
                o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                                      self.folder, 0, 300, 0, False, depth=1)
            result = o.timeline_responses(self.directory, self.audio, self.fields, '', caller,
                                          self.folder, 0, 300, 0, False, depth=1)
        self.assertEqual(len(result), 2)
        self.assertEqual(len(calls), 3)
        self.assertNotEqual(calls[0], calls[-1])

    def test_empty_auxiliary_response_is_uncertain_not_silence_or_infinite_retry(self):
        calls=[]
        def caller(*args):
            calls.append(True)
            return {'text':'','segments':[]},{'http_status':200}
        with patch.object(o,'verify_no_speech',return_value={'no_speech_detected':False,'evidence_files':[]}):
            raw,receipt,check=o.request_with_recovery(self.directory,self.audio,o.TIMELINE,self.fields,'',caller,
                self.folder,0,30,0,False)
        self.assertEqual(len(calls),1)
        self.assertEqual(raw['text'],'')
        self.assertFalse(check['no_speech_detected'])
        self.assertEqual(receipt['reference_issue'],'empty_reference_with_possible_speech')

    def test_exhausted_empty_reference_recovers_saved_response_without_resetting_budget(self):
        evidence=self.folder/'rejected'/f'0000-{o.TIMELINE}-fixture.json'
        b.atomic(evidence,dict(response={'text':'','segments':[]},receipt={'http_status':200},
            failure=dict(model=o.TIMELINE,audio_sha256=b.digest(self.audio),parameters=[list(x) for x in self.fields],
                         offset_seconds=0,span_seconds=30)))
        with patch.object(o,'verify_no_speech',return_value={'no_speech_detected':False,'evidence_files':[]}):
            result=o.load_response(self.directory,self.audio,o.TIMELINE,self.fields,'',None,self.folder,0,30,0,False,
                                   '0000-'+o.TIMELINE,cached_only=True)
        self.assertEqual(result[1]['reference_issue'],'empty_reference_with_possible_speech')
        self.assertEqual(result[1]['recovered_from'],str(evidence.relative_to(self.directory)))

    def test_empty_parent_cannot_replace_existing_split_children(self):
        name='0000-'+o.TIMELINE
        b.atomic(self.folder/(name+'.split.json'),dict(ranges=[[0,15],[15,30]]))
        evidence=self.folder/'rejected'/f'{name}-fixture.json'
        b.atomic(evidence,dict(response={'text':'','segments':[]},receipt={'http_status':200},
            failure=dict(model=o.TIMELINE,audio_sha256=b.digest(self.audio),parameters=[list(x) for x in self.fields],
                         offset_seconds=0,span_seconds=30)))
        with patch.object(o,'verify_no_speech',side_effect=AssertionError('must resume children')):
            result=o.load_response(self.directory,self.audio,o.TIMELINE,self.fields,'',None,self.folder,0,30,0,False,
                                   name,cached_only=True)
        self.assertIsNone(result)
        self.assertFalse((self.folder/(name+'.raw.json')).exists())


if __name__ == '__main__':
    unittest.main()

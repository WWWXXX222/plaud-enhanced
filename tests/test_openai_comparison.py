import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).resolve().parents[1] / 'tools/openai_comparison.py')
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class ComparisonRequestTests(unittest.TestCase):
    def setUp(self):
        import hashlib
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        audio = Path(temporary.name)/'synthetic.m4a'; audio.write_bytes(b'synthetic audio for mocked HTTP tests')
        for key, value in [('AUDIO', audio), ('EXPECTED_SHA', hashlib.sha256(audio.read_bytes()).hexdigest())]:
            change = patch.object(comparison, key, value); change.start(); self.addCleanup(change.stop)

    def test_diarization_uses_required_long_audio_chunking_without_answer_prompt(self):
        model, fields = comparison.MODELS[0]
        body, boundary = comparison.multipart(model, fields, b'synthetic fixture')
        self.assertIn(b'diarized_json', body)
        self.assertIn(b'chunking_strategy', body)
        self.assertNotIn(b'prompt', body)
        self.assertNotIn(b'known_speaker', body)
        self.assertTrue(body.endswith(f'--{boundary}--\r\n'.encode()))

    def test_multilingual_hints_do_not_force_a_single_output_language(self):
        _, fields = comparison.MODELS[1]
        self.assertEqual([value for name, value in fields if name == 'languages[]'], ['zh', 'en'])
        self.assertNotIn('language', [name for name, _ in fields])

    def test_bad_credentials_do_not_enter_evidence_and_stop_second_call(self):
        dummy_key = 'sk-DUMMY-TEST-NOT-A-REAL-KEY'
        error = HTTPError('https://api.openai.com/v1/audio/transcriptions', 401, 'Unauthorized', {},
                          io.BytesIO(json.dumps({'error': {'code': 'invalid_api_key', 'message': dummy_key}}).encode()))
        with tempfile.TemporaryDirectory() as folder, patch.object(comparison, 'OUTPUT', Path(folder)), patch.object(comparison.request, 'build_opener') as factory:
            factory.return_value.open.side_effect = error
            comparison.run_comparison(dummy_key)
            self.assertEqual(factory.return_value.open.call_count, 1)
            saved = '\n'.join(path.read_text() for path in Path(folder).glob('*'))
            self.assertNotIn(dummy_key, saved)
            self.assertIn('invalid_api_key', saved)
            self.assertFalse(list(Path(folder).glob('*.raw.json')))

    def test_credentials_cannot_be_forwarded_on_redirect(self):
        self.assertIsNone(comparison.NoRedirect().redirect_request(None, None, 307, '', {}, 'https://elsewhere.invalid'))

    def test_successful_results_reused_without_second_paid_call(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(comparison, 'OUTPUT', Path(folder)), patch.object(comparison.request, 'build_opener') as factory:
            for model, fields in comparison.MODELS:
                comparison.save_json(Path(folder) / f'{model}.raw.json', {'text':'original response'})
                comparison.save_json(Path(folder) / f'{model}.request.json', {
                    'status':'success', 'model':model, 'audio_sha256':comparison.EXPECTED_SHA,
                    'parameters':fields})
            comparison.run_comparison('sk-DUMMY-TEST-NOT-A-REAL-KEY')
            factory.return_value.open.assert_not_called()
            self.assertEqual(comparison.STATE['phase'], 'complete')

    def test_changed_evidence_is_not_overwritten_or_sent_again(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(comparison, 'OUTPUT', Path(folder)), patch.object(comparison.request, 'build_opener') as factory:
            model, fields = comparison.MODELS[0]
            comparison.save_json(Path(folder) / f'{model}.raw.json', {'text':'immutable'})
            comparison.save_json(Path(folder) / f'{model}.request.json', {
                'status':'success', 'model':model, 'audio_sha256':'wrong', 'parameters':fields})
            comparison.run_comparison('sk-DUMMY-TEST-NOT-A-REAL-KEY')
            factory.return_value.open.assert_not_called()
            self.assertEqual(comparison.STATE['phase'], 'failed')
            self.assertEqual(json.loads((Path(folder) / f'{model}.raw.json').read_text())['text'], 'immutable')


if __name__ == '__main__':
    unittest.main()

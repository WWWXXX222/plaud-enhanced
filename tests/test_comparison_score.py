import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('score', Path(__file__).resolve().parents[1] / 'tools/score_transcription_comparison.py')
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)


class ComparisonScoreTests(unittest.TestCase):
    def setUp(self):
        self.reference = {'duration': 8, 'turns': [
            {'start': 0, 'end': 2, 'speaker': 'A'},
            {'start': 3, 'end': 5, 'speaker': 'B'},
            {'start': 6, 'end': 8, 'speaker': 'A'}]}

    def test_consistent_anonymous_labels_can_match_without_renaming_results(self):
        segments = [dict(t, speaker={'A':'2', 'B':'1'}[t['speaker']]) for t in self.reference['turns']]
        actual = score.timeline_score(self.reference, segments)
        self.assertEqual(actual['reference_interval_speaker_agreement'], 1)
        self.assertEqual(segments[0]['speaker'], '2')

    def test_merged_speakers_lose_credit(self):
        actual = score.timeline_score(self.reference, [{'start':0, 'end':8, 'speaker':'1'}])
        self.assertAlmostEqual(actual['reference_interval_speaker_agreement'], 2/3, places=3)

    def test_multiple_overlapping_speakers_not_double_counted(self):
        actual = score.timeline_score(self.reference, [
            {'start':0, 'end':8, 'speaker':'1'}, {'start':0, 'end':8, 'speaker':'2'}])
        self.assertEqual(actual['reference_interval_speaker_agreement'], 0)

    def test_missing_timeline_is_not_invented(self):
        self.assertFalse(score.timeline_score(self.reference, [])['available'])

    def test_edit_metric_preserves_language_changes(self):
        self.assertEqual(score.tokens('你好 API，$500！'), ['你', '好', 'api', '500'])
        self.assertEqual(score.edit_distance(['你', '好'], ['hello']), 2)


if __name__ == '__main__':
    unittest.main()

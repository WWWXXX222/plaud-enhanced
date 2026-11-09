#!/usr/bin/env python3
"""Offline scoring only: never sends reference text or derived labels to an API.

The mixed edit rate treats each Chinese character and each English word/number
as a token. It does NOT normalize translated text, numeral spelling or Han
variants. Speaker agreement is a reference-interval proxy, not a standard DER:
the synthetic reference includes within-turn pauses and no overlapping speech.
"""
import itertools
import json
import math
from pathlib import Path
import re
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'evidence/openai-comparison-2026-10-18'


def tokens(text):
    return re.findall(r'[\u3400-\u9fff]|[a-z]+(?:\x27[a-z]+)?|\d+', unicodedata.normalize('NFKC', text).lower())


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        row = [i]
        for j, right in enumerate(b, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j-1] + (left != right)))
        previous = row
    return previous[-1]


def timeline_score(reference, raw_segments):
    segments = []
    errors = []
    for i, segment in enumerate(raw_segments):
        start, end = segment.get('start', segment.get('start_seconds')), segment.get('end', segment.get('end_seconds'))
        if (not all(isinstance(x, (float, int)) and not isinstance(x, bool) and math.isfinite(x) for x in (start, end))
                or not 0 <= start < end <= reference['duration'] + 0.25):
            errors.append(f'invalid time in segment {i}')
            continue
        if segments and start < segments[-1]['start']:
            errors.append(f'non-monotonic start in segment {i}')
        segments.append(dict(start=start, end=end, speaker=segment.get('speaker'), text=segment.get('text', '')))
    labels = sorted({s['speaker'] for s in segments if isinstance(s['speaker'], str) and s['speaker']})
    turns = reference['turns']
    speakers = sorted({t['speaker'] for t in turns})
    if not segments:
        return {'available': False, 'validation_errors': errors}
    # Count each point at most once. Ambiguous overlapping labels are not credited.
    boundaries = sorted({x for s in segments + turns for x in (s['start'], s['end'])})
    matrix = {(truth, label): 0.0 for truth in speakers for label in labels}
    covered = 0.0
    for left, right in zip(boundaries, boundaries[1:]):
        middle = (left + right) / 2
        truth = next((t['speaker'] for t in turns if t['start'] <= middle < t['end']), None)
        predicted = {s['speaker'] for s in segments if s['start'] <= middle < s['end'] and s['speaker'] in labels}
        if truth is not None and len(predicted) == 1:
            covered += right - left
            matrix[truth, next(iter(predicted))] += right - left
    best, mapping = 0, {}
    # One-to-one label matching is evaluation only, never a transcript correction.
    count = min(len(speakers), len(labels))
    for selected_truth in itertools.combinations(speakers, count):
        for predicted in itertools.permutations(labels, count):
            score = sum(matrix[t, p] for t, p in zip(selected_truth, predicted))
            if score > best:
                best, mapping = score, dict(zip(predicted, selected_truth))
    total = sum(t['end'] - t['start'] for t in turns)
    per_turn = []
    for turn in turns:
        overlap = {p: sum(max(0, min(turn['end'], s['end']) - max(turn['start'], s['start']))
                          for s in segments if s['speaker'] == p) for p in labels}
        dominant = max(overlap, key=overlap.get) if overlap and max(overlap.values()) > 0 else None
        per_turn.append({'reference_speaker': turn['speaker'], 'reference_start': turn['start'],
                         'dominant_label': dominant, 'dominant_overlap_seconds': round(overlap.get(dominant, 0), 3)})
    changes = []
    for prior, current in zip(segments, segments[1:]):
        if prior['speaker'] != current['speaker']:
            changes.append((prior['end'] + current['start']) / 2)
    expected = [(a['end'], b['start']) for a, b in zip(turns, turns[1:]) if a['speaker'] != b['speaker']]
    change_errors = [min((max(lo - c, c - hi, 0) for c in changes), default=None) for lo, hi in expected]
    return {'available': True, 'segments': len(segments), 'speaker_labels': labels, 'validation_errors': errors,
            'reference_interval_speaker_agreement': round(best / total, 4),
            'unambiguous_labeled_interval_coverage': round(covered / total, 4),
            'evaluation_only_label_mapping': mapping, 'per_turn': per_turn,
            'speaker_change_midpoints': changes,
            'distance_to_nearest_change_from_each_reference_gap_seconds': change_errors,
            'note': 'Synthetic turn-interval proxy, not standard DER or word timestamp accuracy. Mapping used only for scoring.'}


def score(reference, text, segments):
    truth = ' '.join(t['text'] for t in reference['turns'])
    target, actual = tokens(truth), tokens(text)
    distance = edit_distance(target, actual)
    return {'reference_tokens': len(target), 'output_tokens': len(actual), 'token_edits': distance,
            'mixed_token_edit_rate': round(distance / len(target), 4),
            'reference_han_characters': len(re.findall(r'[\u3400-\u9fff]', truth)),
            'output_han_characters': len(re.findall(r'[\u3400-\u9fff]', text)),
            'timeline': timeline_score(reference, segments)}


def main():
    reference = json.loads((ROOT / 'fixtures/mixed-speakers/reference.json').read_text())
    baseline = json.loads((ROOT / 'evidence/language-diagnosis-2026-10-18/zh-transcript.json').read_text())
    result = {'method': __doc__, 'synthetic': True, 'duration': reference['duration'],
              'Plaud': score(reference, ' '.join(s['text'] for s in baseline['segments']), baseline['segments'])}
    for model in ('gpt-4o-transcribe-diarize', 'gpt-transcribe'):
        path = OUT / f'{model}.raw.json'
        if path.exists():
            raw = json.loads(path.read_text())
            result[model] = score(reference, raw['text'], raw.get('segments', []))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'metrics.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()

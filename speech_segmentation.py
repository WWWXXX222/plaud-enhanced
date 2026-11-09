"""Content-neutral chunk boundaries and conservative speaker presentation.

No fixture, participant list or expected sentence is used to repair model text.
Provider responses remain immutable; all display decisions carry provenance.
"""
import re

CHUNK_SECONDS = 600
OVERLAP_SECONDS = 20
POLICY = 'pause-aware-v2'


def plan_ranges(length, silences):
    parts = []
    start = 0.0
    while length - start > CHUNK_SECONDS + 60:
        target = start + CHUNK_SECONDS
        candidates = [(a + z) / 2 for a, z in silences
                      if z - a >= .4 and target - 60 <= (a + z) / 2 <= target + 60]
        end = min(candidates, key=lambda x: abs(x-target)) if candidates else target
        parts.append((start, end))
        start = end if candidates else end - OVERLAP_SECONDS
    parts.append((start, length))
    return parts


def normalized_chars(text):
    pairs = [(c.lower(), i) for i, c in enumerate(text) if c.isalnum()]
    return ''.join(c for c, _ in pairs), [i for _, i in pairs]


def join_primary(chunks):
    """Only deduplicate an exact, substantial overlap; never guess missing words."""
    text = ''
    joins = []
    previous_end = 0
    for item in chunks:
        current = item['text']
        if not text:
            text = current
        elif item['start'] < previous_end:
            left, positions = normalized_chars(text)
            right, _ = normalized_chars(current)
            match = next((n for n in range(min(len(left), len(right), 1600), 11, -1)
                          if left[-n:] == right[:n]), 0)
            if match:
                text = text[:positions[-match]] + current
                joins.append(dict(at=item['start'], status='exact_overlap_deduplicated', matched_characters=match))
            else:
                # Both originals remain visible. The archive policy forbids deriving
                # a decision from these unresolved boundary fragments in isolation.
                text += '\n\n【重叠分段边界待核实：以下片段不可单独作为决定依据】\n\n' + current
                joins.append(dict(at=item['start'], status='unresolved_overlap', decision_extraction_allowed=False))
        else:
            text += '\n\n' + current
            joins.append(dict(at=item['start'], status='pause_boundary'))
        previous_end = item['end']
    return text, joins


def annotate_speakers(segments):
    """Suppress unsupported identity claims, not speech or raw provider labels."""
    groups = {}
    for s in segments:
        groups.setdefault((s.get('speaker_scope', s.get('part_index', 0)), s['raw_speaker']), []).append(s)
    for group in groups.values():
        mentions = set()
        for s in group:
            mentions.update(re.findall(r'我(?:是|叫)\s*([^，。！？、\n]{1,24})', s['text']))
            mentions.update(re.findall(r"\b(?:I am|I'm|My name is)\s+([A-Z][a-z]+)\b", s['text']))
        conflict = len(mentions) > 1
        for s in group:
            issues = []
            if conflict:
                issues.append('conflicting_self_introductions_under_one_label')
                s['speaker'] = '发言片段（标签可能合并多人，待确认）'
            if len(group) == 1 and s['end_seconds'] - s['start_seconds'] <= 1.0 and len(normalized_chars(s['text'])[0]) <= 4:
                issues.append('brief_label_insufficient_for_distinct_speaker')
                s['speaker'] = '短片段（说话人待确认）'
            s['speaker_issues'] = issues
            s['speaker_status'] = 'unconfirmed'
            s['speaker_identity_verified'] = False
    return segments

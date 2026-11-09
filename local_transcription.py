"""Bounded offline transcription, cached by source bytes and model identity."""
import math
import os
from pathlib import Path
import subprocess
import time
import backend as b

PART_SECONDS = 300

def transcribe(directory):
    directory, meeting = b.meeting(directory)
    if meeting.get('capture_state') != 'captured': raise ValueError('请先保存录音。')
    if (directory/'submission.json').exists(): return b.read(directory/'transcript.json')
    with b.lock(directory/'.processing.lock', True):
        retry = directory/'local-retry.json'
        try:
            files = [b.local_file(directory, rel) for rel in meeting.get('audio_files', [])]
            if not files: raise ValueError('没有可转写的音频。')
            worker = b.config.resource('OfflineSpeechWorker')
            model = b.config.resource('OfflineSpeechModel')
            identity = {'inputs': {p.name: b.digest(p) for p in files},
                        'model': b.digest(model/'manifest.json'), 'worker': b.digest(worker),
                        'language': meeting.get('language', 'auto')}
            cache = directory/'offline-parts'; cache.mkdir(exist_ok=True)
            key = __import__('hashlib').sha256(__import__('json').dumps(identity, sort_keys=True).encode()).hexdigest()
            cache = cache/key; cache.mkdir(exist_ok=True)
            length = max(b.duration(p) for p in files)
            audio = directory/'audio.wav'
            marker = directory/'offline-audio.json'
            if not audio.exists() or not marker.exists() or b.read(marker) != identity:
                b.report(directory, 'processing', '正在本机整理录音…', .02)
                args = [str(b.FFMPEG), '-nostdin', '-v', 'error', '-y']
                for path in files: args += ['-i', str(path)]
                filters = [f'[{i}:a]aresample=16000,asetpts=PTS-STARTPTS[a{i}]' for i in range(len(files))]
                filters += [''.join(f'[a{i}]' for i in range(len(files))) +
                            (f'amix=inputs={len(files)}:duration=longest:normalize=0,' if len(files)>1 else '') +
                            'alimiter=limit=0.95:latency=1[out]']
                tmp = directory/'audio.partial.wav'
                subprocess.run(args+['-filter_complex', ';'.join(filters), '-map', '[out]', '-ar', '16000', '-ac', '1', str(tmp)],
                               capture_output=True, check=True, timeout=max(120, length))
                if abs(b.duration(tmp)-length)>2: raise ValueError('音频长度未通过核验。')
                os.replace(tmp, audio); b.atomic(marker, identity)
            all_segments = []; originals = []
            count = math.ceil(length/PART_SECONDS)
            for index in range(count):
                offset = index*PART_SECONDS; seconds = min(PART_SECONDS, length-offset)
                saved = cache/f'{index}.json'
                b.report(directory, 'processing', f'本机离线转写 {index+1}/{count} 段…', .05+.9*index/count)
                if not saved.exists():
                    wav = cache/'part.wav'; pending = cache/'result.partial.json'
                    pending.unlink(missing_ok=True)
                    subprocess.run([str(b.FFMPEG), '-nostdin', '-v', 'error', '-y', '-ss', str(offset),
                        '-i', str(audio), '-t', str(seconds), str(wav)], capture_output=True, check=True, timeout=120)
                    with (directory/'transcription.log').open('ab') as log:
                        subprocess.run([str(worker), str(model), str(wav), str(pending), identity['language']],
                            stdout=log, stderr=log, check=True, timeout=max(600, seconds*8))
                    raw = b.read(pending)
                    validate(raw, seconds)
                    os.replace(pending, saved); wav.unlink(missing_ok=True)
                raw = b.read(saved); validate(raw, seconds); originals.append(raw)
                for segment in raw['segments']:
                    if not segment['text'].strip(): continue
                    all_segments.append(dict(segment, start_seconds=offset+segment['start_seconds'],
                        end_seconds=min(length, offset+segment['end_seconds']), speaker=None,
                        speaker_issues=['身份待确认'] + (['识别质量待核对'] if segment.get('needs_review') else [])))
            if not all_segments: raise ValueError('未识别到清晰语音，录音已保留，请回听核对。')
            result = dict(source='MeetingMemory', engine='WhisperKit offline', duration=length,
                segments=all_segments, speaker_identification=False, language=identity['language'],
                timestamp_role='model-estimated', created_at=b.stamp())
            b.atomic(directory/'whisper-original.json', {'parts':originals, 'identity':identity})
            b.atomic(directory/'transcript.json', result)
            b.atomic(directory/'transcript.txt', '\n\n'.join(f"[{b.timestamp(s['start_seconds'])}] 身份待确认：{s['text']}" for s in all_segments)+'\n')
            b.atomic(retry, {'attempts':0, 'retry_at':0})
            b.report(directory, 'complete', '离线转写完成，正在准备分析归档', 1)
            return result
        except Exception:
            previous = b.read(retry) if retry.exists() else {}
            attempts = previous.get('attempts', 0)+1
            b.atomic(retry, {'attempts':attempts, 'retry_at':time.time()+min(3600, 30*2**min(attempts,7))})
            b.report(directory, 'retry_wait', '离线转写暂时中断，进度已保存，将自动续做。', retryable=True)
            raise

def validate(raw, seconds):
    if not isinstance(raw.get('segments'), list): raise ValueError('离线转写格式无效。')
    previous = -1
    for s in raw['segments']:
        start, end = s['start_seconds'], s['end_seconds']
        if not isinstance(s.get('text'), str) or not math.isfinite(start+end) or not 0 <= start <= end <= seconds+2 or start < previous:
            raise ValueError('离线转写时间轴未通过核验。')
        previous = start

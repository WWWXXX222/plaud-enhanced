"""OpenAI original-language text plus a separately attributed listening timeline.

Credentials arrive only on the native app's private stdin pipe. Reference
scripts, named speaker samples and user notes are never used as ASR prompts.
"""
import json
import math
import os
from pathlib import Path
import secrets
import re
import subprocess
import sys
import time
import ssl
import socket
from concurrent.futures import ThreadPoolExecutor
from urllib import request, error

import backend as b
from speech_segmentation import CHUNK_SECONDS, POLICY, plan_ranges, join_primary, annotate_speakers

ENDPOINT = 'https://api.openai.com/v1/audio/transcriptions'
PRIMARY = 'gpt-transcribe'
TIMELINE = 'gpt-4o-transcribe-diarize'
REFERENCE_SECONDS = 150
MAX_REQUEST_FAILURES = 6
REQUEST_COOLDOWN_SECONDS = 900


class RetryableTranscriptionError(ValueError):
    def __init__(self, message, shrinkable=False):
        super().__init__(message)
        self.shrinkable = shrinkable


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def audio_request(audio, model, fields, key):
    if not 0 < audio.stat().st_size < 25 * 1024 * 1024:
        raise ValueError('OpenAI 单段音频须小于 25 MB；原始录音已保留。')
    boundary = 'OwnPlaud' + secrets.token_hex(20)
    body = []
    for name, value in [('model', model), *fields]:
        body.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    mime = 'audio/mp4' if audio.suffix.lower() in ('.m4a', '.mp4') else 'audio/mpeg'
    body.extend([f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio{audio.suffix}"\r\nContent-Type: {mime}\r\n\r\n'.encode(), audio.read_bytes(), f'\r\n--{boundary}--\r\n'.encode()])
    req = request.Request(ENDPOINT, b''.join(body), headers={
        'Authorization': 'Bearer ' + key, 'Content-Type': 'multipart/form-data; boundary=' + boundary}, method='POST')
    try:
        # Follow the user's configured network route. Forcing a direct connection
        # can time out before reaching OpenAI while the system proxy is healthy.
        opener = request.build_opener(request.ProxyHandler(), NoRedirect())
        with opener.open(req, timeout=180) as response:
            raw = json.loads(response.read(8 * 1024 * 1024))
            receipt = {'http_status': response.status, 'request_id': response.headers.get('x-request-id')}
        if not isinstance(raw, dict) or not isinstance(raw.get('text'), str):
            raise RetryableTranscriptionError('OpenAI 响应不完整，正在自动恢复。')
        return raw, receipt
    except error.HTTPError as exc:
        # Error messages may echo an invalid key. Keep only known safe codes.
        code = None
        try:
            code = json.loads(exc.read(65536)).get('error', {}).get('code')
        except Exception:
            pass
        if exc.code == 401: raise ValueError('OpenAI 密钥无效，请在设置里更新。') from None
        if code == 'insufficient_quota': raise ValueError('OpenAI API 额度不足，请检查账户后重试。') from None
        if exc.code == 429: raise RetryableTranscriptionError('OpenAI 暂时限流，将自动重试。') from None
        if exc.code in (403, 404): raise ValueError('当前 OpenAI API 项目无法使用所选语音模型。') from None
        kind = RetryableTranscriptionError if exc.code in (408, 409) or exc.code >= 500 else ValueError
        raise kind(f'OpenAI 请求未完成（HTTP {exc.code}），录音已保留。') from None
    except json.JSONDecodeError:
        raise RetryableTranscriptionError('OpenAI 响应中断，正在自动恢复。') from None
    except ValueError:
        raise
    except Exception as exc:
        reason = exc.reason if isinstance(exc, error.URLError) else exc
        if isinstance(reason, ssl.SSLCertVerificationError):
            raise ValueError('OpenAI 安全连接证书校验失败，录音已保留。') from None
        if isinstance(reason, (TimeoutError, socket.timeout)):
            message = 'OpenAI 请求超过 180 秒未完成，将自动重试。'
        else:
            message = 'OpenAI 网络连接暂未成功，将自动重试。'
        failure = RetryableTranscriptionError(message, shrinkable=isinstance(reason, (TimeoutError, socket.timeout)))
        # A type name is safe diagnostic evidence; raw network exceptions may
        # contain URLs, headers or credentials and must never be persisted.
        failure.transport_error_type = type(reason).__name__
        raise failure from None


def verify_no_speech(part, folder):
    """An empty API response alone is not evidence of silence. Fail closed.

    Run the existing local Silero VAD with a conservative speech threshold;
    retain both its log and original JSON. Never insert local ASR into OpenAI text.
    """
    token = b.digest(part)
    base = folder / ('vad-' + token)
    check = base.with_suffix('.check.json')
    model = b.ROOT/'models/ggml-silero-v6.2.0.bin'
    model_hash = b.digest(model)
    if check.exists():
        prior = b.read(check)
        if prior.get('audio_sha256') == token and prior.get('model_sha256') == model_hash and all(
                b.digest(b.local_file(folder, rel)) == sha for rel, sha in prior.get('sha256', {}).items()):
            return prior
        raise ValueError('无语音核验证据不一致，原录音已保留。')
    wav = base.with_suffix('.wav')
    r = subprocess.run([str(b.FFMPEG), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-i', str(part), '-ar', '16000', '-ac', '1', str(wav)], capture_output=True, timeout=120)
    if r.returncode: raise RetryableTranscriptionError('正在重新准备空段的语音核验。')
    log = base.with_suffix('.log')
    command = [str(b.ROOT/'vendor/whisper.cpp/build/bin/whisper-cli'), '-m', str(b.ROOT/'models/ggml-small-q5_1.bin'),
               '-f', str(wav), '--vad', '-vm', str(model), '-vt', '0.3', '-vspd', '100', '-oj', '-of', str(base), '-ng', '-t', '4', '-l', 'auto']
    with log.open('wb') as out:
        r = subprocess.run(command, stdout=out, stderr=out, timeout=300)
    raw = base.with_suffix('.json')
    matches = re.findall(r'Final speech segments after filtering: (\d+)', log.read_text(errors='replace'))
    if r.returncode or not raw.exists() or len(matches) != 1:
        raise RetryableTranscriptionError('空段的自动语音核验暂未完成，将自动恢复。')
    no_speech = int(matches[0]) == 0 and not b.read(raw).get('transcription')
    files = [wav, log, raw]
    result = dict(audio_sha256=token, model_sha256=model_hash, detector='whisper.cpp / Silero VAD 6.2.0',
                  threshold=0.3, min_speech_ms=100, no_speech_detected=no_speech, created_at=b.stamp(),
                  sha256={p.name:b.digest(p) for p in files},
                  evidence_files=[str(p.relative_to(folder.parent.parent)) for p in [*files,check]])
    b.atomic(check, result)
    return result


def request_with_recovery(directory, part, model, fields, key, caller, folder, offset, span, index, multi):
    fingerprint = dict(model=model, audio_sha256=b.digest(part), parameters=[list(x) for x in fields])
    budget_path = folder / ('attempts-' + model + '-' + fingerprint['audio_sha256'] + '.json')
    budget = b.read(budget_path) if budget_path.exists() else dict(fingerprint, failures=0)
    if any(budget.get(k) != v for k, v in fingerprint.items()):
        raise ValueError('转写恢复记录与音频不一致，已暂停。')
    for attempt in range(3):
        if budget['failures'] >= MAX_REQUEST_FAILURES:
            if not budget.get('retry_at'):
                budget['retry_at'] = time.time() + min(3600, REQUEST_COOLDOWN_SECONDS * 2**min(budget.get('cooldown_cycles',0),2))
                b.atomic(budget_path,budget)
            if time.time() < budget['retry_at']:
                raise RetryableTranscriptionError(f'第 {index+1} 段暂时无法完成，正在冷却等待自动重试；录音与成功片段已保存。')
            budget.update(failures=0, retry_at=0, cooldown_cycles=budget.get('cooldown_cycles',0)+1)
            b.atomic(budget_path,budget)
        raw = None; receipt = {}
        started = time.monotonic()
        try:
            raw, receipt = caller(part, model, fields, key)
            if not isinstance(raw, dict) or not isinstance(raw.get('text'), str):
                raise RetryableTranscriptionError('OpenAI 响应不完整。')
            empty_check = None
            if not raw['text'].strip():
                b.report(directory, 'processing', '正在自动核验无文字片段，已有转写已保存。', .9)
                empty_check = verify_no_speech(part, folder)
                if not empty_check['no_speech_detected']:
                    if model == PRIMARY:
                        if span > 45:
                            raise RetryableTranscriptionError('正文为空且无法排除语音，正在缩短片段重新识别。', shrinkable=True)
                        receipt = dict(receipt, transcription_issue='empty_primary_with_possible_speech')
                    # An auxiliary diarization failure must not veto successful
                    # primary text. Retain the empty response, VAD and audio as
                    # an explicitly unresolved interval, never as silence.
                    else:
                        receipt = dict(receipt, reference_issue='empty_reference_with_possible_speech')
            elif model == TIMELINE:
                try: reference_segments(raw, offset, span, index, multi)
                except ValueError as exc: raise RetryableTranscriptionError(str(exc), shrinkable=True) from None
            b.atomic(budget_path, dict(fingerprint, failures=0))
            return raw, receipt, empty_check
        except (RetryableTranscriptionError, TimeoutError, ConnectionError, subprocess.TimeoutExpired) as exc:
            reason = str(exc) if isinstance(exc, RetryableTranscriptionError) else '请求超时或连接暂未成功。'
            shrinkable = getattr(exc, 'shrinkable', False) or isinstance(exc, (TimeoutError, subprocess.TimeoutExpired))
            failure = dict(model=model, part=index+1, offset_seconds=offset, span_seconds=span,
                           attempt=attempt+1, reason=reason, exception_type=type(exc).__name__,
                           audio_sha256=b.digest(part), parameters=[list(x) for x in fields],
                           elapsed_seconds=round(time.monotonic()-started,3), created_at=b.stamp())
            if getattr(exc, 'transport_error_type', None):
                failure['transport_error_type'] = exc.transport_error_type
            if raw is not None:
                evidence = folder/'rejected'/f'{index:04d}-{model}-{time.time_ns()}.json'
                b.atomic(evidence, dict(response=raw, receipt=receipt, failure=failure))
                failure['response_evidence'] = str(evidence.relative_to(directory))
                failure['response_sha256'] = b.digest(evidence)
            b.atomic(directory/'transcription-failure.json', failure)
            budget['failures'] += 1
            if budget['failures'] >= MAX_REQUEST_FAILURES:
                budget['retry_at'] = time.time() + min(3600, REQUEST_COOLDOWN_SECONDS * 2**min(budget.get('cooldown_cycles',0),2))
            b.atomic(budget_path, dict(budget, last_failure=failure))
            if model == PRIMARY and raw is not None and not raw.get('text','').strip() and shrinkable:
                # Repeating the same empty long window cannot resolve the VAD
                # disagreement. Preserve it, then retry smaller overlapping audio.
                raise RetryableTranscriptionError(reason, shrinkable=True) from None
            stage = '正文' if model == PRIMARY else '回听时间参考'
            if attempt == 2:
                raise RetryableTranscriptionError(f'第 {index+1} 段{stage}：{reason} 已保存进度，将自动续跑。', shrinkable=shrinkable) from None
            b.report(directory, 'retry_wait', f'第 {index+1} 段{stage}：{reason} 正在自动重试（{attempt+1}/2）。', .85, retryable=True)
            time.sleep((2, 8)[attempt])


def prepare_parts(directory, m):
    # The short import fixture is sent byte-for-byte, as in the comparison.
    files = m.get('audio_files', [])
    original = b.local_file(directory, files[0]) if len(files) == 1 else None
    audio = original if original and original.suffix.lower() in ('.m4a', '.mp4', '.mp3') else b.local_file(directory, 'plaud-upload.mp3')
    length = b.duration(audio)
    if not 3 <= length <= 5 * 3600: raise ValueError('OpenAI 模式支持 3 秒至 5 小时录音。')
    fingerprint = b.digest(audio)
    # Version the cache: old 60-second fragments must not silently survive a
    # segmentation fix, and interrupted older results remain preserved.
    folder = directory / 'openai' / (fingerprint + '-' + POLICY)
    folder.mkdir(parents=True, exist_ok=True)
    if length <= CHUNK_SECONDS and audio.stat().st_size < 25 * 1024 * 1024:
        return audio, length, folder, [(audio, 0.0, length)]
    plan_path = folder / 'chunk-plan.json'
    if plan_path.exists():
        plan = b.read(plan_path)
        if plan.get('audio_sha256') != fingerprint or plan.get('policy') != POLICY:
            raise ValueError('音频分段计划与原件不一致。')
        ranges = plan['ranges']
    else:
        detection = subprocess.run([str(b.FFMPEG), '-nostdin', '-hide_banner', '-i', str(audio),
            '-af', 'silencedetect=noise=-40dB:d=0.4', '-f', 'null', '-'], capture_output=True, text=True, timeout=max(180, length))
        if detection.returncode: raise RetryableTranscriptionError('正在恢复音频停顿检测。')
        starts, silences = [], []
        for kind, number in re.findall(r'silence_(start|end): ([0-9.]+)', detection.stderr):
            if kind == 'start': starts.append(float(number))
            elif starts: silences.append((starts.pop(), min(float(number), length)))
        if starts: silences.append((starts[-1], length))
        ranges = plan_ranges(length, silences)
        b.atomic(plan_path, dict(policy=POLICY, audio_sha256=fingerprint, duration=length,
                                ranges=ranges, silences=silences, threshold_db=-40, min_silence_seconds=.4))
    parts = []
    for index, (start, end) in enumerate(ranges):
        span = end - start
        if span < .01: continue
        target = folder / f'audio-{index:04d}.mp3'
        if not target.exists():
            tmp = target.with_suffix('.partial.mp3')
            result = subprocess.run([str(b.FFMPEG), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                '-i', str(audio), '-ss', str(start), '-t', str(span), '-ar', '24000', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '96k', str(tmp)], capture_output=True, timeout=180)
            if result.returncode: raise ValueError('音频分段失败，原录音仍在本机。')
            if abs(b.duration(tmp) - span) > .3: raise ValueError('音频分段长度校验未通过。')
            os.replace(tmp, target); target.chmod(0o600)
        if abs(b.duration(target) - span) > .3: raise ValueError('缓存音频分段长度不匹配。')
        parts.append((target, float(start), span))
    return audio, length, folder, parts


def reference_segments(raw, offset, span, part_index, multi):
    result = []
    previous_start = None
    for s in raw.get('segments', []):
        start, end, text = s.get('start'), s.get('end'), s.get('text')
        if (not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in (start, end))
                or not 0 <= start <= end <= span + .3 or start > span or not isinstance(text, str)):
            raise ValueError('OpenAI 返回了无效或超出音频范围的时间标记。')
        label = str(s.get('speaker') or '?')
        if len(label) > 80: raise ValueError('OpenAI 说话人标签异常。')
        # Compare provider coordinates before display rounding. Equal starts are
        # valid overlapping speech; a fractional offset must not reverse them.
        if previous_start is not None and start < previous_start: raise ValueError('OpenAI 时间参考顺序异常。')
        previous_start = start
        result.append({'start_seconds': round(start + offset, 3), 'end_seconds': round(min(end, span) + offset, 3),
            'speaker': f'说话人 {label}（待确认）' if not multi else f'第 {part_index + 1} 段 · 说话人 {label}（待确认）',
            'raw_speaker': label, 'part_index': part_index, 'speaker_status': 'unconfirmed', 'text': text.strip(), 'role': 'independent_listening_reference',
            'timestamp_status': 'point_duration_unknown' if start == end else 'estimated_interval'})
    if not result: raise ValueError('OpenAI 未返回时间参考，正文已保留，请继续处理。')
    return result


def load_response(directory, part, model, fields, key, caller, folder, offset, span, index, multi, name, cached_only=False):
    """Reuse verified raw evidence, including responses rejected by old validation."""
    fingerprint = dict(model=model, audio_sha256=b.digest(part), parameters=[list(x) for x in fields])
    raw_path, meta_path = folder/(name+'.raw.json'), folder/(name+'.request.json')
    evidence = [str(p.relative_to(directory)) for p in (raw_path, meta_path)]
    if raw_path.exists() and meta_path.exists():
        meta = b.read(meta_path)
        if (any(meta.get(k) != v for k, v in fingerprint.items()) or meta.get('raw_sha256') != b.digest(raw_path)
                or meta.get('offset_seconds') != offset or meta.get('span_seconds') != span):
            raise ValueError('OpenAI 缓存证据不一致，已暂停；原始结果已保留。')
        return b.read(raw_path), dict(meta, audio_file=str(part.relative_to(directory))), evidence
    recovered = None
    if model == TIMELINE:
        for path in sorted((folder/'rejected').glob(f'{index:04d}-{model}-*.json'), reverse=True):
            prior = b.read(path)
            failure, receipt, raw = prior.get('failure', {}), prior.get('receipt', {}), prior.get('response', {})
            if (any(failure.get(k) != v for k, v in fingerprint.items()) or receipt.get('http_status') != 200
                    or failure.get('offset_seconds') != offset or failure.get('span_seconds') != span
                    or not isinstance(raw, dict) or not isinstance(raw.get('text'), str)):
                continue
            empty_check = None
            if raw['text'].strip():
                try: reference_segments(raw, offset, span, index, multi)
                except ValueError: continue
            else:
                # A previous split may already contain useful child results.
                # Do not replace them with their parent's earlier empty result.
                if (folder/(name+'.split.json')).exists(): continue
                empty_check = verify_no_speech(part, folder)
                if not empty_check['no_speech_detected']:
                    receipt = dict(receipt, reference_issue='empty_reference_with_possible_speech')
            recovered = dict(recovered_from=str(path.relative_to(directory)), recovered_from_sha256=b.digest(path))
            break
    if recovered is None:
        if cached_only: return None
        started = time.monotonic()
        raw, receipt, empty_check = request_with_recovery(directory, part, model, fields, key, caller, folder, offset, span, index, multi)
        elapsed = round(time.monotonic()-started, 3)
    else:
        elapsed = 0
    b.atomic(raw_path, raw)
    meta = dict(fingerprint, **receipt, endpoint=ENDPOINT, created_at=b.stamp(), elapsed_seconds=elapsed,
                offset_seconds=offset, span_seconds=span, reference_prompt_supplied=False,
                raw_sha256=b.digest(raw_path), audio_file=str(part.relative_to(directory)),
                empty_audio_check=empty_check, **(recovered or {}))
    b.atomic(meta_path, meta)
    return raw, meta, evidence


def slice_reference_audio(part, target, start, span):
    if not target.exists():
        tmp = target.with_suffix('.partial.mp3')
        command = [str(b.FFMPEG), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
            '-i', str(part), '-ss', str(start), '-t', str(span), '-ar', '24000', '-ac', '1',
            '-c:a', 'libmp3lame', '-b:a', '96k', str(tmp)]
        result = subprocess.run(command, capture_output=True, timeout=180)
        if result.returncode and b'inadequate AVFrame plane padding' in result.stderr:
            # Some bundled FFmpeg builds reject the final planar-float frame.
            # Converting to s16p allocates a correctly padded encoder buffer;
            # preserve the same range, existing completed slices and identities.
            result = subprocess.run(command[:-1]+['-sample_fmt', 's16p', command[-1]], capture_output=True, timeout=180)
        if result.returncode:
            b.atomic(target.with_suffix('.slice-error.json'), dict(returncode=result.returncode,
                message=result.stderr.decode('utf-8', errors='replace')[-2000:], start=start, span=span))
            raise RetryableTranscriptionError('本机音频切片暂未完成，已保留诊断与成功片段。')
        if abs(b.duration(tmp)-span) > .3: raise ValueError('回听参考分段长度不一致。')
        os.replace(tmp, target); target.chmod(0o600)
    if abs(b.duration(target)-span) > .3: raise ValueError('缓存回听参考分段长度不一致。')


def timeline_responses(directory, part, fields, key, caller, folder, offset, span, index, multi, name=None, depth=0):
    """Bound reference latency without changing primary text or its existing cache.

    Every child keeps absolute coordinates and its own speaker namespace. Saved
    split plans prevent restarts from trying the failed larger request again.
    """
    name = name or f'{index:04d}-{TIMELINE}'
    saved = load_response(directory, part, TIMELINE, fields, key, caller, folder, offset, span, index, multi, name, cached_only=True)
    if saved is not None: return [saved]
    plan_path = folder/(name+'.split.json')
    if not plan_path.exists() and span <= REFERENCE_SECONDS:
        b.report(directory, 'processing', f'第 {index+1} 段 · 生成 {b.timestamp(offset)}–{b.timestamp(offset+span)} 回听参考', .85)
        try:
            return [load_response(directory, part, TIMELINE, fields, key, caller, folder, offset, span, index, multi, name)]
        except RetryableTranscriptionError as exc:
            if span <= 45 or not exc.shrinkable: raise
            # A failed small request gets smaller, instead of endlessly replaying
            # the same geometry. Completed siblings remain reusable.
    fingerprint = dict(audio_sha256=b.digest(part), offset_seconds=offset, span_seconds=span)
    if plan_path.exists():
        plan = b.read(plan_path)
        if any(plan.get(k) != v for k, v in fingerprint.items()):
            raise ValueError('回听参考恢复计划与音频不一致。')
    else:
        count = max(2, math.ceil(span/REFERENCE_SECONDS))
        # The endpoints are the original geometry. Recomputing span*count/count
        # can differ by one floating-point ULP and falsely report missing audio.
        boundaries = [0.0, *[span*n/count for n in range(1, count)], span]
        plan = dict(fingerprint, policy='bounded-reference-v1', ranges=list(zip(boundaries, boundaries[1:])))
        b.atomic(plan_path, plan)
    cursor = 0.0
    for start, end in plan['ranges']:
        if not (math.isfinite(start) and math.isfinite(end) and start == cursor and 0 < end-start < span):
            raise ValueError('回听参考恢复计划存在缺口或无效分段。')
        cursor = end
    # Older persisted plans may have that one-ULP endpoint. Keep their exact
    # child geometry/cache identities; tolerate arithmetic rounding only.
    if not math.isclose(cursor, span, rel_tol=0, abs_tol=4*max(math.ulp(cursor), math.ulp(span))):
        raise ValueError('回听参考恢复计划未覆盖完整音频。')
    def run_child(item):
        n, (start, end) = item
        child_name = name+f'-ref{n:02d}'
        child = folder/(child_name+'.mp3')
        slice_reference_audio(part, child, start, end-start)
        results = timeline_responses(directory, child, fields, key, caller, folder, offset+start, end-start,
                                     index, True, child_name, depth+1)
        for _, _, evidence in results:
            evidence.extend([str(plan_path.relative_to(directory)), str(child.relative_to(directory))])
        return results
    items = list(enumerate(plan['ranges']))
    # At most two provider requests per meeting, even during recursive recovery.
    if depth == 0:
        with ThreadPoolExecutor(max_workers=2) as pool:
            batches = list(pool.map(run_child, items))
    else:
        batches = [run_child(item) for item in items]
    return [result for batch in batches for result in batch]


def primary_responses(directory, part, fields, key, caller, folder, offset, span, index, multi, name=None):
    """Recover empty primary windows without deleting words or assuming silence.

    Split only failed windows. Twenty-second overlaps protect negation and other
    boundary phrases; ambiguous joins remain marked by join_primary. At <=45 s,
    an empty response plus possible VAD speech is an explicit unresolved gap.
    """
    name = name or f'{index:04d}-{PRIMARY}'
    saved = load_response(directory, part, PRIMARY, fields, key, caller, folder, offset, span, index, multi, name, cached_only=True)
    if saved is not None: return [saved]
    plan_path = folder/(name+'.split.json')
    fingerprint = dict(model=PRIMARY, audio_sha256=b.digest(part), parameters=[list(x) for x in fields])
    prior_empty = False
    if span > 45:
        for path in (folder/'rejected').glob(f'{index:04d}-{PRIMARY}-*.json'):
            prior = b.read(path); failure = prior.get('failure',{}); raw = prior.get('response',{})
            if (all(failure.get(k)==v for k,v in fingerprint.items()) and prior.get('receipt',{}).get('http_status')==200
                    and failure.get('offset_seconds')==offset and failure.get('span_seconds')==span
                    and isinstance(raw.get('text'),str) and not raw['text'].strip()):
                prior_empty = True; break
    if not plan_path.exists() and not prior_empty:
        try:
            return [load_response(directory, part, PRIMARY, fields, key, caller, folder, offset, span, index, multi, name)]
        except RetryableTranscriptionError as exc:
            if span <= 45 or not exc.shrinkable: raise
    geometry = dict(audio_sha256=fingerprint['audio_sha256'], offset_seconds=offset, span_seconds=span)
    if plan_path.exists():
        plan = b.read(plan_path)
        if any(plan.get(k)!=v for k,v in geometry.items()): raise ValueError('正文恢复计划与音频不一致。')
    else:
        count = max(2, math.ceil(span/150))
        ranges = [(max(0,span*n/count-10),min(span,span*(n+1)/count+10)) for n in range(count)]
        plan = dict(geometry,policy='overlapping-primary-recovery-v1',ranges=ranges)
        b.atomic(plan_path,plan)
    cursor = 0.0
    for start,end in plan['ranges']:
        if not (math.isfinite(start) and math.isfinite(end) and 0 <= start <= cursor < end <= span and end-start < span):
            raise ValueError('正文恢复计划存在缺口或无效分段。')
        cursor = end
    if cursor != span: raise ValueError('正文恢复计划未覆盖完整音频。')
    results = []
    for n,(start,end) in enumerate(plan['ranges']):
        child_name = name+f'-text{n:02d}'
        child = folder/(child_name+'.mp3')
        slice_reference_audio(part,child,start,end-start)
        b.report(directory,'processing',f'第 {index+1} 段 · 重新识别 {b.timestamp(offset+start)}–{b.timestamp(offset+end)} 原文',.85)
        children = primary_responses(directory,child,fields,key,caller,folder,offset+start,end-start,index,True,child_name)
        for _,meta,files in children:
            files.extend([str(plan_path.relative_to(directory)),str(child.relative_to(directory))])
            meta.setdefault('recovery_issue','primary_recovered_after_failed_window')
            meta.setdefault('recovery_parent_sha256',fingerprint['audio_sha256'])
        results.extend(children)
    return results


def transcribe(directory, key, caller=audio_request):
    directory, m = b.meeting(directory)
    if m.get('transcription_engine') != 'openai' or m.get('capture_state') != 'captured':
        raise ValueError('请先选择 OpenAI 并结束录音。')
    if (directory / 'submission.json').exists(): raise ValueError('已经提交的会议不可重新转写。')
    if m.get('cloud_upload') and not m.get('plaud_file_id'): raise ValueError('请先完成 Plaud 录音上传。')
    if not m.get('cloud_upload') and not (directory/'plaud-upload.mp3').exists():
        from prepare_upload import prepare
        prepare(directory)
    with b.lock(directory / '.processing.lock', True):
        audio, length, folder, parts = prepare_parts(directory, m)
        primary_texts, timeline, records, evidence, coverage = [], [], [], [], []
        languages = ['en', 'zh'] if m.get('language') == 'en' else ['zh', 'en']
        def unresolved(meta, files, index, primary=False):
            start, end = meta['offset_seconds'], meta['offset_seconds']+meta['span_seconds']
            message = (f'【系统标注：{b.timestamp(start)}–{b.timestamp(end)} 原文未能识别，不能确认是否有发言；音频与模型响应已保留，此处不是会议原话。】' if primary else
                       '【系统标注：此区间的辅助时间参考未识别出文字，不能据此认定无语音。请以正式正文为准，必要时回听原音频。】')
            issue_key = 'transcription_issue' if primary else 'reference_issue'
            timeline.append(dict(start_seconds=round(start,3),end_seconds=round(end,3),speaker='说话人待确认',
                raw_speaker='?',part_index=index,speaker_scope=files[0],speaker_status='unconfirmed',text=message,
                role='unresolved_primary_transcription' if primary else 'unresolved_listening_reference',
                timestamp_status='audio_window_only',**{issue_key:'empty_primary_with_possible_speech' if primary else 'empty_reference_with_possible_speech'}))
            if primary: primary_texts.append(dict(text=message,start=start,end=end))

        for index, (part, offset, span) in enumerate(parts):
            fields = [('response_format','json'), *[('languages[]',x) for x in languages]]
            b.report(directory,'processing',f'OpenAI 正在处理 {index+1}/{len(parts)} 段 · 保留中英原文',.85)
            primaries = primary_responses(directory,part,fields,key,caller,folder,offset,span,index,len(parts)>1)
            for raw,meta,files in primaries:
                primary_part = b.local_file(directory,meta['audio_file'])
                start, duration = meta['offset_seconds'], meta['span_seconds']
                evidence.extend(files); records.append(meta)
                if not raw['text'].strip():
                    verified = verify_no_speech(primary_part,folder)
                    evidence.extend(verified['evidence_files'])
                    status = 'no_speech_detected' if verified['no_speech_detected'] else 'unresolved_primary'
                    if not verified['no_speech_detected']:
                        if duration > 45: raise RetryableTranscriptionError('空正文片段仍需缩短后核验。',shrinkable=True)
                        unresolved(meta,files,index,primary=True)
                    coverage.append(dict(start_seconds=start,end_seconds=round(start+duration,3),status=status,audio_sha256=b.digest(primary_part)))
                    continue
                primary_texts.append(dict(text=raw['text'],start=start,end=start+duration))
                if meta.get('recovery_issue'):
                    timeline.append(dict(start_seconds=round(start,3),end_seconds=round(start+duration,3),
                        speaker='说话人待确认',raw_speaker='?',part_index=index,speaker_scope=files[0],speaker_status='unconfirmed',
                        text='【系统标注：此区间的正文来自失败长段的补识别，存在模型分歧，需核对原音频，不能单独作为会议事实或决定依据。】',
                        role='primary_recovery_review',timestamp_status='audio_window_only',
                        transcription_review_issue=meta['recovery_issue']))
                coverage.append(dict(start_seconds=start,end_seconds=round(start+duration,3),status='transcribed',audio_sha256=b.digest(primary_part)))
                b.report(directory,'processing',f'OpenAI 正在处理 {index+1}/{len(parts)} 段 · 生成回听时间参考',.85)
                name = Path(files[0]).name.removesuffix('.raw.json').replace(PRIMARY,TIMELINE)
                references = timeline_responses(directory,primary_part,[('response_format','diarized_json'),('chunking_strategy','auto')],
                    key,caller,folder,start,duration,index,len(parts)>1 or len(primaries)>1,name=name)
                for ref,info,proof in references:
                    evidence.extend(proof); records.append(info)
                    if not ref['text'].strip():
                        verified = verify_no_speech(b.local_file(directory,info['audio_file']),folder)
                        evidence.extend(verified['evidence_files'])
                        if not verified['no_speech_detected']: unresolved(info,proof,index)
                    else:
                        segments = reference_segments(ref,info['offset_seconds'],info['span_seconds'],index,
                                                      len(parts)>1 or len(primaries)>1 or len(references)>1)
                        for segment in segments:
                            segment['speaker_scope'] = proof[0]
                            if len(primaries)>1 or len(references)>1:
                                segment['speaker'] = f'第 {index+1} 段 · {b.timestamp(info["offset_seconds"])} 起 · 说话人 {segment["raw_speaker"]}（待确认）'
                        timeline.extend(segments)
            if part.parent == folder: evidence.append(str(part.relative_to(directory)))
        if b.read(directory/'meeting.json').get('transcription_engine') != 'openai': raise ValueError('转写方式已改变，请继续所选方式。')
        text, joins = join_primary(primary_texts)
        timeline = annotate_speakers(timeline)
        reference_gaps, transcription_gaps, transcription_review_windows = [], [], []
        for segment in timeline:
            if segment.get('reference_issue'):
                segment['speaker_issues'].append(segment['reference_issue'])
                reference_gaps.append({k:segment[k] for k in ('start_seconds','end_seconds','reference_issue','speaker_scope')})
            if segment.get('transcription_issue'):
                segment['speaker_issues'].append(segment['transcription_issue'])
                transcription_gaps.append({k:segment[k] for k in ('start_seconds','end_seconds','transcription_issue','speaker_scope')})
            if segment.get('transcription_review_issue'):
                segment['speaker_issues'].append(segment['transcription_review_issue'])
                transcription_review_windows.append({k:segment[k] for k in ('start_seconds','end_seconds','transcription_review_issue','speaker_scope')})
        system_annotations = []
        if transcription_review_windows:
            ranges = '、'.join(f'{b.timestamp(w["start_seconds"])}–{b.timestamp(w["end_seconds"])}' for w in transcription_review_windows)
            system_annotations.append(f'【系统标注：{ranges} 的正文来自失败长段的补识别，尚待核对；不能据此确认会议事实或决定。下方保留模型原字词，原音频与响应均已保存。】')
            text = '\n'.join(system_annotations)+'\n\n'+text
        if (folder/'chunk-plan.json').exists(): evidence.append(str((folder/'chunk-plan.json').relative_to(directory)))
        normalized = {'source':'OpenAI', 'engine':PRIMARY, 'timeline_engine':TIMELINE, 'text':text, 'duration':length,
                      'segments':timeline, 'speaker_identification':False, 'speaker_status':'unconfirmed',
                      'timestamp_role':'independent_listening_reference_not_alignment_of_primary_text',
                      'precision':'model estimated; primary text has no word timestamps', 'chunk_seconds':CHUNK_SECONDS,
                      'chunking_policy':POLICY, 'text_joins':joins, 'reference_gaps':reference_gaps,
                      'transcription_gaps':transcription_gaps, 'transcription_review_windows':transcription_review_windows,
                      'primary_text_complete':not (transcription_gaps or transcription_review_windows), 'system_annotations':system_annotations,
                      'quality_warnings':list(dict.fromkeys(issue for s in timeline for issue in s['speaker_issues']))}
        normalized['coverage'] = coverage
        b.atomic(directory/'transcript.txt', text+'\n')
        b.atomic(directory/'transcript.json', normalized)
        lines=['# 回听时间参考（独立转写，不是正文的精确对齐）', '',
               '正式正文见 transcript.txt。下列文字来自另一模型，可能与正文不同；所有说话人待确认，不能据标签确认人数或身份。', '']
        for s in timeline:
            marker = (b.timestamp(s['start_seconds']) + ' · 单点参考，时长未确定') if s.get('timestamp_status') == 'point_duration_unknown' else f'{b.timestamp(s["start_seconds"])}–{b.timestamp(s["end_seconds"])}'
            lines.append(f'[{marker}] {s["speaker"]}：{s["text"]}')
        for c in coverage:
            if c['status'] == 'no_speech_detected': lines.append(f'[{b.timestamp(c["start_seconds"])}–{b.timestamp(c["end_seconds"])}] OpenAI 未返回文字；本机 Silero VAD 未检出语音。原音频与核验证据均保留，此标注不是会议原文。')
        b.atomic(directory/'transcript-timeline.md', '\n\n'.join(lines)+'\n')
        # Failed-but-retained provider responses are source evidence, not accepted text.
        evidence.extend(str(p.relative_to(directory)) for p in sorted((folder/'rejected').glob('*.json')))
        b.atomic(directory/'openai-result.json', {'version':1, 'source_audio':str(audio.relative_to(directory)), 'audio_sha256':b.digest(audio),
            'duration':length, 'primary_model':PRIMARY, 'timeline_model':TIMELINE, 'speaker_status':'unconfirmed',
            'evidence_files':list(dict.fromkeys(evidence)), 'coverage':coverage, 'requests':records, 'transcript_sha256':b.digest(directory/'transcript.txt'),
            'normalized_sha256':b.digest(directory/'transcript.json'), 'timeline_sha256':b.digest(directory/'transcript-timeline.md')})
        b.report(directory, 'openai_ready', 'OpenAI 原文与回听参考已就绪，正在检查归档资料。', .98)
        return normalized


def main():
    os.umask(0o077)
    directory = None
    try:
        if len(sys.argv) != 2: return 2
        directory, _ = b.meeting(sys.argv[1])
        if not directory.is_relative_to((b.ROOT/'data/meetings').resolve()): return 2
        key = sys.stdin.buffer.read(4097).decode().strip()
        if not key.startswith('sk-') or not 20 <= len(key) <= 1024 or any(c.isspace() for c in key): raise ValueError('请在设置中保存有效的 OpenAI API Key。')
        try: transcribe(directory, key)
        finally: key = None
        return 0
    except Exception as exc:
        if directory:
            retryable = isinstance(exc, (RetryableTranscriptionError, TimeoutError, ConnectionError, BlockingIOError, subprocess.TimeoutExpired))
            if not b.read(directory/'meeting.json').get('cloud_upload'):
                retry_path = directory/'local-retry.json'
                prior = b.read(retry_path) if retry_path.exists() else {}
                attempts = prior.get('attempts', 0)+1
                b.atomic(retry_path, dict(attempts=attempts, retry_at=time.time()+min(3600,30*2**min(attempts,7))))
            b.report(directory, 'retry_wait' if retryable else 'error', str(exc) if isinstance(exc, ValueError) else 'OpenAI 转写暂未完成，录音与已完成结果均保留。', retryable=retryable)
        return 1


if __name__ == '__main__':
    # Native owner can stop this worker and encoder children as one owned group.
    if os.getpgrp() != os.getpid(): os.setsid()
    raise SystemExit(main())

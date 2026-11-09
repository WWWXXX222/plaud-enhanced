#!/usr/bin/env python3
"""One-shot local comparison of the unchanged, user-authorized synthetic fixture.

The API key stays in this process for the two requests only. No credentials,
authorization headers, or provider error messages are written to disk or logs.
This runner deliberately never loads the reference transcript.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import threading
import sys
import time
from datetime import datetime, timezone
from urllib import request, error

ROOT = Path(__file__).resolve().parents[1]
AUDIO = ROOT / 'fixtures/中英混合三人测试.m4a'
EXPECTED_SHA = '78bbfb8221c84f9878ac34032d1260d951b4b1ba4dc86e5e4b7775e7b77318c0'
OUTPUT = ROOT / 'evidence/openai-comparison-2026-10-18'
LOCK = threading.Lock()
STATE = {'phase': 'ready', 'message': '等待在本机输入 API Key', 'results': []}
MODELS = (
    ('gpt-4o-transcribe-diarize', [('response_format', 'diarized_json'), ('chunking_strategy', 'auto')]),
    ('gpt-transcribe', [('response_format', 'json'), ('languages[]', 'zh'), ('languages[]', 'en')]),
)


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
    os.replace(temporary, path)


def multipart(model, fields, audio):
    boundary = 'OwnPlaud' + secrets.token_hex(18)
    chunks = []
    for name, value in [('model', model), *fields]:
        chunks.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    chunks += [f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="mixed-speakers.m4a"\r\nContent-Type: audio/mp4\r\n\r\n'.encode(), audio, f'\r\n--{boundary}--\r\n'.encode()]
    return b''.join(chunks), boundary


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def run_comparison(api_key):
    results = []
    try:
        audio = AUDIO.read_bytes()
        if hashlib.sha256(audio).hexdigest() != EXPECTED_SHA:
            raise ValueError('Fixture changed')
        opener = request.build_opener(request.ProxyHandler({}), NoRedirect())
        for model, fields in MODELS:
            existing = OUTPUT / f'{model}.raw.json'
            if existing.exists():
                previous = json.loads((OUTPUT / f'{model}.request.json').read_text())
                raw = json.loads(existing.read_text())
                if (previous.get('status') != 'success' or previous.get('model') != model
                        or previous.get('audio_sha256') != EXPECTED_SHA
                        or previous.get('parameters') != [list(field) for field in fields]
                        or not isinstance(raw.get('text'), str)):
                    raise ValueError('Saved evidence differs; refusing to overwrite')
                results.append(previous)
                continue
            with LOCK:
                STATE.update(message=f'正在测试 {model}…')
            body, boundary = multipart(model, fields, audio)
            meta = {'model': model, 'endpoint': 'https://api.openai.com/v1/audio/transcriptions',
                    'audio_sha256': EXPECTED_SHA, 'audio_bytes': len(audio),
                    'parameters': fields, 'reference_or_speaker_samples_supplied': False,
                    'started_at': datetime.now(timezone.utc).isoformat()}
            started = time.monotonic()
            req = request.Request(meta['endpoint'], body, method='POST', headers={
                'Authorization': f'Bearer {api_key}', 'Content-Type': f'multipart/form-data; boundary={boundary}'})
            try:
                with opener.open(req, timeout=180) as response:
                    payload = json.loads(response.read(4 * 1024 * 1024))
                    meta.update(status='success', http_status=response.status,
                                request_id=response.headers.get('x-request-id'))
                if not isinstance(payload, dict) or not isinstance(payload.get('text'), str):
                    raise ValueError('Unexpected response shape')
                save_json(OUTPUT / f'{model}.raw.json', payload)
            except error.HTTPError as exc:
                # Provider messages can echo part of an invalid API key. Never retain them.
                meta.update(status='failed', http_status=exc.code, request_id=exc.headers.get('x-request-id'))
                try:
                    code = json.loads(exc.read(65536)).get('error', {}).get('code')
                    if code in {'invalid_api_key', 'insufficient_quota', 'model_not_found', 'rate_limit_exceeded', 'unsupported_parameter'}:
                        meta['error_code'] = code
                except Exception:
                    pass
            except Exception:
                meta.update(status='failed', error_code='network_or_response_error')
            finally:
                # Do not leave an Authorization-bearing request in longer-lived state.
                req = None
            meta['elapsed_seconds'] = round(time.monotonic() - started, 3)
            save_json(OUTPUT / f'{model}.request.json', meta)
            results.append(meta)
            with LOCK:
                STATE['results'] = results.copy()
            # A credential/quota problem applies to both calls; avoid a pointless retry.
            if meta.get('http_status') == 401 or meta.get('error_code') == 'insufficient_quota':
                break
        good = sum(item['status'] == 'success' for item in results)
        final = {'phase': 'complete' if good == len(MODELS) else 'partial' if good else 'failed',
                 'message': f'已完成 {good}/{len(MODELS)} 项测试，原始结果已保留。', 'results': results}
        save_json(OUTPUT / 'run.json', final)
        with LOCK:
            STATE.update(final)
    except Exception:
        with LOCK:
            STATE.update(phase='failed', message='本机测试未完成；未保存密钥。')
    finally:
        api_key = None



def native_main():
    # Private pipe from the native app. No key in argv/environment/files.
    api_key = sys.stdin.buffer.read(4097).decode('utf-8').strip()
    if not api_key.startswith('sk-') or not 20 <= len(api_key) <= 1024 or any(c.isspace() for c in api_key):
        return 2
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(OUTPUT / 'runner.lock', os.O_WRONLY | os.O_CREAT, 0o600), 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 3
        try:
            run_comparison(api_key)
        finally:
            api_key = None
    return 0 if STATE['phase'] == 'complete' else 2


if __name__ == '__main__':
    if sys.argv[1:] == ['--stdin-key']:
        try:
            code = native_main()
        except Exception:
            code = 2
        raise SystemExit(code)
    raise SystemExit('网页测试入口已移除，请在 Plaud威力加强版 → 设置 → OpenAI 转写中运行对比。')

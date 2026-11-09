"""Prepare a local recording for the user's Plaud account, without ASR or credentials."""
import math
import os
import subprocess
import backend as b

def digest(path):
    return b.digest(path)

def prepare(directory):
    directory, m = b.meeting(directory)
    if m.get('capture_state') != 'captured':
        raise ValueError('请先结束录音。')
    if (directory/'submission.json').exists():
        raise ValueError('这场会议已经归档，不能再次上传。')
    with b.lock(directory/'.processing.lock', True):
        files = [b.local_file(directory, p) for p in m.get('audio_files', [])]
        if not files: raise ValueError('没有可上传的录音。')
        length = max(b.duration(p) for p in files)
        if not math.isfinite(length) or length < 3: raise ValueError('录音至少需要 3 秒；原音频已保留。')
        if length > 5*3600: raise ValueError('本版每场支持最多 5 小时，请拆分录音后上传。')
        inputs = [{'name': p.name, 'sha256': digest(p)} for p in files]
        target = directory/'plaud-upload.mp3'; meta = directory/'upload-audio.json'
        if target.exists() and meta.exists():
            saved = b.read(meta)
            if saved.get('inputs') == inputs and saved.get('sha256') == digest(target):
                return dict(prepared=saved)
        b.report(directory, 'processing', '正在合并麦克风与电脑声音，准备上传 Plaud…', .03)
        tmp = directory/'plaud-upload.partial.mp3'
        args = [str(b.FFMPEG), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y']
        for p in files: args += ['-i', str(p)]
        filters = [f'[{i}:a]aresample=32000,asetpts=PTS-STARTPTS[a{i}]' for i in range(len(files))]
        filters += [''.join(f'[a{i}]' for i in range(len(files))) +
                    (f'amix=inputs={len(files)}:duration=longest:normalize=0,' if len(files)>1 else '') +
                    'alimiter=limit=0.95:latency=1[out]']
        args += ['-filter_complex', ';'.join(filters), '-map', '[out]', '-ar', '32000', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '96k', str(tmp)]
        try:
            result = subprocess.run(args, capture_output=True, timeout=max(120, length))
            if result.returncode: raise ValueError('录音整理失败，原始音轨仍在本机。')
            actual = b.duration(tmp)
            if abs(actual-length)>2: raise ValueError('音频长度核验未通过，已停止上传。')
            if tmp.stat().st_size > 500*1024*1024: raise ValueError('音频超过 Plaud 的 500 MB 上传限制。')
            os.replace(tmp, target); target.chmod(0o600)
            audio_digest = digest(target)
            saved = dict(filename=target.name, duration=actual, size=target.stat().st_size, sha256=audio_digest, inputs=inputs)
            b.atomic(meta, saved)
            return dict(prepared=saved)
        finally: tmp.unlink(missing_ok=True)

#!/usr/bin/env python3
"""Headless Plaud synchronization and native-app archival queue."""
import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import threading
import time
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
from runtime_config import vault_path
DEFAULT_VAULT = vault_path()
PLAUD_CONFIG = Path.home() / 'Library/Application Support/Plaud/config.json'
ID_RE = re.compile(r'(?:of_[a-zA-Z0-9_-]{8,100}|mm_[a-f0-9-]{36})\Z')
TIME_RE = re.compile(r'^\[(\d+:\d{2}(?::\d{2})?)(?:\s*-\s*(\d+:\d{2}(?::\d{2})?))?\]\s*(.*)$')
ZONE = ZoneInfo('America/Los_Angeles')

def document_assets(base, documents):
    """Validate passive attachments before publishing a ready job or claiming it."""
    documents = documents or []
    if not isinstance(documents, list) or len(documents) > 10:
        raise ValueError('文档数量无效')
    assets = {}; total = 0; seen = set()
    for item in documents:
        if not isinstance(item, dict) or item.get('sha256') in seen:
            raise ValueError('附件清单无效或重复')
        seen.add(item.get('sha256'))
        for field, hash_field in [('path','sha256'), ('text_path','text_sha256')]:
            rel = item.get(field)
            if field == 'text_path' and not rel: continue
            if not isinstance(rel, str) or not rel.startswith('documents/') or Path(rel).is_absolute():
                raise ValueError('附件路径无效')
            path = (base / rel).resolve()
            if not path.is_relative_to(base.resolve()) or not path.is_file():
                raise ValueError('附件原件缺失')
            size = path.stat().st_size
            limit = 25*1024*1024 if field == 'path' else 1_000_000
            if not 0 < size <= limit or hashlib.sha256(path.read_bytes()).hexdigest() != item.get(hash_field):
                raise ValueError('附件校验失败')
            if field == 'path':
                total += size
                if size != item.get('size'): raise ValueError('附件大小不一致')
            assets[rel] = item[hash_field]
    if total > 100*1024*1024: raise ValueError('附件总大小超过限制')
    return documents, assets


def now():
    return dt.datetime.now(ZONE).isoformat(timespec='seconds')

def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default

def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = value if isinstance(value, bytes) else (value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)).encode()
    tmp = path.with_name('.' + path.name + '.' + secrets.token_hex(6))
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)

def seconds(value):
    parts = [int(x) for x in value.split(':')]
    if len(parts) not in (2, 3) or any(x >= 60 for x in parts[1:]):
        raise ValueError('无效的转写时间戳')
    return sum(v * 60 ** i for i, v in enumerate(reversed(parts)))

def timestamp(sec):
    return f'{sec // 3600:02d}:{sec // 60 % 60:02d}:{sec % 60:02d}'

def parse_transcript(text):
    segments = []
    for line in text.splitlines():
        if not line.strip():
            continue
        match = TIME_RE.match(line)
        if not match:
            if not segments:
                raise ValueError('转写没有可核对的时间轴，暂不归档')
            segments[-1]['text'] += '\n' + line
            continue
        start, end, body = match.groups()
        start, end = seconds(start), seconds(end) if end else None
        if end is not None and end < start:
            raise ValueError('转写的结束时间早于开始时间')
        if segments and start < segments[-1]['start_seconds']:
            raise ValueError('转写时间轴顺序异常，暂不归档')
        speaker = None
        if ': ' in body:
            candidate, remainder = body.split(': ', 1)
            if 0 < len(candidate) <= 80:
                speaker, body = candidate, remainder
        if not body.strip():
            raise ValueError('转写片段为空')
        segments.append({'start_seconds': start, 'end_seconds': end, 'speaker': speaker,
                         'speaker_label_source': 'CLI text prefix; identity unverified', 'text': body,
                         'original_line': line})
    if not segments:
        raise ValueError('转写尚未生成')
    return segments

def image_extension(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return '.png'
    if data.startswith(b'\xff\xd8\xff'):
        return '.jpg'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return '.webp'
    raise ValueError('请附上 PNG、JPEG 或 WebP 截图')

class Bridge:
    def __init__(self, vault=DEFAULT_VAULT, runtime=None, plaud_config=PLAUD_CONFIG, runner=None):
        self.vault = Path(vault).resolve()
        self.inbox = self.vault / 'meeting-inbox/plaud'
        self.runtime = Path(runtime or ROOT / 'runtime')
        self.plaud_config = Path(plaud_config)
        self.runner = runner or subprocess.run
        self.node = shutil.which('node') or '/opt/homebrew/bin/node'
        self.cli = ROOT / 'vendor/node_modules/@plaud-ai/cli/dist/index.js'
        if not self.runtime.exists():
            self.runtime.mkdir(parents=True, exist_ok=True)
        self.inbox.mkdir(parents=True, exist_ok=True)

    @contextlib.contextmanager
    def lock(self):
        with (self.inbox / '.state.lock').open('a') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

    def job_path(self, file_id):
        if not isinstance(file_id, str) or not ID_RE.fullmatch(file_id):
            raise ValueError('无效的会议编号')
        return self.inbox / file_id / 'job.json'

    def jobs(self):
        return sorted([read_json(p) for p in self.inbox.glob('*/job.json') if ID_RE.fullmatch(p.parent.name)], key=lambda j: j['created_at'], reverse=True)

    def history(self):
        # Narrow, non-secret allowlist: never read encryption.json or browser storage.
        data = read_json(self.plaud_config, {})
        current = data.get('currentWorkspaceId')
        history = []
        for item in data.get('uploadHistory', []):
            if not isinstance(item, dict) or (item.get('workspaceId') and item.get('workspaceId') != current):
                continue
            file_id = str(item.get('fileId', ''))
            # Desktop stores bare 32-hex IDs; official CLI exposes them with of_.
            if re.fullmatch(r'[a-f0-9]{32}', file_id):
                file_id = 'of_' + file_id
            if ID_RE.fullmatch(file_id):
                safe = {k: item.get(k) for k in ['fileName', 'recordingId', 'status']}
                history.append(dict(safe, fileId=file_id))
        return history

    def create_job(self, item):
        path = self.job_path(item['fileId'])
        if path.exists():
            return read_json(path)
        recording_id = item.get('recordingId')
        recorded_at = None
        if isinstance(recording_id, (int, float)) and recording_id > 1e12:
            recorded_at = dt.datetime.fromtimestamp(recording_id / 1000, ZONE).isoformat()
        job = {'version': 1, 'file_id': item['fileId'], 'title': item.get('fileName') or '待补充会议',
               'recorded_at': recorded_at, 'created_at': now(), 'updated_at': now(),
               'plaud_status': item.get('status'), 'context': None, 'state': 'needs_context',
               'assets_ready': False, 'last_error': None, 'attempts': 0, 'include_plaud_summary': False}
        atomic(path, job)
        return job

    def discover(self):
        history = self.history()
        with self.lock():
            state = read_json(self.runtime / 'watch.json')
            if state is None:
                atomic(self.runtime / 'watch.json', {'baseline_at': now(), 'seen': [x['fileId'] for x in history]})
                return []
            seen, found = set(state['seen']), []
            for item in history:
                file_id = item['fileId']
                if file_id not in seen:
                    self.create_job(item)
                    found.append(file_id)
                    seen.add(file_id)
                path = self.job_path(file_id)
                if path.exists():
                    job = read_json(path)
                    if job.get('plaud_status') != item['status']:
                        job['plaud_status'] = item['status']
                        atomic(path, job)
            if set(state['seen']) != seen:
                state['seen'] = sorted(seen)
                atomic(self.runtime / 'watch.json', state)
            return found

    def add_history(self, file_id):
        item = next((x for x in self.history() if x['fileId'] == file_id), None)
        if item is None:
            raise ValueError('会议不在当前 Plaud 最近上传列表中')
        with self.lock():
            return self.create_job(item)

    def save_context(self, file_id, data):
        if 'include_plaud_summary' in data and type(data['include_plaud_summary']) is not bool:
            raise ValueError('是否发送 Plaud 总结必须是开关选项')
        participants = str(data.get('participants', '')).strip()
        purpose = str(data.get('purpose', '')).strip()
        automatic = data.get('auto_archive') is True
        if not automatic and (not participants or not purpose):
            raise ValueError('请填写参会人和会议目的；不确定的姓名可以标注待确认')
        if len(participants) > 4000 or len(purpose) > 12000 or len(str(data.get('notes', ''))) > 20000:
            raise ValueError('补充信息过长，请精简后重试')
        files = data.get('images', [])
        if not isinstance(files, list) or len(files) > 8:
            raise ValueError('一次最多附上 8 张截图')
        decoded = []
        for image in files:
            raw = base64.b64decode(image.get('base64', ''), validate=True)
            if not 0 < len(raw) <= 15 * 1024 * 1024:
                raise ValueError('每张截图须小于 15 MB')
            ext = image_extension(raw)
            digest = hashlib.sha256(raw).hexdigest()
            decoded.append((f'{digest}{ext}', raw))
        with self.lock():
            path = self.job_path(file_id)
            job = read_json(path)
            if not job:
                raise ValueError('找不到会议')
            if job['state'] in ['processing', 'done']:
                raise ValueError('这场会议已交给 Codex；请在专用聊天中补充或更正')
            include = data.get('include_plaud_summary', job.get('include_plaud_summary', True))
            if include != job.get('include_plaud_summary', True):
                job['assets_ready'] = False
                job['next_attempt'] = 0
            job['include_plaud_summary'] = include
            images = list((job.get('context') or {}).get('images', []))
            if len(set(images + [name for name, _ in decoded])) > 8:
                raise ValueError('每场会议最多附上 8 张截图')
            for name, raw in decoded:
                atomic(path.parent / 'images' / name, raw)
                if name not in images:
                    images.append(name)
            if not images and not automatic:
                raise ValueError('请至少附上一张会议截图')
            documents, _ = document_assets(path.parent, data.get('documents'))
            job['context'] = {'documents': documents, 'participants': participants, 'purpose': purpose,
                              'notes': str(data.get('notes', '')).strip(), 'images': images,
                              'submitted_at': now(), 'source': 'optional-user-context' if automatic else 'user-confirmed', 'include_plaud_summary': include,
                              'auto_archive': automatic, 'missing_fields': [k for k,v in [('participants',participants),('purpose',purpose),('images',images)] if not v],
                              'speaker_identity_verified': False}
            job['state'] = 'ready' if job['assets_ready'] else 'waiting_plaud'
            job['updated_at'] = now()
            atomic(path, job)
        return job

    def cli_run(self, *args):
        env = dict(os.environ, NO_COLOR='1', FORCE_COLOR='0', DO_NOT_TRACK='1', PLAUD_TELEMETRY_DISABLED='1')
        result = self.runner([self.node, str(self.cli), *map(str, args)], capture_output=True, text=True, timeout=75, env=env)
        if result.returncode:
            if result.returncode == 2:
                raise RuntimeError('Plaud 授权需要重新登录')
            raise RuntimeError(f'Plaud 接口暂时不可用（退出码 {result.returncode}），稍后重试')
        return re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)

    def sync_one(self, file_id, force=False):
        path = self.job_path(file_id)
        # One downloader per meeting across the daemon and manual/heartbeat invocations.
        with (path.parent / 'download.lock').open('a') as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            job = read_json(path)
            if job['state'] in ['done', 'processing'] or job['assets_ready']:
                return
            if not force and time.time() < job.get('next_attempt', 0):
                return
            # Absent policy belongs to pre-option jobs; preserve their original behavior.
            include = job.get('include_plaud_summary', True)
            try:
                detail = self.cli_run('file', file_id)
                fields = dict(re.findall(r'^\s*([a-z_]+):\s*(.*?)\s*$', detail, re.M))
                if fields.get('id') != file_id:
                    raise ValueError('Plaud 返回了不同的会议编号，已停止同步')
                if fields.get('transcript') != 'available' or (include and fields.get('summary') != 'available'):
                    raise RuntimeError('等待 Plaud 生成'+('转写' if fields.get('transcript') != 'available' else '总结'))
                staging = path.parent / 'staging'
                staging.mkdir(exist_ok=True)
                for name in ['transcript.txt', 'plaud-summary.md']:
                    (staging / name).unlink(missing_ok=True)
                self.cli_run('transcript', file_id, '-o', staging / 'transcript.txt')
                if include:self.cli_run('summary', file_id, '-o', staging / 'plaud-summary.md')
                transcript = (staging / 'transcript.txt').read_text()
                summary = (staging / 'plaud-summary.md').read_text() if include else None
                segments = parse_transcript(transcript)
                if include and (not summary.strip() or 'this note has no content yet' in summary):
                    raise ValueError('Plaud 总结尚未完整返回')
                date = (job.get('recorded_at') or job['created_at'])[:10]
                raw_dir = self.vault / 'personal-memory/raw-inputs/work/plaud' / f'{date}-{file_id}'
                timeline = '\n\n'.join(f"[{timestamp(x['start_seconds'])}] {x['speaker'] or '说话人未标注'}\n{x['text']}" for x in segments)
                # Store metadata without audio signed URLs, device serials, or credentials.
                metadata = {k: fields.get(k) for k in ['id', 'name', 'created_at', 'start_at', 'duration', 'transcript', 'summary']}
                metadata['fetched_at'] = now()
                metadata['upstream_timezone'] = 'API timestamps have no offset; original values preserved'
                with self.lock():
                    job = read_json(path)
                    if job['state'] in ['processing', 'done'] or job.get('include_plaud_summary', True) != include:
                        return  # Context changed during download; retry with the new policy.
                    atomic(raw_dir / 'transcript.txt', transcript)
                    atomic(raw_dir / 'transcript.json', {'source': 'Plaud official CLI', 'precision': 'seconds (CLI rendering)', 'segments': segments})
                    atomic(raw_dir / 'transcript-timeline.md', '# 带时间轴逐字稿\n\n' + timeline + '\n')
                    if include:atomic(raw_dir / 'plaud-summary.md', summary)
                    else:(raw_dir / 'plaud-summary.md').unlink(missing_ok=True)
                    metadata['include_plaud_summary'] = include
                    atomic(raw_dir / 'plaud-metadata.json', metadata)
                    job.update(assets_ready=True, raw_dir=str(raw_dir), title=fields.get('name') or job['title'],
                               segment_count=len(segments), last_error=None, updated_at=now())
                    job['state'] = 'ready' if job.get('context') else 'needs_context'
                    atomic(path, job)
            except Exception as exc:
                with self.lock():
                    job = read_json(path)
                    job['attempts'] += 1
                    job['last_error'] = str(exc) if isinstance(exc, (RuntimeError, ValueError)) else '同步暂未完成，将自动重试'
                    job['next_attempt'] = time.time() + min(900, 30 * 2 ** min(job['attempts'], 5))
                    job['updated_at'] = now()
                    atomic(path, job)

    def sync(self):
        for job in self.jobs():
            self.sync_one(job['file_id'])
        return self.ready()

    def ready(self):
        return [j for j in self.jobs() if j['state'] == 'ready' and j.get('context') and j['assets_ready']]

    def claim(self, file_id):
        with self.lock():
            path = self.job_path(file_id)
            job = read_json(path)
            if job['state'] == 'processing':
                return job
            if job['state'] != 'ready' or not job['assets_ready'] or not job.get('context'):
                raise ValueError('会议资料还没齐，不能开始归档')
            raw_dir = Path(job['raw_dir'])
            documents, document_hashes = document_assets(path.parent, job['context'].get('documents'))
            for rel in document_hashes:
                atomic(raw_dir / rel, (path.parent / rel).read_bytes())
            atomic(raw_dir / 'context.json', job['context'])
            for image in job['context']['images']:
                atomic(raw_dir / 'images' / image, (path.parent / 'images' / image).read_bytes())
            source = job.get('source', 'Plaud')
            manifest = read_json(raw_dir / 'manifest.json', {}) if source in ['MeetingMemory', 'OpenAI'] else {}
            manifest.update({'file_id': file_id, 'title': job['title'], 'recorded_at': job['recorded_at'],
                'source': source, 'context': 'context.json', 'transcript': 'transcript.txt',
                'timeline': 'transcript-timeline.md',
                'images': ['images/' + x for x in job['context']['images']], 'documents': documents, 'packaged_at': now()})
            manifest.setdefault('sha256', {}).update(document_hashes)
            if source in ['Plaud', 'OpenAI']:
                include = job.get('include_plaud_summary', True)
                if include and not (raw_dir / 'plaud-summary.md').is_file():
                    raise ValueError('已选择的 Plaud 总结缺失，请重新同步')
                if not include and (raw_dir / 'plaud-summary.md').exists():
                    raise ValueError('资料包含有未选择的总结，请重新同步')
                manifest['include_plaud_summary'] = include
                manifest['plaud_summary'] = 'plaud-summary.md' if include else None
                manifest['is_test'] = bool(job.get('is_test'))
                if job.get('local_meeting_id'): manifest['local_meeting_id'] = job['local_meeting_id']
                if job.get('capture_mode'): manifest['capture_mode'] = job['capture_mode']
                if job.get('capture_warning'): manifest['capture_warning'] = job['capture_warning']
            atomic(raw_dir / 'manifest.json', manifest)
            job.update(state='processing', claimed_at=now(), updated_at=now())
            atomic(path, job)
            return job

    def finish(self, file_id, outputs):
        checked = []
        for output in outputs:
            p = Path(output).resolve()
            if not p.is_relative_to(self.vault) or not p.is_file() or p.stat().st_size == 0:
                raise ValueError('归档结果必须是 vault 中已生成的非空文件')
            checked.append(str(p))
        if len(set(checked)) < 2:
            raise ValueError('请提供会议分析和来源摘要两个已生成的文件')
        with self.lock():
            path = self.job_path(file_id)
            job = read_json(path)
            if job['state'] not in ['processing', 'done']:
                raise ValueError('尚未领取这场会议')
            if (job.get('context') or {}).get('documents'):
                review = Path(job['raw_dir']) / 'document-review.md'
                if not review.is_file() or not review.stat().st_size:
                    raise ValueError('请先记录每份附件实际读取的范围与局限，再完成归档')
            job.update(state='done', outputs=checked, completed_at=now(), updated_at=now())
            atomic(path, job)
            return job

    def release(self, file_id):
        with self.lock():
            path = self.job_path(file_id)
            job = read_json(path)
            if job['state'] == 'processing':
                job.update(state='ready', updated_at=now())
                atomic(path, job)


def watch(bridge, stop=None):
    """Keep discovery and downloads alive without any web server or UI launch."""
    stop = stop or threading.Event()
    with (bridge.runtime / 'watch.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Plaud 后台同步已在运行')
        # Remove the retired bootstrap URL without reading or logging its token.
        (bridge.runtime / 'open-url.txt').unlink(missing_ok=True)
        last_sync = None
        worker = None
        print('Plaud 后台同步已启动；请在 Plaud威力加强版中补充并归档。', flush=True)
        while not stop.is_set():
            try:
                bridge.discover()
                atomic(bridge.runtime / 'health.json', {
                    'watching': True, 'mode': 'native', 'web_enabled': False,
                    'last_scan_at': now(), 'error': None})
                if (last_sync is None or time.monotonic() - last_sync >= 60) and (worker is None or not worker.is_alive()):
                    # A slow download must not block upload discovery.
                    worker = threading.Thread(target=bridge.sync, daemon=True)
                    worker.start()
                    last_sync = time.monotonic()
            except Exception:
                atomic(bridge.runtime / 'health.json', {
                    'watching': True, 'mode': 'native', 'web_enabled': False,
                    'last_scan_at': now(), 'error': '暂时无法读取 Plaud 上传记录，将重试'})
            stop.wait(3)


def open_native_app():
    app = Path.home() / 'Applications/Plaud威力加强版.app'
    if not app.is_dir():
        raise ValueError('没有找到 Plaud威力加强版，请先安装原生 App。')
    subprocess.run(['/usr/bin/open', '-a', str(app)], check=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--vault', type=Path, default=DEFAULT_VAULT)
    parser.add_argument('--runtime', type=Path)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('watch')
    sub.add_parser('serve', help='兼容旧启动配置；仅运行后台同步，不提供网页')
    for name in ['scan', 'sync', 'ready', 'status', 'open']:
        sub.add_parser(name)
    for name in ['add', 'claim', 'release', 'fetch']:
        sub.add_parser(name).add_argument('file_id')
    p = sub.add_parser('finish'); p.add_argument('file_id'); p.add_argument('outputs', nargs='+')
    args = parser.parse_args()
    bridge = Bridge(args.vault, args.runtime)
    if args.command in ['watch', 'serve']:
        return watch(bridge)
    elif args.command == 'scan': result = bridge.discover()
    elif args.command == 'sync': result = bridge.sync()
    elif args.command == 'ready': result = bridge.ready()
    elif args.command == 'status': result = bridge.jobs()
    elif args.command == 'add': result = bridge.add_history(args.file_id)
    elif args.command == 'claim': result = bridge.claim(args.file_id)
    elif args.command == 'release': result = bridge.release(args.file_id)
    elif args.command == 'finish': result = bridge.finish(args.file_id, args.outputs)
    elif args.command == 'fetch':
        bridge.sync_one(args.file_id, force=True); result = read_json(bridge.job_path(args.file_id))
    elif args.command == 'open':
        open_native_app()
        return
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()

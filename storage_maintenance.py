"""Local, model-free storage retention. Never cleans recording/incomplete work.

Only finished, verifiable Plaud uploads with complete local compressed audio are
eligible. Metadata/transcripts/images/documents/results are never removed.
"""
from pathlib import Path
from contextlib import ExitStack
import argparse
import datetime as dt
import json
import os
import re
import time

import backend as b
import retained_evidence as evidence

POLICY = 'storage-policy.json'
PLAN = 'storage-cleanup-plan.json'
SETTINGS = 'storage-settings.json'
DAYS = (0, 7, 30, 90)


class Deferred(Exception): pass
class Ineligible(ValueError): pass


def read_optional(path, default):
    return b.read(path) if path.exists() else default


def settings(root):
    value = read_optional(Path(root)/SETTINGS, {})
    enabled = value.get('enabled', True)
    days = value.get('raw_retention_days', 7)
    if not isinstance(enabled, bool) or type(days) is not int or days not in DAYS:
        raise ValueError('存储设置无法读取，未清理文件')
    return dict(enabled=enabled, raw_retention_days=days)


def configure(root, enabled, days):
    if days not in DAYS: raise ValueError('无效的保留天数')
    with b.lock(Path(root)/'.storage.lock'):
        b.atomic(Path(root)/SETTINGS, dict(enabled=bool(enabled), raw_retention_days=days))


def timestamp(value):
    try: return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError): raise ValueError('归档完成时间无法核验')


def recording(root):
    for p in (Path(root)/'data/meetings').glob('*/meeting.json'):
        # Unreadable state is not permission to clean.
        if b.read(p).get('capture_state') == 'recording': return True
    return False


def require_idle(root):
    if recording(root): raise Deferred('录音正在进行，保存后再自动整理。')


def context(directory, vault, policy, now):
    directory, m = b.meeting(directory)
    if m.get('capture_state') != 'captured' or m.get('cloud_upload') is not True:
        raise Ineligible('保留：录音未完成或不是本机上传的会议')
    if b.read(directory/'progress.json').get('state') != 'complete': raise Ineligible('保留：转写尚未完成')
    upload = b.read(directory/'cloud-upload.json')
    if (upload.get('phase') != 'complete' or not upload.get('file_id') or
        'of_' + upload['file_id'] != m.get('plaud_file_id') or
        not upload.get('account_id') or upload['account_id'] != m.get('plaud_account_id')):
        raise ValueError('保留：上传回执未通过核验')
    receipt = b.read(directory/'submission.json')
    fid = m['plaud_file_id']
    if not isinstance(fid, str) or not re.fullmatch(r'of_[a-zA-Z0-9_-]{8,100}', fid): raise ValueError('录音编号无效')
    if receipt.get('file_id') != fid: raise ValueError('归档回执与会议不一致')
    jobpath = Path(vault)/'meeting-inbox/plaud'/fid/'job.json'
    if Path(receipt.get('job_path', '')).resolve() != jobpath.resolve() or jobpath.is_symlink():
        raise ValueError('归档任务路径不匹配')
    job = b.read(jobpath)
    if (job.get('state') != 'done' or job.get('file_id') != fid or job.get('local_meeting_id') != m['id'] or
        b.read(directory/'archive-trigger.json').get('state') != 'done'):
        raise Ineligible('保留：分析归档尚未核验完成')
    raw = Path(job['raw_dir'])
    if raw.is_symlink() or not raw.resolve().is_relative_to((Path(vault)/'personal-memory/raw-inputs').resolve()):
        raise ValueError('原始证据目录无效')
    raw = raw.resolve()
    manifest = b.read(evidence.safe_path(raw, 'manifest.json'))
    if (manifest.get('file_id') != fid or manifest.get('local_meeting_id') != m['id'] or
        manifest.get('audio') != 'plaud-upload.mp3'):
        raise Ineligible('保留：历史归档格式暂不自动清理')
    upload_audio = b.read(directory/'upload-audio.json')
    expected = manifest.get('sha256', {}).get('plaud-upload.mp3')
    if not expected or expected != upload.get('audio_sha256') or expected != upload_audio.get('sha256'):
        raise ValueError('压缩录音与上传指纹不一致')
    pin = read_optional(directory/POLICY, {}).get('keep_originals', False)
    if not isinstance(pin, bool): raise ValueError('会议保留设置无效')
    completed = timestamp(job.get('completed_at'))
    if completed > now + 300: raise ValueError('归档完成时间异常')
    days = policy['raw_retention_days']
    expires = completed + days*86400 if days else None
    return dict(directory=directory, meeting=m, job=job, jobpath=jobpath, raw=raw, manifest=manifest,
                audio_hash=expected, upload_audio=upload_audio, keep_originals=pin,
                expires_at=expires, expired=not pin and expires is not None and now >= expires)


def candidates(ctx):
    directory, raw, manifest = ctx['directory'], ctx['raw'], ctx['manifest']
    hashes = manifest.get('sha256', {})
    result = []
    def add(scope, rel, expected, reason):
        p = evidence.safe_path(directory if scope == 'local' else raw, rel)
        if p.is_file(): result.append(dict(scope=scope, path=rel, sha256=expected, size=p.stat().st_size, reason=reason))
    for rel in evidence.RAW_TRACKS:
        if rel not in hashes: continue
        # One verified original remains in the vault throughout retention/pinning.
        if evidence.safe_path(raw, rel).is_file() or ctx['expired']:
            add('local', rel, hashes[rel], 'duplicate_raw')
        if ctx['expired']: add('archive', rel, hashes[rel], 'expired_raw')
    for rel, digest in hashes.items():
        if rel not in evidence.RAW_TRACKS and evidence.removable_audio(rel):
            add('archive', rel, digest, 'completed_cache')
            add('local', rel, digest, 'completed_cache')
    # Old/retried generations not included in the sealed evidence can be local
    # caches too. Restrict this to audio below openai/, never imports or documents.
    planned = {(p['scope'], p['path']) for p in result}
    cache = directory/'openai'
    if cache.exists() and not cache.is_symlink():
        for p in cache.rglob('*'):
            rel = p.relative_to(directory).as_posix()
            if evidence.removable_audio(rel) and p.is_file() and ('local', rel) not in planned:
                safe = evidence.safe_path(directory, rel)
                result.append(dict(scope='local', path=rel, sha256=None, size=safe.stat().st_size, reason='completed_cache'))
    return result


def validate_audio(ctx):
    name = 'plaud-upload.mp3'
    for base in [ctx['directory'], ctx['raw']]:
        p = evidence.safe_path(base, name)
        if not p.is_file() or b.digest(p) != ctx['audio_hash']: raise ValueError('完整压缩录音核验失败，保留原件')
        duration = b.duration(p)
        expected = ctx['upload_audio'].get('duration', 0)
        if not expected > 0 or abs(duration - expected) > 2: raise ValueError('压缩录音时长不匹配，保留原件')


def prepare_plan(ctx, operations, now):
    import archive_runner as runner
    directory, raw, job = ctx['directory'], ctx['raw'], ctx['job']
    validate_audio(ctx)
    saved = read_optional(directory/'archive-evidence.json', None)
    if saved is None:
        _, hashes = runner.evidence(job, ctx['jobpath'].parents[3])
        saved = dict(raw_dir=str(raw), sha256=hashes)
        b.atomic(directory/'archive-evidence.json', saved)
    if Path(saved.get('raw_dir', '')).resolve() != raw: raise ValueError('归档核验快照路径不一致')
    hashes = saved['sha256']
    runner.validate_completion(job, ctx['jobpath'].parents[3], raw, hashes)
    # Each proposed removal is checked against immutable evidence or, for
    # unsealed local caches, given its own digest before any files are removed.
    for op in operations:
        p = evidence.safe_path(directory if op['scope'] == 'local' else raw, op['path'])
        digest = b.digest(p)
        if op['sha256'] is not None and digest != op['sha256']: raise ValueError('待清理副本与归档不一致：' + op['path'])
        if op['scope'] == 'archive' and hashes.get(op['path']) != digest: raise ValueError('归档指纹缺失')
        op['sha256'] = digest
    retired = evidence.retired(raw, hashes)
    new_retired = dict(retired)
    for op in operations:
        if op['scope'] == 'archive':
            new_retired[op['path']] = dict(sha256=op['sha256'], size=op['size'], reason=op['reason'], retired_at=now)
    proof = None
    new_snapshot = dict(saved, sha256=dict(hashes))
    if new_retired != retired:
        proof = dict(version=1, file_id=job['file_id'], policy='completed-upload-and-archive-v1',
                     retained_audio=dict(path='plaud-upload.mp3', sha256=ctx['audio_hash']), retired=new_retired)
        # Use the same serialization as backend.atomic for its sealed digest.
        import hashlib
        new_snapshot['sha256'][evidence.RECEIPT] = hashlib.sha256(json.dumps(proof, ensure_ascii=False, indent=2).encode()).hexdigest()
    plan = dict(version=1, state='pending', file_id=job['file_id'], raw_dir=str(raw),
                before=saved, after=new_snapshot, proof=proof, operations=operations, completed=[], created_at=now)
    b.atomic(directory/PLAN, plan)
    return plan


def apply_plan(ctx, plan, root):
    directory, raw = ctx['directory'], ctx['raw']
    if plan.get('version') != 1 or plan.get('file_id') != ctx['job']['file_id'] or Path(plan.get('raw_dir', '')).resolve() != raw:
        raise ValueError('清理恢复记录与会议不一致')
    snapshot = b.read(directory/'archive-evidence.json')
    if snapshot not in (plan['before'], plan['after']): raise ValueError('清理期间归档快照发生变化')
    if {k:v for k,v in plan['before']['sha256'].items() if k != evidence.RECEIPT} != {k:v for k,v in plan['after']['sha256'].items() if k != evidence.RECEIPT}:
        raise ValueError('清理不得修改原件指纹')
    validate_audio(ctx)
    # Validate every operation before publishing deletion authority. Any missing
    # text or unexpected replacement still fails; an interrupted plan may only
    # have already removed explicitly listed audio.
    for op in plan['operations']:
        if op.get('scope') not in ('local', 'archive') or not evidence.removable_audio(op.get('path', '')):
            raise ValueError('清理范围无效')
        p = evidence.safe_path(directory if op['scope'] == 'local' else raw, op['path'])
        if p.exists() and (not p.is_file() or b.digest(p) != op['sha256']): raise ValueError('清理文件已变化：' + op['path'])
    if plan['proof'] is not None:
        b.atomic(raw/evidence.RECEIPT, plan['proof'])
        if b.digest(raw/evidence.RECEIPT) != plan['after']['sha256'].get(evidence.RECEIPT): raise ValueError('清理记录保存失败')
    b.atomic(directory/'archive-evidence.json', plan['after'])
    evidence.verify(raw, plan['after']['sha256'])
    removed = 0
    for index, op in enumerate(plan['operations']):
        require_idle(root)
        # A longer retention period may have been selected after interruption.
        # The receipt can describe a retired file that still exists (and must
        # still match its hash); finish the old plan without removing that file.
        if op['scope'] == 'archive' and op['path'] in evidence.RAW_TRACKS and not ctx['expired']:
            continue
        p = evidence.safe_path(directory if op['scope'] == 'local' else raw, op['path'])
        if p.exists():
            # Recheck immediately before unlinking, including after a crash.
            if b.digest(p) != op['sha256']: raise ValueError('文件发生变化，停止清理')
            p.unlink(); removed += op['size']
        if index not in plan['completed']:
            plan['completed'].append(index); b.atomic(directory/PLAN, plan)
    plan['state'] = 'done'; plan['completed_at'] = time.time()
    b.atomic(directory/PLAN, plan)
    evidence.verify(raw, plan['after']['sha256'])
    return removed


def tree_size(path):
    total = 0
    if not path.exists() or path.is_symlink(): return total
    for base, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(base)/d).is_symlink()]
        for name in files:
            p = Path(base)/name
            if not p.is_symlink(): total += p.stat().st_size
    return total


def scan(root, vault, now=None):
    root, vault = Path(root).resolve(), Path(vault).resolve()
    now = time.time() if now is None else now
    policy = settings(root)
    result = dict(**policy, local_bytes=0, candidate_bytes=0, duplicate_bytes=0, expired_bytes=0,
                  cache_bytes=0, cleaned_bytes=0, meetings={}, errors=[], message='')
    for directory in sorted((root/'data/meetings').glob('mm_*')):
        if not directory.is_dir() or directory.is_symlink(): continue
        local = tree_size(directory); result['local_bytes'] += local
        row = dict(local_bytes=local, candidate_bytes=0, keep_originals=False, originals_available=True, message='处理完成后可自动整理')
        try:
            row['keep_originals'] = read_optional(directory/POLICY, {}).get('keep_originals', False)
            ctx = context(directory, vault, policy, now)
            ops = candidates(ctx)
            row['candidate_bytes'] = sum(op['size'] for op in ops)
            row['originals_available'] = any(evidence.safe_path(base, rel).is_file() for base in (directory, ctx['raw']) for rel in evidence.RAW_TRACKS)
            row['expires_at'] = ctx['expires_at']
            row['message'] = ('原始音轨已按策略清理，完整压缩录音仍保留' if not row['originals_available'] else
                              '原始音轨长期保留在知识库，可核验去除重复副本' if row['keep_originals'] or not policy['raw_retention_days'] else
                              '已归档；原始音轨从归档完成起保留 %s 天' % policy['raw_retention_days'])
            result['candidate_bytes'] += row['candidate_bytes']
            for op in ops:
                key = {'duplicate_raw':'duplicate_bytes', 'expired_raw':'expired_bytes', 'completed_cache':'cache_bytes'}[op['reason']]
                result[key] += op['size']
        except (OSError, ValueError, KeyError, TypeError) as exc:
            row['message'] = str(exc) if isinstance(exc, ValueError) else '保留：尚未具备完整的上传与归档核验资料'
        result['meetings'][directory.name] = row
    return result


def run(root, vault, automatic=False, now=None):
    root, vault = Path(root).resolve(), Path(vault).resolve()
    now = time.time() if now is None else now
    cleaned = 0; failures = []; message = ''
    try:
        with b.lock(root/'.storage.lock', True):
            policy = settings(root)
            if automatic and not policy['enabled']: return dict(scan(root, vault, now), message='自动整理已关闭')
            require_idle(root)
            for directory in sorted((root/'data/meetings').glob('mm_*')):
                if not directory.is_dir() or directory.is_symlink(): continue
                require_idle(root)
                try:
                    with ExitStack() as locks:
                        locks.enter_context(b.lock(directory/'.processing.lock', True))
                        locks.enter_context(b.lock(directory/'.archive-run.lock', True))
                        ctx = context(directory, vault, policy, now)
                        plan = read_optional(directory/PLAN, {})
                        if plan.get('state') == 'pending': cleaned += apply_plan(ctx, plan, root)
                        ops = candidates(ctx)
                        if ops: cleaned += apply_plan(ctx, prepare_plan(ctx, ops, now), root)
                except (BlockingIOError, Ineligible, FileNotFoundError): continue
                except (OSError, ValueError, KeyError, TypeError) as exc:
                    failures.append(dict(id=directory.name, message=str(exc) if isinstance(exc, ValueError) else '资料核验未完成，已保留文件'))
            message = '整理完成；压缩录音、转写、分析和附件均保留。'
            if failures: message += '%s 场会议核验未通过，相关文件已保留。' % len(failures)
    except BlockingIOError: message = '已有存储整理在进行，无需重复启动。'
    except Deferred as exc: message = str(exc)
    result = scan(root, vault, now)
    result.update(cleaned_bytes=cleaned, errors=failures, message=message)
    b.atomic(root/'runtime/storage-last-run.json', dict(at=b.stamp(), cleaned_bytes=cleaned, errors=failures, message=message))
    return result


def pin(root, directory, keep, vault):
    root = Path(root).resolve(); directory, m = b.meeting(directory)
    if directory.parent != root/'data/meetings': raise ValueError('会议不在应用目录')
    with b.lock(root/'.storage.lock'):
        if keep:
            receipt = read_optional(directory/'submission.json', {})
            raw = Path(receipt.get('raw_dir', directory))
            if not raw.resolve().is_relative_to(Path(vault).resolve()/'personal-memory/raw-inputs'):
                raw = directory
            if m.get('capture_state') == 'captured' and not any((base/name).is_file() for base in (directory,raw) for name in evidence.RAW_TRACKS):
                raise ValueError('原始音轨已清理或未录制，无法恢复；现有压缩录音仍保留。')
        # If a previous cleanup was interrupted, keep already removed entries as
        # history, but do not resume deletions before an explicit pin is honored.
        pending = read_optional(directory/PLAN, {})
        if pending.get('state') == 'pending': raise ValueError('上次整理尚未完成，请先检查并整理后再修改保留设置。')
        b.atomic(directory/POLICY, dict(keep_originals=bool(keep), updated_at=b.stamp()))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, default=b.ROOT); p.add_argument('--vault', type=Path, default=b.VAULT)
    p.add_argument('--run', action='store_true'); p.add_argument('--automatic', action='store_true')
    p.add_argument('--configure', choices=['on','off']); p.add_argument('--days', type=int, choices=DAYS, default=7)
    p.add_argument('--meeting', type=str); p.add_argument('--keep', choices=['yes','no'])
    args = p.parse_args()
    try:
        if args.configure: configure(args.root, args.configure == 'on', args.days)
        if args.meeting and args.keep:
            if not b.ID.fullmatch(args.meeting): raise ValueError('会议编号无效')
            pin(args.root, args.root/'data/meetings'/args.meeting, args.keep == 'yes', args.vault)
        result = run(args.root, args.vault, args.automatic) if args.run else scan(args.root, args.vault)
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(json.dumps({'error':str(exc) if isinstance(exc, ValueError) else '本机存储操作失败，文件已保留'}, ensure_ascii=False)); return 1
    return 0


if __name__ == '__main__': raise SystemExit(main())

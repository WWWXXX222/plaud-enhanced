"""Verify sealed evidence, including explicitly recorded post-archive retention.

A model cannot authorize deletion by adding a receipt during a run: the receipt
itself must be in the caller's pre-existing hash snapshot.
"""
from pathlib import Path, PurePosixPath
import backend as b

RECEIPT = 'storage-retention.json'
RAW_TRACKS = {'microphone.caf', 'system.caf'}


def removable_audio(relative):
    p = PurePosixPath(relative)
    if p.is_absolute() or any(x in ('', '.', '..') for x in p.parts): return False
    return relative in RAW_TRACKS or (len(p.parts) >= 3 and p.parts[0] == 'openai'
                                     and p.suffix.lower() in ('.mp3', '.m4a', '.wav'))


def safe_path(root, relative):
    root = Path(root).absolute()
    if not isinstance(relative, str) or not relative: raise ValueError('无效的保留记录路径')
    p = PurePosixPath(relative)
    if p.is_absolute() or '..' in p.parts or '.' in p.parts: raise ValueError('无效的保留记录路径')
    target = root.joinpath(*p.parts)
    cursor = target
    while cursor != root:
        if cursor.is_symlink(): raise ValueError('素材路径包含符号链接')
        cursor = cursor.parent
    if not target.resolve().is_relative_to(Path(root).resolve()): raise ValueError('素材不在会议目录')
    return target


def retired(raw, hashes):
    if RECEIPT not in hashes: return {}
    p = safe_path(raw, RECEIPT)
    if b.digest(p) != hashes[RECEIPT]: raise ValueError('存储清理记录已变化')
    record = b.read(p)
    manifest = b.read(safe_path(raw, 'manifest.json'))
    if record.get('version') != 1 or record.get('file_id') != manifest.get('file_id'):
        raise ValueError('存储清理记录不匹配')
    replacement = record.get('retained_audio', {})
    name = replacement.get('path')
    if name != 'plaud-upload.mp3' or manifest.get('audio') != name:
        raise ValueError('缺少保留的完整压缩录音')
    expected = replacement.get('sha256')
    if not expected or hashes.get(name) != expected or b.digest(safe_path(raw, name)) != expected:
        raise ValueError('保留录音校验失败')
    entries = record.get('retired', {})
    if not isinstance(entries, dict): raise ValueError('存储清理记录无效')
    for rel, item in entries.items():
        if not removable_audio(rel) or rel == name or not isinstance(item, dict):
            raise ValueError('禁止清理此类归档证据')
        if item.get('sha256') != hashes.get(rel) or item.get('reason') not in ('expired_raw', 'completed_cache'):
            raise ValueError('清理记录与原件指纹不匹配')
    return entries


def verify(raw, hashes):
    raw = Path(raw).resolve()
    allowed = retired(raw, hashes)
    for rel, expected in hashes.items():
        p = safe_path(raw, rel)
        if not p.exists() and rel in allowed: continue
        if not p.is_file() or b.digest(p) != expected: raise ValueError('原始证据已变化：' + rel)

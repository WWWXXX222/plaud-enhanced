"""Immutable OpenAI source package in the existing Codex queue, with Plaud link."""
import datetime as dt
from pathlib import Path
from zoneinfo import ZoneInfo

import backend as b
import plaud_account as pa


def submit(directory, vault=b.VAULT):
    directory, m = b.meeting(directory); vault = Path(vault).resolve()
    with b.lock(directory/'.processing.lock', True):
        receipt_path = directory/'submission.json'
        if receipt_path.exists(): return b.read(receipt_path)
        uses_plaud = m.get('cloud_upload') is True or m.get('source') == 'Plaud'
        fid = m.get('plaud_file_id') if uses_plaud else m['id']
        if uses_plaud: pa.validate_id(fid)
        if m.get('transcription_engine') != 'openai': raise ValueError('这条会议未选择 OpenAI。')
        if b.read(directory/'progress.json').get('state') != 'complete': raise ValueError('请等待所选资料全部就绪。')
        uploaded = b.read(directory/'cloud-upload.json') if uses_plaud else {}
        if uses_plaud and (uploaded.get('phase') != 'complete' or 'of_'+uploaded.get('file_id','') != fid or uploaded.get('account_id') != m.get('plaud_account_id')):
            raise ValueError('Plaud 上传回执尚未就绪或不匹配。')
        b.validate_context(m)
        include = uses_plaud and m.get('include_plaud_summary') is True
        if include and (not (directory/'plaud-summary.md').is_file() or not (directory/'plaud-summary.md').read_text().strip()): raise ValueError('所选 Plaud 总结尚未就绪。')
        result = b.read(directory/'openai-result.json'); transcript = b.read(directory/'transcript.json')
        for field, file in [('transcript_sha256','transcript.txt'), ('normalized_sha256','transcript.json'), ('timeline_sha256','transcript-timeline.md')]:
            if result.get(field) != b.digest(b.local_file(directory, file)): raise ValueError('OpenAI 转写证据发生变化，请检查后重试。')
        if transcript.get('source') != 'OpenAI' or not transcript.get('text','').strip() or not transcript.get('segments'):
            raise ValueError('OpenAI 正文或时间参考不完整。')
        audio = b.local_file(directory, result['source_audio'])
        if b.digest(audio) != result['audio_sha256'] or abs(b.duration(audio)-transcript['duration']) > .1:
            raise ValueError('转写音频与原录音不匹配。')
        images = []
        for rel in m.get('images', []):
            p = b.local_file(directory, rel); head = p.read_bytes()[:12]
            if p.stat().st_size > 15*1024*1024 or not (head.startswith(b'\x89PNG\r\n\x1a\n') or head.startswith(b'\xff\xd8\xff')): raise ValueError('截图须为 15 MB 以内的 PNG 或 JPEG。')
            images.append(p)
        q = pa.bridge(vault); job_path = q.job_path(fid)
        with q.lock():
            if job_path.exists():
                prior = b.read(job_path)
                if prior.get('state') in ('ready','processing','done'):
                    if prior.get('source') != 'OpenAI' or prior.get('local_meeting_id') != m['id']: raise ValueError('该录音已按另一份资料提交，不能覆盖归档。')
                    receipt = dict(file_id=fid, job_path=str(job_path), raw_dir=prior['raw_dir'], submitted_at=b.stamp())
                    b.atomic(receipt_path, receipt); return receipt
                if prior.get('context'): raise ValueError('同一录音已有待提交背景，请先完成原有归档。')
            date = dt.datetime.fromisoformat(m['created_at'].replace('Z','+00:00')).astimezone(ZoneInfo('America/Los_Angeles')).date().isoformat()
            raw = vault/'personal-memory/raw-inputs/work/openai'/f'{date}-{fid}'
            names, hashes = [], {}
            for p in images:
                name = b.digest(p)+('.png' if p.read_bytes().startswith(b'\x89PNG') else '.jpg')
                b.copy_atomic(p, raw/'images'/name); b.copy_atomic(p, job_path.parent/'images'/name); names.append(name)
            import meeting_documents as docs
            documents, document_hashes = docs.package(directory,m.get('documents'),[raw,job_path.parent])
            hashes.update(document_hashes)
            context = dict(documents=documents,participants=m.get('participants',''), purpose=m.get('purpose',''), notes=__import__('speaker_notes').context_notes(directory,m.get('notes','')), images=names,
                           is_test=bool(m.get('is_test')), include_plaud_summary=include, submitted_at=b.stamp(), **b.context_metadata(m))
            evidence = ['transcript.txt','transcript.json','transcript-timeline.md','openai-result.json', result['source_audio'],
                        'plaud-upload.mp3','upload-audio.json', *m.get('audio_files',[]), *result['evidence_files']]
            if include: evidence.append('plaud-summary.md')
            elif (raw/'plaud-summary.md').exists(): raise ValueError('未提交的资料目录含有未选择的总结，请检查后重试。')
            for rel in dict.fromkeys(evidence):
                p = b.local_file(directory, rel); b.copy_atomic(p, raw/rel); hashes[rel] = b.digest(p)
            b.atomic(raw/'context.json', context)
            b.atomic(raw/'meeting-metadata.json', dict(m, transcript_source='OpenAI', speaker_status='unconfirmed'))
            if uses_plaud: b.atomic(raw/'plaud-upload-receipt.json', dict(file_id=fid, phase='complete', audio_sha256=uploaded.get('audio_sha256'),
                         account_id=m.get('plaud_account_id'), local_meeting_id=m['id']))
            manifest = dict(file_id=fid, title=m['title'], recorded_at=m['created_at'], source='OpenAI', local_meeting_id=m['id'],
                plaud_file_id=m.get('plaud_file_id'), transcript='transcript.txt', transcript_json='transcript.json', timeline='transcript-timeline.md',
                timestamp_role=transcript['timestamp_role'], speaker_status='unconfirmed', primary_model=result['primary_model'],
                timeline_model=result['timeline_model'], metadata='meeting-metadata.json', context='context.json',
                audio=result['source_audio'], images=['images/'+n for n in names], documents=documents, sha256=hashes,
                include_plaud_summary=include, plaud_summary='plaud-summary.md' if include else None,
                is_test=bool(m.get('is_test')), capture_mode=m.get('capture_mode'), capture_warning=m.get('capture_warning'), packaged_at=b.stamp())
            b.atomic(raw/'manifest.json', manifest)
            job = dict(version=3, file_id=fid, title=m['title'], source='OpenAI', local_meeting_id=m['id'], plaud_file_id=m.get('plaud_file_id'),
                recorded_at=m['created_at'], created_at=b.stamp(), updated_at=b.stamp(), context=context, state='ready', assets_ready=True,
                segment_count=len(transcript['segments']), raw_dir=str(raw), include_plaud_summary=include, is_test=bool(m.get('is_test')),
                capture_mode=m.get('capture_mode'), capture_warning=m.get('capture_warning'), last_error=None, attempts=0)
            b.atomic(job_path, job)
            receipt = dict(file_id=fid, job_path=str(job_path), raw_dir=str(raw), submitted_at=b.stamp())
            b.atomic(receipt_path, receipt); return receipt

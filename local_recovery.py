"""Model-free idle check; only saved, unfinished local recordings start ASR."""
import time
import backend as b

def recover(root=b.ROOT, vault=b.VAULT):
    import archive_dispatch as archive
    rows = list((root/'data/meetings').glob('*/meeting.json'))
    if any(b.read(p).get('capture_state') == 'recording' for p in rows): return
    for path in rows:
        meeting = b.read(path); directory = path.parent
        if meeting.get('capture_state') != 'captured' or meeting.get('cloud_upload') or meeting.get('source') == 'Plaud': continue
        if meeting.get('transcription_engine') != 'local' or not meeting.get('auto_archive'): continue
        if (directory/'submission.json').exists(): continue
        retry = b.read(directory/'local-retry.json') if (directory/'local-retry.json').exists() else {}
        if retry.get('retry_at', 0) > time.time(): continue
        try:
            progress = b.read(directory/'progress.json') if (directory/'progress.json').exists() else {}
            if progress.get('state') != 'complete': b.transcribe(directory)
            archive.handoff(directory, vault)
        except (BlockingIOError, ValueError, OSError): continue

if __name__ == '__main__': recover()

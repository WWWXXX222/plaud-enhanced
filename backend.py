#!/usr/bin/env python3
"""Offline audio processing and immutable handoff to the user's Codex queue."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
import runtime_config as config
VAULT = config.vault_path()
FFMPEG = config.executable('ffmpeg')
FFPROBE = config.executable('ffprobe')
ID = re.compile(r'mm_[a-f0-9-]{36}\Z')

def stamp(): return dt.datetime.now().astimezone().isoformat(timespec='seconds')

def atomic(path, obj):
    path = Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_name('.'+path.name+'.'+secrets.token_hex(6))
    content=obj if isinstance(obj,bytes) else (obj if isinstance(obj,str) else json.dumps(obj,ensure_ascii=False,indent=2)).encode()
    try:
        fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as f:f.write(content);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:tmp.unlink(missing_ok=True)

def read(path): return json.loads(Path(path).read_text())

@contextlib.contextmanager
def lock(path, nonblocking=False):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('a') as f:
        fcntl.flock(f,fcntl.LOCK_EX|(fcntl.LOCK_NB if nonblocking else 0))
        try:yield f
        finally:fcntl.flock(f,fcntl.LOCK_UN)

def local_file(directory, relative):
    if not isinstance(relative,str) or not relative or Path(relative).is_absolute():raise ValueError('无效的素材路径')
    p=(directory/relative).resolve()
    if not p.is_relative_to(directory.resolve()) or not p.is_file():raise ValueError('素材缺失，请检查录音和截图')
    return p

def meeting(directory):
    directory=Path(directory).resolve();m=read(directory/'meeting.json')
    if not ID.fullmatch(m.get('id','')) or directory.name!=m['id']:raise ValueError('会议编号不一致')
    return directory,m

def report(directory,state,message,progress=0,**details):
    atomic(directory/'progress.json',dict(state=state,message=message,progress=progress,pid=os.getpid(),updated_at=stamp(),**details))

def validate_context(m):
    if not str(m.get('title','')).strip(): raise ValueError('会议标题不能为空。')
    automatic = m.get('auto_archive') is True
    if not automatic and any(not str(m.get(k,'')).strip() for k in ('participants','purpose')):
        raise ValueError('请补齐参会人和会议目的。')
    if not isinstance(m.get('images',[]),list) or not (0 if automatic else 1) <= len(m.get('images',[])) <= 8:
        raise ValueError('截图数量不符合要求。')

def context_metadata(m):
    return dict(source='optional-user-context' if m.get('auto_archive') is True else 'user-confirmed',
                auto_archive=m.get('auto_archive') is True,
                missing_fields=[k for k in ('participants','purpose','images') if not m.get(k)],
                speaker_identity_verified=False)

def duration(path):
    r=subprocess.run([str(FFPROBE),'-v','error','-show_entries','format=duration','-of','json',str(path)],capture_output=True,text=True,timeout=60)
    if r.returncode:raise ValueError('录音文件无法读取；原始录音已保留')
    value=float(json.loads(r.stdout)['format']['duration'])
    if not math.isfinite(value) or value<=0:raise ValueError('录音为空')
    return value

def normalize_segments(raw,audio_duration):
    out=[]
    for s in raw.get('transcription',[]):
        start=s.get('offsets',{}).get('from');end=s.get('offsets',{}).get('to');text=s.get('text','').strip()
        if not isinstance(start,(int,float)) or not isinstance(end,(int,float)) or not math.isfinite(start+end):raise ValueError('转写时间轴缺失')
        start,end=start/1000,end/1000
        if not text:continue
        if start<0 or end<start or start>audio_duration+1 or end>audio_duration+2:raise ValueError('转写时间超出录音范围')
        if out and start<out[-1]['start_seconds']:raise ValueError('转写时间轴顺序异常')
        out.append(dict(start_seconds=round(start,3),end_seconds=round(min(end,audio_duration),3),speaker=None,text=text))
    if not out:raise ValueError('没有识别到清晰语音，请回听录音或选择正确的语言后重试')
    return out

def timestamp(s):
    s=int(s);return f'{s//3600:02d}:{s//60%60:02d}:{s%60:02d}'

def transcribe(directory,model=None,cli=None):
    if model is None and cli is None:
        from local_transcription import transcribe as local_transcribe
        return local_transcribe(directory)
    directory,m=meeting(directory)
    if m.get('capture_state')=='recording':raise ValueError('请先结束录音')
    if (directory/'submission.json').exists():raise ValueError('这场会议已提交，请在 Codex 中更正')
    with lock(directory/'.processing.lock',True):
        try:
            files=[local_file(directory,x) for x in m.get('audio_files',[])]
            if not files:raise ValueError('尚无录音，请先录音或导入音频')
            model=Path(model or ROOT/'models/ggml-small-q5_1.bin')
            cli=Path(cli or ROOT/'vendor/whisper.cpp/build/bin/whisper-cli')
            if not model.is_file() or not cli.is_file():raise ValueError('本地转写引擎尚未安装完成')
            report(directory,'processing','正在整理录音…',0.03)
            lengths=[duration(p) for p in files]
            expected=m.get('duration',0)
            length=max(lengths)
            if isinstance(expected,(int,float)) and math.isfinite(expected) and expected>length and expected<length+600:length=expected
            args=[str(FFMPEG),'-nostdin','-hide_banner','-loglevel','error','-y']
            for p in files:args+=['-i',str(p)]
            chains=[f'[{i}:a]aresample=16000,asetpts=PTS-STARTPTS[a{i}]' for i in range(len(files))]
            mixed=''.join(f'[a{i}]' for i in range(len(files)))
            chains.append(mixed+(f'amix=inputs={len(files)}:duration=longest:normalize=0,' if len(files)>1 else '')+f'alimiter=limit=0.95:latency=1,apad,atrim=duration={length:.6f}[out]')
            args+=['-filter_complex',';'.join(chains),'-map','[out]','-ar','16000','-ac','1','-c:a','pcm_s16le',str(directory/'audio.partial.wav')]
            r=subprocess.run(args,capture_output=True,timeout=max(120,length))
            if r.returncode:raise ValueError('录音整理失败；原始文件已保留')
            os.replace(directory/'audio.partial.wav',directory/'audio.wav')
            actual=duration(directory/'audio.wav')
            report(directory,'processing','正在本机转写，可先补充会议背景…',0.1)
            output=directory/'whisper.partial'
            output.with_suffix('.partial.json').unlink(missing_ok=True)
            lang=m.get('language','auto')
            if lang not in ['auto','zh','en']:raise ValueError('请选择自动、中文或英文')
            command=[str(cli),'-m',str(model),'-f',str(directory/'audio.wav'),'-l',lang,'-oj','-of',str(output),'-pp','-t','6','-sns']
            vad=ROOT/'models/ggml-silero-v6.2.0.bin'
            if vad.exists():command+=['--vad','-vm',str(vad)]
            # GPU can be unavailable in non-interactive environments: preserve explicit fallback.
            logs=directory/'transcription.log'
            for gpu in [True,False]:
                with logs.open('wb') as log:
                    r=subprocess.run(command+([] if gpu else ['-ng']),stdout=log,stderr=log,timeout=max(600,actual*8))
                if r.returncode==0:break
                if not gpu:raise ValueError('本机转写失败；录音已保留，可以重试')
                report(directory,'processing','正在使用兼容模式转写…',0.15)
            raw_path=Path(str(output)+'.json')
            raw=read(raw_path);segments=normalize_segments(raw,actual)
            result=dict(source='MeetingMemory',engine='whisper.cpp 1.9.5 / small-q5_1',language=raw.get('result',{}).get('language',lang),
                        duration=actual,precision='model-estimated timestamps; milliseconds stored, not guaranteed alignment',
                        speaker_identification=False,segments=segments,created_at=stamp())
            # Never advertise a partial or failed result as complete.
            atomic(directory/'transcript.json',result)
            atomic(directory/'transcript.txt','\n\n'.join(f"[{timestamp(s['start_seconds'])} - {timestamp(s['end_seconds'])}] {s['text']}" for s in segments)+'\n')
            atomic(directory/'whisper-original.json',raw_path.read_bytes())
            raw_path.unlink(missing_ok=True)
            report(directory,'complete',f'转写完成 · {len(segments)} 段发言',1)
            return result
        except Exception as e:
            message=str(e) if isinstance(e,ValueError) else '处理被中断或暂时失败；原始录音已保留，请重试'
            report(directory,'error',message)
            raise

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def copy_atomic(source,target):
    target.parent.mkdir(parents=True,exist_ok=True)
    tmp=target.with_name('.'+target.name+'.'+secrets.token_hex(6))
    try:
        shutil.copyfile(source,tmp);tmp.chmod(0o600);os.replace(tmp,target)
    finally:tmp.unlink(missing_ok=True)

def submit(directory,vault=VAULT):
    directory,m=meeting(directory);vault=Path(vault).resolve()
    if m.get('transcription_engine')=='openai':
        import openai_archive
        return openai_archive.submit(directory,vault)
    if m.get('source')=='Plaud' and m.get('transcription_engine') != 'local':
        import plaud_account
        return plaud_account.submit(directory,vault)
    with lock(directory/'.processing.lock',True):
        existing=directory/'submission.json'
        if existing.exists():return read(existing)
        if read(directory/'progress.json').get('state')!='complete':raise ValueError('请等待转写完整结束后再提交')
        validate_context(m)
        images=m.get('images',[])
        result=read(directory/'transcript.json')
        if not result.get('segments'):raise ValueError('转写为空，不能提交')
        verified_duration=result.get('duration')
        if not isinstance(verified_duration,(int,float)) or not math.isfinite(verified_duration) or verified_duration<=0:raise ValueError('录音时长未验证，请重新转写')
        source_images=[]
        for rel in images:
            p=local_file(directory,rel);head=p.read_bytes()[:12]
            if p.stat().st_size>15*1024*1024 or not (head.startswith(b'\x89PNG\r\n\x1a\n') or head.startswith(b'\xff\xd8\xff')):raise ValueError('截图应为 15 MB 以内的 PNG 或 JPEG')
            source_images.append(p)
        file_id=m['id'];inbox=vault/'meeting-inbox/plaud';jobdir=inbox/file_id;jobpath=jobdir/'job.json'
        with lock(inbox/'.state.lock'):
            if jobpath.exists():
                receipt=dict(file_id=file_id,job_path=str(jobpath),raw_dir=read(jobpath)['raw_dir'],submitted_at=stamp())
                atomic(existing,receipt);return receipt
            recorded=dt.datetime.fromisoformat(m['created_at'].replace('Z','+00:00'))
            date=recorded.astimezone().date().isoformat()
            raw=vault/'personal-memory/raw-inputs/work/meeting-memory'/f'{date}-{file_id}'
            names=[]
            for p in source_images:
                name=digest(p)+('.png' if p.read_bytes()[:8]==b'\x89PNG\r\n\x1a\n' else '.jpg')
                copy_atomic(p,jobdir/'images'/name);copy_atomic(p,raw/'images'/name);names.append(name)
            import meeting_documents as docs
            documents, document_hashes = docs.package(directory,m.get('documents'),[raw,jobdir])
            context=dict(documents=documents,participants=m.get('participants',''),purpose=m.get('purpose',''),notes=__import__('speaker_notes').context_notes(directory,m.get('notes','')),images=names,
                         submitted_at=stamp(),is_test=m.get('is_test',False),**context_metadata(m))
            evidence=['transcript.txt','transcript.json','whisper-original.json','audio.wav',*m.get('audio_files',[])]
            hashes=dict(document_hashes)
            for rel in dict.fromkeys(evidence):
                p=local_file(directory,rel);copy_atomic(p,raw/rel);hashes[rel]=digest(p)
            metadata=dict(m,duration=verified_duration,duration_source='verified mixed audio')
            atomic(raw/'context.json',context);atomic(raw/'meeting-metadata.json',metadata)
            atomic(raw/'transcript-timeline.md','# 带时间轴逐字稿\n\n'+(directory/'transcript.txt').read_text())
            manifest=dict(file_id=file_id,title=m['title'],recorded_at=m['created_at'],source='MeetingMemory',context='context.json',
                          transcript='transcript.txt',timeline='transcript-timeline.md',metadata='meeting-metadata.json',
                          audio='audio.wav',upstream_summary=None,images=['images/'+n for n in names],documents=documents,sha256=hashes,
                          is_test=m.get('is_test',False),packaged_at=stamp())
            atomic(raw/'manifest.json',manifest)
            job=dict(version=2,file_id=file_id,title=m['title'],source='MeetingMemory',recorded_at=m['created_at'],
                     created_at=stamp(),updated_at=stamp(),context=context,state='ready',assets_ready=True,
                     segment_count=len(result['segments']),raw_dir=str(raw),last_error=None,attempts=0,
                     is_test=m.get('is_test',False))
            # The ready job is published last, after the whole evidence package exists.
            atomic(jobpath,job)
            receipt=dict(file_id=file_id,job_path=str(jobpath),raw_dir=str(raw),submitted_at=stamp())
            atomic(existing,receipt)
            return receipt

def main():
    os.umask(0o077)
    p=argparse.ArgumentParser();p.add_argument('command',choices=['transcribe','submit','auto-handoff','plaud-prepare','plaud-account','plaud-list','plaud-login','plaud-import','plaud-refresh','plaud-summary','plaud-audio']);p.add_argument('directory',type=Path);p.add_argument('--vault',type=Path,default=VAULT);p.add_argument('--page',type=int,default=1);p.add_argument('--file-id');p.add_argument('--account-id')
    a=p.parse_args()
    try:
        if a.command=='auto-handoff':
            import archive_dispatch
            print(json.dumps(dict(ok=True,**archive_dispatch.handoff(a.directory,a.vault)),ensure_ascii=False))
        elif a.command=='plaud-prepare':
            from prepare_upload import prepare
            print(json.dumps(dict(ok=True,**prepare(a.directory)),ensure_ascii=False))
        elif a.command.startswith('plaud-'):
            import plaud_account
            result=plaud_account.dispatch(a.command,a)
            print(json.dumps(dict(ok=True,**result),ensure_ascii=False))
        else:
            result=transcribe(a.directory) if a.command=='transcribe' else submit(a.directory,a.vault)
            if a.command=='submit':
                import archive_dispatch
                archive_dispatch.dispatch(a.directory,a.vault)
            print(json.dumps({'ok':True,'segments':len(result.get('segments',[])),'receipt':result if a.command=='submit' else None},ensure_ascii=False))
    except BlockingIOError:print(json.dumps({'ok':False,'error':'这场会议正在处理，请稍后重试'},ensure_ascii=False));sys.exit(2)
    except Exception as e:print(json.dumps({'ok':False,'error':str(e) if isinstance(e,ValueError) else '处理未完成，请检查应用中的状态'},ensure_ascii=False));sys.exit(1)

if __name__=='__main__':main()

"""Plaud account adapter. OAuth and credentials stay with the official CLI."""
import base64
import datetime as dt
import hashlib
from functools import lru_cache
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
from zoneinfo import ZoneInfo

import backend as b

BRIDGE_ROOT = b.config.bridge_root()
CLI = BRIDGE_ROOT / 'vendor/node_modules/@plaud-ai/cli/dist/index.js'
FILE_ID = re.compile(r'of_[a-zA-Z0-9_-]{8,100}\Z')
ANSI = re.compile(r'\x1b\[[0-9;]*m')
ACCOUNT_CACHE = b.ROOT / 'data/plaud/account.json'

class PlaudError(ValueError):
    pass

class Client:
    def __init__(self, runner=subprocess.run): self.runner = runner
    def run(self, *args, timeout=80):
        env = dict(os.environ, NO_COLOR='1', FORCE_COLOR='0', DO_NOT_TRACK='1', PLAUD_TELEMETRY_DISABLED='1', PLAUD_NO_UPDATE_NOTIFIER='1')
        node = shutil.which('node') or '/usr/local/bin/node'
        try:
            r = self.runner([node, str(CLI), *map(str,args)], capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            raise PlaudError('Plaud 连接超时，已有资料仍保留；请稍后刷新。')
        if r.returncode == 2: raise PlaudError('Plaud 授权已失效，请点击“连接 Plaud 账户”重新授权。')
        if r.returncode: raise PlaudError('暂时无法连接 Plaud，请检查网络后重试。')
        return ANSI.sub('',r.stdout)
    def account(self):
        fields = parse_fields(self.run('me'))
        if not fields.get('id'): raise PlaudError('Plaud 未返回账户身份，暂不读取录音。')
        key = hashlib.sha256((fields['id']+'|'+fields.get('workspace_id','')).encode()).hexdigest()[:24]
        return dict(id=key,name=fields.get('nickname') or 'Plaud 用户',email=fields.get('email',''),connected=True,checked_at=b.stamp(),workspace_id=fields.get('workspace_id',''))
    def login(self):
        self.run('login', timeout=330)
        return self.account()
    def files(self,page):
        if not 1 <= page <= 1000: raise PlaudError('页码超出支持范围。')
        return parse_files(self.run('files','--page',page,'--page-size',50),page,50)
    def detail(self,fid):
        validate_id(fid)
        f = parse_fields(self.run('file',fid))
        if f.get('id') != fid: raise PlaudError('Plaud 录音编号不一致，已停止同步。')
        return {k:f.get(k,'') for k in ['id','name','created_at','start_at','duration','transcript','summary']}


def parse_fields(text): return dict(re.findall(r'^\s*([a-z_]+):[ \t]*(.*?)\s*$',text,re.M))
def validate_id(fid):
    if not isinstance(fid,str) or not FILE_ID.fullmatch(fid): raise PlaudError('无效的 Plaud 录音编号。')

def parse_files(text,page,size):
    count = re.search(r'^Files on this page: (\d+)\s*$',text,re.M)
    records=[]
    for line in text.splitlines():
        if not re.match(r'^\s*of_',line): continue
        m=re.match(r'^\s*(of_[a-zA-Z0-9_-]+)\s{2,}(.+?)\s{2,}((?:\d{4}-\d{2}-\d{2})|-)\s{2,}(\S+)\s*$',line)
        if not m: raise PlaudError('Plaud 列表格式已变化，已停止读取以免错配录音。')
        fid,title,date,duration=m.groups();validate_id(fid)
        records.append(dict(id=fid,title=title.strip() or '未命名录音',date=date,duration=duration))
    if not count or int(count[1])!=len(records) or len({r['id'] for r in records})!=len(records):
        raise PlaudError('Plaud 列表不完整，请刷新重试。')
    return dict(records=records,page=page,has_more=len(records)==size and page<1000)

def duration_seconds(value):
    if not re.fullmatch(r'(?:\d+h)?(?:\d+m)?(?:\d+s)?',value or ''):return 0
    return sum(int(n)*{'h':3600,'m':60,'s':1}[u] for n,u in re.findall(r'(\d+)([hms])',value))

@lru_cache(maxsize=1)
def queue_module():
    spec=importlib.util.spec_from_file_location('ownplaud_queue_bridge',BRIDGE_ROOT/'bridge.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

def bridge(vault=b.VAULT): return queue_module().Bridge(vault=vault)

def verify_account(client,expected):
    account=client.account()
    if account['id']!=expected:raise PlaudError('Plaud 账户已切换，请刷新账户列表后再打开这条录音。')
    b.atomic(ACCOUNT_CACHE,account)
    return account

def list_recordings(page=1,client=None):
    client=client or Client();account=client.account();result=client.files(page)
    result['account']=account;b.atomic(ACCOUNT_CACHE,account)
    b.atomic(b.ROOT/'data/plaud'/account['id']/f'page-{page}.json',result)
    return result

def local_id(account_id,fid):return 'mm_'+str(uuid.uuid5(uuid.NAMESPACE_URL,'plaud:'+account_id+':'+fid))

def import_recording(fid,account_id,client=None,vault=b.VAULT,root=None):
    validate_id(fid);client=client or Client();verify_account(client,account_id)
    detail=client.detail(fid)
    base=Path(root) if root else b.ROOT/'data/meetings'
    directory=base/local_id(account_id,fid)
    # A locally recorded upload keeps its original folder and context when reopened from history.
    for path in base.glob('mm_*/meeting.json'):
        try: existing=b.read(path)
        except (ValueError,OSError): continue
        if existing.get('plaud_file_id')==fid and existing.get('plaud_account_id')==account_id:
            directory=path.parent;break
    directory.mkdir(parents=True,exist_ok=True)
    with b.lock(directory/'.processing.lock',True):
        if not (directory/'meeting.json').exists():
            date=detail.get('start_at') if detail.get('start_at') not in ['', '-'] else detail.get('created_at')
            m=dict(id=directory.name,title=detail.get('name') or 'Plaud 录音',created_at=date or b.stamp(),participants='',purpose='',notes='',images=[],audio_files=[],capture_state='captured',capture_mode='plaud',duration=duration_seconds(detail.get('duration')),language='auto',is_test=False,include_plaud_summary=False,source='Plaud',plaud_file_id=fid,plaud_account_id=account_id)
            b.atomic(directory/'meeting.json',m)
        else:
            m=b.read(directory/'meeting.json')
            if m.get('plaud_file_id')!=fid or m.get('plaud_account_id')!=account_id:raise PlaudError('本机录音来源不一致。')
        attach_existing(directory,m,vault)
        if m.get('transcription_engine')=='openai':
            # History must not overwrite OpenAI text with Plaud ASR or parse it as CLI text.
            if (directory/'submission.json').exists():
                raw=Path(b.read(directory/'submission.json')['raw_dir']).resolve()
                if not raw.is_relative_to(Path(vault).resolve()):raise PlaudError('归档资料路径不在所选项目内。')
                for name in ['transcript.txt','transcript.json','transcript-timeline.md']:
                    b.copy_atomic(b.local_file(raw,name),directory/name)
                b.report(directory,'complete','OpenAI 归档原文 · 说话人待确认',1)
        elif (directory/'submission.json').exists():
            hydrate_archive(directory,m,detail,vault)
        else: fetch_assets(directory,m,client,detail)
    return dict(meeting=b.read(directory/'meeting.json'))

def hydrate_archive(directory,m,detail,vault):
    receipt=b.read(directory/'submission.json')
    if not receipt.get('raw_dir'):return
    raw=Path(receipt['raw_dir']).resolve()
    if not raw.is_relative_to(Path(vault).resolve()):raise PlaudError('归档资料路径不在所选项目内。')
    if not (raw/'transcript.txt').exists():return
    original=(raw/'transcript.txt').read_text();segments=queue_module().parse_transcript(original)
    length=max(duration_seconds(detail.get('duration')),max((s['end_seconds'] or s['start_seconds']) for s in segments))
    b.atomic(directory/'transcript.txt',original)
    b.atomic(directory/'transcript.json',dict(source='Plaud archived snapshot',duration=length,speaker_identification=False,segments=segments))
    manifest=b.read(raw/'manifest.json') if (raw/'manifest.json').exists() else {}
    has_summary=manifest.get('include_plaud_summary',m.get('include_plaud_summary',True)) and (raw/'plaud-summary.md').exists()
    if has_summary:b.atomic(directory/'plaud-summary.md',(raw/'plaud-summary.md').read_text())
    detail.update(fetched_at=b.stamp(),account_id=m['plaud_account_id'],transcript_ready=True,summary_ready=bool(has_summary),archived_snapshot=True)
    b.atomic(directory/'plaud-detail.json',detail)
    b.report(directory,'complete',f'Plaud 归档原文 · {len(segments)} 段转写',1)

def fetch_assets(directory,m,client,detail=None):
    if m.get('transcription_engine')=='openai':raise PlaudError('本条会议选择 OpenAI，不以 Plaud 转写覆盖正文。')
    detail=detail or client.detail(m['plaud_file_id']);fid=m['plaud_file_id']
    include=m.get('include_plaud_summary') is True
    b.report(directory,'processing','正在读取 Plaud 转写'+('与总结' if include else '')+'…',0.1)
    try:
        with tempfile.TemporaryDirectory(prefix='.plaud-',dir=directory) as staging:
            staging=Path(staging);transcript=None;summary=None
            if detail['transcript']=='available':
                path=staging/'transcript.txt';client.run('transcript',fid,'-o',path)
                if path.exists():
                    original=path.read_text();segments=queue_module().parse_transcript(original)
                    length=max(duration_seconds(detail.get('duration')),max((s['end_seconds'] or s['start_seconds']) for s in segments))
                    transcript=dict(source='Plaud',duration=length,precision='seconds (official CLI rendering)',speaker_identification=False,segments=segments)
                    b.atomic(directory/'transcript.txt',original);b.atomic(directory/'transcript.json',transcript)
            if include and detail['summary']=='available':
                path=staging/'summary.md';client.run('summary',fid,'-o',path)
                if path.exists() and path.read_text().strip() and 'this note has no content yet' not in path.read_text():
                    summary=path.read_text();b.atomic(directory/'plaud-summary.md',summary)
            detail.update(fetched_at=b.stamp(),account_id=m['plaud_account_id'],transcript_ready=transcript is not None,summary_ready=summary is not None)
            b.atomic(directory/'plaud-detail.json',detail)
            # A checkbox change during the request must not publish stale readiness.
            current=b.read(directory/'meeting.json')
            if (current.get('include_plaud_summary') is True)!=include:
                b.report(directory,'waiting_plaud','发送选项已更新，正在重新检查资料。')
            elif transcript is not None and (not include or summary is not None):b.report(directory,'complete',f'Plaud 已同步 · {len(transcript["segments"])} 段转写'+('与总结' if include else ' · 不发送总结'),1)
            else:b.report(directory,'waiting_plaud','等待 Plaud 生成'+('转写' if not transcript else '总结')+'；生成后点击刷新。')
    except Exception:
        b.report(directory,'error','Plaud 同步未完成，已有资料已保留；请重新连接或刷新。');raise

def refresh_recording(directory,client=None):
    directory,m=b.meeting(directory);client=client or Client();verify_account(client,m.get('plaud_account_id'))
    if (directory/'submission.json').exists():raise PlaudError('这场会议已提交，原始证据保持不变；可在 Codex 中补充更正。')
    with b.lock(directory/'.processing.lock',True):fetch_assets(directory,m,client)
    return dict(meeting=m)

def view_summary(directory,client=None):
    directory,m=b.meeting(directory);client=client or Client();verify_account(client,m.get('plaud_account_id'))
    # Viewing is deliberately separate from submission policy and readiness.
    if (directory/'submission.json').exists():raise PlaudError('已归档会议仅展示提交时保留的资料。')
    with b.lock(directory/'.processing.lock',True):
        if client.detail(m['plaud_file_id'])['summary']!='available':raise PlaudError('Plaud 总结尚未生成；不影响默认的转写归档。')
        with tempfile.TemporaryDirectory(prefix='.summary-',dir=directory) as staging:
            path=Path(staging)/'summary.md';client.run('summary',m['plaud_file_id'],'-o',path)
            if not path.exists() or not path.read_text().strip() or 'this note has no content yet' in path.read_text():raise PlaudError('Plaud 总结尚未完整返回。')
            b.atomic(directory/'plaud-summary.md',path.read_text())
    return dict(meeting=m)

def attach_existing(directory,m,vault):
    path=Path(vault)/'meeting-inbox/plaud'/m['plaud_file_id']/'job.json'
    if not path.exists():return
    job=b.read(path)
    if not job.get('context') or job['state'] not in ['ready','processing','done','waiting_plaud']:return
    if not (directory/'submission.json').exists():
        context=job['context'];m.update(participants=context.get('participants',''),purpose=context.get('purpose',''),notes=context.get('notes',''),is_test=job.get('is_test',False),include_plaud_summary=job.get('include_plaud_summary',True))
        if job.get('source')=='OpenAI':m['transcription_engine']='openai'
        m['images']=[]
        for name in context.get('images',[]):
            source=b.local_file(path.parent,'images/'+name);target='images/'+source.name;b.copy_atomic(source,directory/target);m['images'].append(target)
        import meeting_documents as docs
        m['documents'], _ = docs.package(path.parent,context.get('documents'),[directory])
        b.atomic(directory/'meeting.json',m)
        b.atomic(directory/'submission.json',dict(file_id=m['plaud_file_id'],job_path=str(path),raw_dir=job.get('raw_dir',''),submitted_at=job.get('updated_at')))

def submit(directory,vault=b.VAULT,client=None):
    directory,m=b.meeting(directory);client=client or Client()
    validate_id(m.get('plaud_file_id'));verify_account(client,m.get('plaud_account_id'))
    with b.lock(directory/'.processing.lock',True):
        if (directory/'submission.json').exists():return b.read(directory/'submission.json')
        include=m.get('include_plaud_summary') is True
        if b.read(directory/'progress.json')['state']!='complete':raise PlaudError('请先同步完整的 Plaud 转写'+('和总结。' if include else '。'))
        queue_module().parse_transcript((directory/'transcript.txt').read_text())
        if include and (not (directory/'plaud-summary.md').exists() or not (directory/'plaud-summary.md').read_text().strip()):raise PlaudError('已选择同时发送总结，请等待总结同步完成。')
        b.validate_context(m)
        images=[]
        for rel in m['images']:
            p=b.local_file(directory,rel)
            if p.stat().st_size>15*1024*1024:raise PlaudError('每张截图不能超过 15 MB。')
            images.append({'base64':base64.b64encode(p.read_bytes()).decode()})
        q=bridge(vault);fid=m['plaud_file_id'];path=q.job_path(fid)
        with q.lock():
            job=q.create_job(dict(fileId=fid,fileName=m['title'],recordingId=None,status='cloud'))
            if job['state'] not in ['ready','processing','done']:
                job.update(is_test=bool(m.get('is_test')),source='Plaud',local_meeting_id=m['id'])
                if m.get('cloud_upload'):
                    job['local_audio_dir']=str(directory)
                    job['capture_mode']=m.get('capture_mode')
                    job['capture_warning']=m.get('capture_warning')
                    try: job['recorded_at']=dt.datetime.fromisoformat(m['created_at'].replace('Z','+00:00')).astimezone(ZoneInfo('America/Los_Angeles')).isoformat()
                    except (ValueError,KeyError): pass
                b.atomic(path,job)
        if job['state'] not in ['ready','processing','done']:
            import meeting_documents as docs
            documents, _ = docs.package(directory,m.get('documents'),[path.parent])
            q.save_context(fid,dict(documents=documents,participants=m.get('participants',''),purpose=m.get('purpose',''),notes=__import__('speaker_notes').context_notes(directory,m.get('notes','')),images=images,include_plaud_summary=include,auto_archive=m.get('auto_archive') is True))
            q.sync_one(fid,force=True)
        attach_existing(directory,m,vault)
        if not (directory/'submission.json').exists():raise PlaudError('归档队列尚未接收，请重试。')
        return b.read(directory/'submission.json')

class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if urllib.parse.urlparse(newurl).scheme!='https':raise PlaudError('音频下载地址不安全。')
        return super().redirect_request(req,fp,code,msg,headers,newurl)

def download_audio(directory,client=None):
    directory,m=b.meeting(directory);client=client or Client();verify_account(client,m.get('plaud_account_id'))
    fid=m.get('plaud_file_id');validate_id(fid)
    with b.lock(directory/'.audio.lock',True):
        target=directory/'plaud-audio.m4a'
        if target.exists() and target.stat().st_size>0:return dict(audio=str(target))
        text=client.run('audio',fid);urls=re.findall(r'^https://\S+\s*$',text,re.M)
        if len(urls)!=1:raise PlaudError('Plaud 暂未提供这条录音的音频，请稍后重试或在原版中回听。')
        # Signed URL stays only in memory and is never logged or written to metadata.
        url=urls[0].strip();parsed=urllib.parse.urlparse(url)
        if parsed.scheme!='https' or not parsed.hostname:raise PlaudError('无效的音频地址。')
        temp=directory/'.plaud-audio.partial'
        try:
            with urllib.request.build_opener(HTTPSRedirect).open(url,timeout=60) as response,temp.open('wb') as out:
                total=0
                while chunk:=response.read(1024*1024):
                    total+=len(chunk)
                    if total>2*1024**3:raise PlaudError('录音超过 2 GB，请在 Plaud 中回听。')
                    out.write(chunk)
            b.duration(temp);os.replace(temp,target);target.chmod(0o600)
        except PlaudError:raise
        except Exception:raise PlaudError('音频下载未完成，请重试；不会影响转写和总结。')
        finally:temp.unlink(missing_ok=True)
        return dict(audio=str(target))

def dispatch(command,args):
    client=Client()
    if command=='plaud-account':
        account=client.account();b.atomic(ACCOUNT_CACHE,account);return dict(account=account)
    if command=='plaud-login':
        account=client.login();b.atomic(ACCOUNT_CACHE,account);return dict(account=account)
    if command=='plaud-list':return list_recordings(args.page,client)
    if command=='plaud-import':return import_recording(args.file_id,args.account_id,client,args.vault)
    if command=='plaud-refresh':return refresh_recording(args.directory,client)
    if command=='plaud-summary':return view_summary(args.directory,client)
    if command=='plaud-audio':return download_audio(args.directory,client)
    raise PlaudError('不支持的 Plaud 操作。')

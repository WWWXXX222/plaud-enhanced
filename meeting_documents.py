"""Bounded, passive document import and immutable evidence packaging. No network."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import urlsplit, urlunsplit

import backend as b

EXTENSIONS = {'pdf', 'docx', 'pptx', 'xlsx', 'md', 'txt', 'csv'}
MAX_FILE = 25 * 1024 * 1024
MAX_TOTAL = 100 * 1024 * 1024
MAX_COUNT = 10
MAX_TEXT = 250_000


def normalize_link(value):
    if not isinstance(value, str): raise ValueError('请输入 http:// 或 https:// 文档链接')
    value = value.strip()
    if not value or len(value) > 4096 or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value) or '\\' in value:
        raise ValueError('链接格式不正确，请粘贴完整的文档地址')
    try:
        url = urlsplit(value)
        if url.scheme.lower() not in {'http', 'https'} or not url.hostname or url.username is not None or url.password is not None:
            raise ValueError()
        _ = url.port
    except ValueError:
        raise ValueError('仅支持不含账号密码的 http:// 或 https:// 文档链接') from None
    return urlunsplit((url.scheme.lower(), url.netloc.lower(), url.path or '/', url.query, url.fragment))


def link_payload(url, name):
    return json.dumps(dict(type='document_link', url=url, name=name), ensure_ascii=False, sort_keys=True, indent=2)+'\n'


def prepare_link(value, directory, name=''):
    url = normalize_link(value)
    name = name.strip() or urlsplit(url).hostname
    if len(name) > 200 or any(ord(c) < 32 for c in name): raise ValueError('链接名称最多 200 字，不能包含换行')
    payload = link_payload(url, name).encode('utf-8')
    digest = hashlib.sha256(payload).hexdigest()
    rel = 'documents/'+digest+'.link.json'
    b.atomic(Path(directory)/rel, payload)
    return dict(path=rel, name=name, size=len(payload), sha256=digest, source_url=url,
                extraction_status='link_pending', note='链接已保存；分析时尝试读取，无法访问会明确标注')


def office_text(path, ext):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        if len(infos) > 5000 or sum(i.file_size for i in infos) > 100 * 1024 * 1024:
            raise ValueError('文档展开后过大，已保留原件供核对')
        required = {'docx':'word/document.xml','pptx':'ppt/presentation.xml','xlsx':'xl/workbook.xml'}[ext]
        if required not in z.namelist(): raise ValueError('文档格式不匹配，已保留原件供核对')
        def xml(name):
            info = z.getinfo(name)
            if info.file_size > 12 * 1024 * 1024: raise ValueError('正文过大，已保留原件供核对')
            data = z.read(info)
            if b'\x00' in data or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper(): raise ValueError('文档含有不支持的 XML 声明或编码')
            return ET.fromstring(data)
        def tag(e): return e.tag.rsplit('}',1)[-1]
        if ext == 'xlsx':
            shared = [''.join(e.itertext()) for e in xml('xl/sharedStrings.xml') if tag(e)=='si'] if 'xl/sharedStrings.xml' in z.namelist() else []
            names = sorted(n for n in z.namelist() if re.fullmatch(r'xl/worksheets/sheet\d+\.xml',n))
            parts = []; count = 0
            for name in names:
                parts.append('\n['+name+']')
                for row in xml(name).iter():
                    if tag(row) != 'row': continue
                    cells = []
                    for c in row:
                        value = next((x.text or '' for x in c if tag(x)=='v'),'')
                        if c.get('t') == 's': value = shared[int(value)] if value.isdigit() and int(value)<len(shared) else '[未识别共享文本]'
                        elif c.get('t') == 'inlineStr': value = ''.join(x.text or '' for x in c.iter() if tag(x)=='t')
                        formula = next((x.text for x in c if tag(x)=='f'),None)
                        cells.append(c.get('r','')+': '+value+(' [公式: '+formula+'；值为文件缓存]' if formula else ''))
                    line = '\t'.join(cells); parts.append(line); count += len(line)
                    if count > MAX_TEXT: return '\n'.join(parts)
            return '\n'.join(parts)
        names = ['word/document.xml'] if ext == 'docx' else sorted((n for n in z.namelist() if re.fullmatch(r'ppt/(slides/slide|notesSlides/notesSlide)\d+\.xml',n)),key=lambda n:(0 if '/slides/' in n else 1,int(re.search(r'(\d+)\.xml$',n)[1])))
        parts = []; count = 0
        for name in names:
            parts.append('\n['+name+']')
            for node in xml(name).iter():
                if tag(node)=='p':
                    line = ''.join(x.text or '' for x in node.iter() if tag(x)=='t'); parts.append(line); count += len(line)
                if count > MAX_TEXT: return '\n'.join(parts)
        return '\n'.join(parts)


def prepare(source, directory, pdf_helper=None):
    source=Path(source); directory=Path(directory)
    ext=source.suffix.lower().lstrip('.')
    if ext not in EXTENSIONS: raise ValueError('支持 PDF、DOCX、PPTX、XLSX、MD、TXT 和 CSV')
    if not source.is_file() or source.is_symlink(): raise ValueError('请选择普通文档文件')
    size=source.stat().st_size
    if not 0 < size <= MAX_FILE: raise ValueError('每份文档须为 25 MB 以内的非空文件')
    digest=b.digest(source); rel='documents/'+digest+'.'+ext; target=directory/rel
    if not target.exists(): b.copy_atomic(source,target)
    if b.digest(target)!=digest: raise ValueError('文档复制后校验失败，请重新添加')
    result=dict(path=rel,name=source.name,size=size,sha256=digest,extraction_status='ready',note='已提取文字；原件随会议保存')
    try:
        if ext=='pdf':
            if target.read_bytes()[:5]!=b'%PDF-': raise ValueError('PDF 格式不匹配')
            if not pdf_helper or not Path(pdf_helper).is_file(): raise ValueError('PDF 文字提取不可用，分析时需读取原件')
            run=subprocess.run([str(pdf_helper),str(target)],capture_output=True,text=True,timeout=25)
            if run.returncode: raise ValueError('PDF 无可提取文字、已加密或无法读取；分析时需核对原件')
            payload=json.loads(run.stdout); text=payload['text']
            if payload.get('truncated'): result.update(extraction_status='partial',note='仅提取部分文字；分析时需核对完整原件')
        elif ext in ('docx','pptx','xlsx'):
            text=office_text(target,ext)
            result['note']='已提取文字；图片、图表与版式需核对原件'
        else:
            data=target.read_bytes()
            try: text=data.decode('utf-8-sig')
            except UnicodeDecodeError:
                try: text=data.decode('utf-16') if data.startswith((b'\xff\xfe',b'\xfe\xff')) else data.decode('gb18030')
                except UnicodeDecodeError: raise ValueError('文字编码无法识别，分析时需核对原件')
            if '\x00' in text: raise ValueError('文件不像纯文本文档，分析时需核对原件')
        if not text.strip(): raise ValueError('未提取到正文，分析时需读取原件')
        if len(text)>MAX_TEXT: result.update(extraction_status='partial',note='正文较长，预提取已截断；分析时需读取完整原件')
        text=text[:MAX_TEXT]
        text_rel='documents/'+digest+'.extracted.txt'
        b.atomic(directory/text_rel,text)
        result.update(text_path=text_rel,text_sha256=b.digest(directory/text_rel))
    except (ValueError,OSError,zipfile.BadZipFile,ET.ParseError,subprocess.TimeoutExpired) as error:
        result.update(extraction_status='original_only',note=str(error) if isinstance(error,ValueError) else '文字提取未完成；原件已保留，分析时需核对')
    return result


def validate(directory, rows):
    rows=rows or []
    if not isinstance(rows,list) or len(rows)>MAX_COUNT: raise ValueError('每场会议最多 10 份文档')
    total=0; seen=set(); seen_links=set()
    for row in rows:
        if not isinstance(row,dict): raise ValueError('文档清单格式错误')
        rel=row.get('path'); p=b.local_file(Path(directory),rel)
        if not rel.startswith('documents/'): raise ValueError('文档路径或格式错误')
        if row.get('source_url') is not None:
            url=normalize_link(row['source_url']); name=row.get('name')
            if not isinstance(name,str) or not name.strip() or len(name)>200 or any(ord(c)<32 for c in name): raise ValueError('链接名称无效')
            if url!=row['source_url'] or url in seen_links: raise ValueError('链接清单无效或重复')
            seen_links.add(url)
            if not rel.endswith('.link.json') or p.stat().st_size>32768 or p.read_text()!=link_payload(url,name): raise ValueError('链接原件与清单不一致')
            if row.get('text_path') or row.get('extraction_status')!='link_pending': raise ValueError('链接引用不能冒充已提取的文档正文')
        elif p.suffix[1:].lower() not in EXTENSIONS: raise ValueError('文档路径或格式错误')
        size=p.stat().st_size; total+=size
        if not 0<size<=MAX_FILE or size!=row.get('size') or b.digest(p)!=row.get('sha256'): raise ValueError('附件原件校验失败：'+str(row.get('name','文档')))
        if row['sha256'] in seen: raise ValueError('文档清单有重复项')
        seen.add(row['sha256'])
        if row.get('text_path'):
            text=b.local_file(Path(directory),row['text_path'])
            if not row['text_path'].startswith('documents/') or text.stat().st_size>MAX_TEXT*4 or b.digest(text)!=row.get('text_sha256'): raise ValueError('附件文字校验失败')
    if total>MAX_TOTAL: raise ValueError('每场会议的文档总大小不能超过 100 MB')
    return rows


def package(directory, rows, destinations):
    rows=validate(directory,rows); hashes={}
    for row in rows:
        for key,hashkey in [('path','sha256'),('text_path','text_sha256')]:
            if not row.get(key): continue
            rel=row[key]
            for dest in destinations: b.copy_atomic(b.local_file(Path(directory),rel),Path(dest)/rel)
            hashes[rel]=row[hashkey]
    return rows,hashes

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('source');parser.add_argument('directory',type=Path);parser.add_argument('--pdf-helper');parser.add_argument('--link',action='store_true');parser.add_argument('--name',default='')
    args=parser.parse_args()
    try: print(json.dumps(prepare_link(args.source,args.directory,args.name) if args.link else prepare(args.source,args.directory,args.pdf_helper),ensure_ascii=False))
    except (ValueError,OSError) as error: print(json.dumps({'error':str(error)},ensure_ascii=False));sys.exit(1)

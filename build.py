#!/usr/bin/env python3
import pathlib,plistlib,subprocess,shutil,json,hashlib,sys,os
from app_signing import sign_bundle
ROOT=pathlib.Path(__file__).resolve().parent
APP=ROOT/'build/Plaud威力加强版.app'
CONTENTS=APP/'Contents';MACOS=CONTENTS/'MacOS';RES=CONTENTS/'Resources'
MACOS.mkdir(parents=True,exist_ok=True);RES.mkdir(exist_ok=True)
info={'CFBundleExecutable':'MeetingMemory','CFBundleIdentifier':'com.local.meetingmemory.mac',
      'CFBundleName':'Plaud威力加强版','CFBundleDisplayName':'Plaud威力加强版','CFBundlePackageType':'APPL',
      'CFBundleShortVersionString':'0.11.0','CFBundleVersion':'52','LSMinimumSystemVersion':'15.0',
      'CFBundleIconFile':'AppIcon.icns',
      'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication',
      'NSMicrophoneUsageDescription':'Plaud威力加强版需要麦克风来录制你的会议发言。录音保存在本机，录完按你的设置自动转写与分析；上传 Plaud 为可选项。',
      'NSScreenCaptureUsageDescription':'Plaud威力加强版使用系统音频录制能力收录电脑会议声音；不保存屏幕录像。',
      'NSAudioCaptureUsageDescription':'Plaud威力加强版需要收录电脑会议声音，与麦克风录音一起生成会议逐字稿。'}
if '--development-root' in sys.argv: info['MeetingProjectRoot'] = str(ROOT)
with (CONTENTS/'Info.plist').open('wb') as f:plistlib.dump(info,f)
shutil.copyfile(ROOT/'plaud_web_adapter.js', RES/'plaud_web_adapter.js')
cache=ROOT/'build/module-cache';cache.mkdir(exist_ok=True)
subprocess.run(['/usr/bin/swiftc','-O','-module-cache-path',str(cache),str(ROOT/'tools/extract_document_pdf.swift'),
                '-o',str(RES/'MeetingDocumentText'),'-framework','PDFKit'],check=True)
icons=ROOT/'assets/AppIcon.iconset'; icons.mkdir(parents=True, exist_ok=True)
subprocess.run(['/usr/bin/swift','-module-cache-path',str(cache),str(ROOT/'tools/render_icon.swift'),str(icons)],check=True)
subprocess.run(['/usr/bin/iconutil','-c','icns',str(icons),'-o',str(RES/'AppIcon.icns')],check=True)
shutil.copyfile(icons/'icon_256x256.png', RES/'AppIconPreview.png')
subprocess.run(['/usr/bin/swift','build','--package-path',str(ROOT/'offline-worker'),'-c','release',
                '--arch','arm64','--jobs','3','--product','OfflineSpeechWorker'],check=True)
worker=ROOT/'offline-worker/.build/arm64-apple-macosx/release/OfflineSpeechWorker'
if subprocess.check_output(['/usr/bin/lipo','-archs',str(worker)],text=True).strip()!='arm64':
    raise RuntimeError('离线字幕进程必须原生运行在 Apple Silicon；停止构建。')
shutil.copy2(worker, RES/'OfflineSpeechWorker')
model=ROOT/'offline-worker/models/whisper'
manifest=json.loads((model/'manifest.json').read_text())
for entry in manifest['files']:
    data=(model/entry['path']).read_bytes()
    if len(data)!=entry['size'] or hashlib.sha256(data).hexdigest()!=entry['sha256']:
        raise RuntimeError('离线模型校验失败；停止构建。')
shutil.copytree(model, RES/'OfflineSpeechModel', dirs_exist_ok=True)
shutil.copyfile(ROOT/'offline-worker/Vendor/argmax-oss-swift/LICENSE', RES/'WhisperKit-LICENSE')
shutil.copyfile(ROOT/'assets/Whisper-LICENSE', RES/'Whisper-LICENSE')
subprocess.run(['/usr/bin/swiftc','-swift-version','5','-O','-whole-module-optimization','-num-threads','4','-parse-as-library','-target','arm64-apple-macosx15.0',
                '-module-cache-path',str(cache),*[str(p) for p in sorted((ROOT/'Sources').glob('*.swift'))],
                '-o',str(MACOS/'MeetingMemory'),'-framework','SwiftUI','-framework','AppKit','-framework','AVFoundation',
                '-framework','CoreAudio','-framework','CoreMedia','-framework','WebKit','-framework','Security','-framework','LocalAuthentication'],check=True)
runtime = RES/'Runtime'
if runtime.exists(): shutil.rmtree(runtime)
runtime.mkdir()
files = [p for p in ROOT.glob('*.py') if p.name not in ('build.py','install.py','app_signing.py')]
files += [ROOT/'WORKFLOW.md', *sorted((ROOT/'skills').rglob('*.md'))]
for path in files:
    target = runtime/path.relative_to(ROOT); target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, target)
(runtime/'runtime-files.json').write_text(json.dumps([str(p.relative_to(ROOT)) for p in files]))
if '--ad-hoc' in sys.argv:
    if '--development-root' in sys.argv: raise RuntimeError('Development updates require stable signing.')
    for helper in ['OfflineSpeechWorker', 'MeetingDocumentText']:
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(RES/helper)], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(APP)], check=True)
else:
    sign_bundle(APP, ROOT)
print(APP)

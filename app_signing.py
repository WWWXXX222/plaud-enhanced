"""Keep release identity stable so macOS can recognize upgrades of this app."""
from contextlib import contextmanager
import fcntl
import json
from pathlib import Path
import re
import subprocess


def select_identity(pinned=None):
    result = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                            capture_output=True, text=True, check=True)
    identities = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "', result.stdout, re.M)
    if pinned and pinned in identities:
        return pinned
    if not pinned and len(identities) == 1:
        return identities[0]
    raise RuntimeError('缺少已固定的签名证书，或存在多个未选择的证书；停止构建，不能退回临时签名。')


def requirement(app):
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)],
                            capture_output=True, text=True, check=True)
    match = re.search(r'^(?:#\s*)?designated => (.+)$', result.stdout+'\n'+result.stderr, re.M)
    if not match:
        raise RuntimeError('无法验证应用的签名身份。')
    return match.group(1)


def verify_update(source, prior=None):
    new = requirement(source)
    if 'cdhash ' in new or 'anchor apple' not in new:
        raise RuntimeError('正式版必须使用固定 Apple 签名证书，不能安装临时签名版本。')
    if prior:
        old = requirement(prior)
        # Only the legacy ad-hoc release needs a one-time identity migration.
        if not old.startswith('cdhash ') and old != new:
            raise RuntimeError('新版签名身份与已安装版本不同；停止更新以保留已有系统授权。')
    return new


def sign_bundle(app, root):
    app, root = Path(app), Path(root)
    pin_file = root/'build/signing-identity.json'
    pinned = json.loads(pin_file.read_text())['identity'] if pin_file.exists() else None
    identity = select_identity(pinned)
    helper = app/'Contents/Resources/MeetingDocumentText'
    if helper.exists():
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--identifier',
                        'com.local.meetingmemory.documenttext', str(helper)], check=True)
    offline = app/'Contents/Resources/OfflineSpeechWorker'
    if offline.exists():
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--identifier',
                        'com.local.meetingmemory.offlinespeech', str(offline)], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    new = verify_update(app)
    pin_file.parent.mkdir(parents=True, exist_ok=True)
    # Public certificate fingerprint only. No key material is exported.
    pin_file.write_text(json.dumps({'identity': identity, 'requirement': new}, indent=2)+'\n')
    return new


def require_quiet(root, apps):
    root = Path(root)
    result = subprocess.run(['/bin/ps', '-axo', 'comm='], capture_output=True, text=True, check=True)
    processes = {line.strip() for line in result.stdout.splitlines()}
    if any(str(Path(app)/'Contents/MacOS/MeetingMemory') in processes for app in apps):
        raise RuntimeError('旧版 App 或恢复进程仍在运行；请正常退出后再安装，避免旧版身份继续请求文件授权。')
    for path in (root/'data/meetings').glob('*/meeting.json'):
        if json.loads(path.read_text()).get('capture_state') == 'recording':
            raise RuntimeError('还有录音未保存，停止安装以保护会议内容。')


@contextmanager
def installation_window(root, apps):
    """Do not relocate a bundle while its background workers still own data."""
    root = Path(root)
    require_quiet(root, apps)
    paths = [root/'.storage.lock', root/'runtime/archive/worker.lock', *(root/'data/meetings').glob('*/.processing.lock')]
    handles = []
    try:
        for path in paths:
            if not path.exists():
                continue
            handle = path.open('r+'); handles.append(handle)
            try:
                fcntl.flock(handle, fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('后台仍在转写或归档，请等待完成后安装；不会终止或重复启动任务。') from None
        yield
    finally:
        for handle in handles:
            handle.close()

"""Per-user configuration. No account data or developer paths ship with the app."""
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent

def settings(root=ROOT):
    try: return json.loads((Path(root)/'settings.json').read_text())
    except FileNotFoundError: return {}

def vault_path(root=ROOT):
    return Path(settings(root).get('vault_path') or Path(root)/'Vault').expanduser().resolve()

def executable(name):
    configured = settings().get(name+'_path')
    candidates = [configured, shutil.which(name), str(Path.home()/'.local/bin'/name),
                  '/opt/homebrew/bin/'+name, '/usr/local/bin/'+name, '/usr/bin/'+name]
    if name == 'codex':
        candidates += ['/Applications/Codex.app/Contents/Resources/codex',
                       '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex']
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK): return Path(candidate)
    raise ValueError(f'尚未安装 {name}，请在首次设置中检查依赖。')

def bridge_root():
    return Path(settings().get('bridge_root') or ROOT)

def resource(name):
    base = os.environ.get('MEETING_RESOURCES')
    if base and (Path(base)/name).exists(): return Path(base)/name
    path = ROOT/'build/Plaud威力加强版.app/Contents/Resources'/name
    if path.exists(): return path
    raise ValueError('离线模型或辅助程序缺失，请重新安装完整 App。')

def workflow(): return Path(settings().get('workflow_path') or ROOT/'WORKFLOW.md')

def memory_skill(): return Path(settings().get('memory_skill_path') or ROOT/'skills/meeting-memory/SKILL.md')

"""Install the local, model-free recovery check. Does not change Codex schedules."""
from pathlib import Path
import os
import plistlib
import subprocess
import backend as b

LABEL = 'com.local.meetingmemory.archive-recovery'

def configuration(root=b.ROOT):
    root = Path(root).resolve()
    native = Path(os.environ.get('MEETING_APP_PATH', str(Path.home()/'Applications/Plaud威力加强版.app')))/'Contents/MacOS/MeetingMemory'
    return dict(Label=LABEL, ProgramArguments=[str(native), '--archive-recover-only'],
                RunAtLoad=True, StartInterval=1800,
                ProcessType='Background', StandardOutPath=str(root/'runtime/archive/recovery.log'),
                StandardErrorPath=str(root/'runtime/archive/recovery.log'))

def install():
    (b.ROOT/'runtime/archive').mkdir(parents=True, exist_ok=True)
    path = Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    path.parent.mkdir(parents=True, exist_ok=True)
    data = plistlib.dumps(configuration())
    if path.exists() and path.read_bytes() == data:
        probe=subprocess.run(['/bin/launchctl','print',f'gui/{os.getuid()}/{LABEL}'],capture_output=True)
        if probe.returncode == 0: return path
    subprocess.run(['/bin/launchctl','bootout',f'gui/{os.getuid()}',str(path)],capture_output=True)
    b.atomic(path, data)
    subprocess.run(['/bin/launchctl','bootstrap',f'gui/{os.getuid()}',str(path)],check=True)
    return path

if __name__ == '__main__': print(install())

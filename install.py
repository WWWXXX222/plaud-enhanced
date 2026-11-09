#!/usr/bin/env python3
"""Install a complete verified bundle; avoid overwriting a cached executable inode."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid
import os
from app_signing import installation_window, require_quiet, verify_update

ROOT = Path(__file__).resolve().parent
NAME = 'Plaud威力加强版.app'
IDENTIFIER = 'com.local.meetingmemory.mac'
source = ROOT / 'build' / NAME
target = Path.home() / 'Applications' / NAME
legacy = target.with_name('会记.app')
key = uuid.uuid4().hex[:8]
staging = target.with_name('.plaud-update-' + key + '.app')
backup = ROOT / 'build' / ('previous-install-' + key)

assert plistlib.loads((source / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == IDENTIFIER
prior = target if target.exists() else legacy if legacy.exists() else None
if prior:
    assert plistlib.loads((prior / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == IDENTIFIER
verify_update(source, prior)
with installation_window(ROOT, [target, legacy]):
    shutil.copytree(source, staging)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staging)], check=True)
    # Copying can take time. Recheck before changing the installed path.
    require_quiet(ROOT, [target, legacy])
    if prior:
        prior.rename(backup)
    try:
        staging.rename(target)
    except Exception:
        if prior:
            backup.rename(prior)
        raise
# Announce this replacement bundle to Launch Services without clearing global icon caches.
os.utime(target, None)
registrar = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
if registrar.exists():
    subprocess.run([str(registrar), '-f', str(target)], check=True)
print(target)

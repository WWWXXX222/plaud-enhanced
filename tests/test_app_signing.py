import fcntl
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import app_signing as signing


class SigningTests(unittest.TestCase):
    def test_reads_synthesized_and_explicit_requirements(self):
        for text in ['# designated => cdhash H"1234"', 'designated => identifier "app" and anchor apple generic']:
            with patch.object(signing.subprocess, 'run', return_value=Mock(stdout=text, stderr='Executable=/test')):
                self.assertEqual(signing.requirement('app'), text.split(' => ')[1])

    def test_release_build_never_uses_ad_hoc_identity(self):
        source = (Path(__file__).resolve().parents[1]/'build.py').read_text()
        self.assertNotIn("'--sign','-'", source)
        self.assertIn('sign_bundle', source)

    def test_identity_selection_is_pinned_and_fails_closed(self):
        a, b = 'A'*40, 'B'*40
        identities = f'  1) {a} "Apple Development: A"\n  2) {b} "Apple Development: B"'
        with patch.object(signing.subprocess, 'run', return_value=Mock(stdout=identities)):
            self.assertEqual(signing.select_identity(a), a)
            for pin in [None, '-', 'C'*40]:
                with self.assertRaises(RuntimeError): signing.select_identity(pin)
        with patch.object(signing.subprocess, 'run', return_value=Mock(stdout='0 valid identities found')):
            with self.assertRaises(RuntimeError): signing.select_identity()

    def test_upgrade_rejects_ad_hoc_and_changed_identity(self):
        stable = 'identifier "com.local.meetingmemory.mac" and anchor apple generic and certificate leaf[subject.OU] = TEAM'
        with patch.object(signing, 'requirement', side_effect=[stable, stable]):
            signing.verify_update(Path('new'), Path('old'))
        with patch.object(signing, 'requirement', side_effect=[stable, 'cdhash H"0123"']):
            signing.verify_update(Path('new'), Path('old'))  # one migration from the old build
        with patch.object(signing, 'requirement', return_value='cdhash H"0123"'):
            with self.assertRaises(RuntimeError): signing.verify_update(Path('new'), None)
        with patch.object(signing, 'requirement', side_effect=[stable, stable+' and certificate leaf = OLD']):
            with self.assertRaises(RuntimeError): signing.verify_update(Path('new'), Path('old'))

    def test_running_app_or_recording_prevents_replacing_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); app = root/'Plaud.app'
            with patch.object(signing.subprocess, 'run', return_value=Mock(stdout=str(app/'Contents/MacOS/MeetingMemory')+'\n')):
                with self.assertRaises(RuntimeError): signing.require_quiet(root, [app])
            folder=root/'data/meetings/mm_test'; folder.mkdir(parents=True)
            (folder/'meeting.json').write_text(json.dumps({'capture_state':'recording'}))
            with patch.object(signing.subprocess, 'run', return_value=Mock(stdout='')):
                with self.assertRaises(RuntimeError): signing.require_quiet(root, [app])

    def test_live_worker_lease_prevents_install_and_unlocks_afterwards(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); runtime=root/'runtime/archive'; runtime.mkdir(parents=True)
            lock=runtime/'worker.lock'; lock.touch()
            with patch.object(signing, 'require_quiet'):
                with lock.open('r+') as owner:
                    fcntl.flock(owner, fcntl.LOCK_EX|fcntl.LOCK_NB)
                    with self.assertRaises(RuntimeError):
                        with signing.installation_window(root, []): self.fail('active worker accepted')
                with signing.installation_window(root, []):
                    with lock.open('r+') as contender:
                        with self.assertRaises(BlockingIOError): fcntl.flock(contender, fcntl.LOCK_EX|fcntl.LOCK_NB)
                with lock.open('r+') as contender:
                    fcntl.flock(contender, fcntl.LOCK_EX|fcntl.LOCK_NB)


if __name__ == '__main__': unittest.main()

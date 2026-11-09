import array
import cmath
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
import wave
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import backend as b
from prepare_upload import prepare

class UploadAudioTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.directory=Path(self.temp.name)/('mm_'+str(uuid.uuid4()))
        self.directory.mkdir();self.m=dict(id=self.directory.name,capture_state='captured',audio_files=['mic.wav','system.wav'])
        b.atomic(self.directory/'meeting.json',self.m)
        for name,hz in [('mic.wav',500),('system.wav',900)]:
            with wave.open(str(self.directory/name),'wb') as w:
                w.setparams((1,2,16000,0,'NONE','not compressed'))
                w.writeframes(array.array('h',[int(4000*math.sin(2*math.pi*hz*i/16000)) for i in range(64000)]).tobytes())
    def tearDown(self):self.temp.cleanup()
    def test_both_sources_survive_cloud_mix_and_retry_reuses_audio(self):
        prepared=prepare(self.directory)['prepared'];target=self.directory/prepared['filename']
        self.assertAlmostEqual(prepared['duration'],4,delta=.1)
        before=target.stat().st_mtime_ns;self.assertEqual(prepare(self.directory)['prepared'],prepared);self.assertEqual(target.stat().st_mtime_ns,before)
        raw=subprocess.check_output([str(b.FFMPEG),'-v','error','-i',str(target),'-t','1','-f','s16le','-ar','16000','-ac','1','-'])
        samples=array.array('h',raw)
        amplitudes={hz:abs(sum(v*cmath.exp(-2j*math.pi*hz*i/16000) for i,v in enumerate(samples)))/len(samples) for hz in [500,900,1400]}
        self.assertGreater(amplitudes[500],500);self.assertGreater(amplitudes[900],500)
        self.assertLess(amplitudes[1400],amplitudes[500]/10)
        self.assertFalse((self.directory/'transcript.json').exists())
    def test_recording_or_already_archived_is_never_uploaded(self):
        self.m['capture_state']='recording';b.atomic(self.directory/'meeting.json',self.m)
        with self.assertRaises(ValueError):prepare(self.directory)
        self.m['capture_state']='captured';b.atomic(self.directory/'meeting.json',self.m);b.atomic(self.directory/'submission.json',{})
        with self.assertRaises(ValueError):prepare(self.directory)
    def test_missing_track_stops_instead_of_silently_uploading_one_source(self):
        (self.directory/'system.wav').unlink()
        with self.assertRaises(ValueError):prepare(self.directory)
        self.assertFalse((self.directory/'plaud-upload.mp3').exists())

if __name__=='__main__':unittest.main()

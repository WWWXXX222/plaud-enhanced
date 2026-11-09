"""Build-time public model download. Never called by the recording app."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'offline-worker/models/whisper'
REPO = 'argmaxinc/whisperkit-coreml'
REV = '0f63a7800b00dd0226abd051b906c246e1907482'
VARIANT = 'openai_whisper-large-v3-v20240930_626MB'

def get_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)

def main():
    DEST.mkdir(parents=True, exist_ok=True)
    meta = get_json(f'https://huggingface.co/api/models/{REPO}/revision/{REV}?blobs=true')
    tokenizer = get_json('https://huggingface.co/api/models/openai/whisper-large-v3/revision/main?blobs=true')
    files = [(REPO, REV, f, f['rfilename'][len(VARIANT)+1:]) for f in meta['siblings']
             if f['rfilename'].startswith(VARIANT+'/')]
    files += [('openai/whisper-large-v3', tokenizer['sha'], f, f['rfilename'])
              for f in tokenizer['siblings'] if f['rfilename'] in
              ('tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json', 'added_tokens.json')]
    def download(item):
        repo, revision, info, relative = item
        path = DEST/relative
        expected = info.get('lfs', {}).get('sha256')
        def valid():
            return path.is_file() and path.stat().st_size == info['size'] and (
                not expected or hashlib.sha256(path.read_bytes()).hexdigest() == expected)
        if not valid():
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name+'.download')
            subprocess.run(['/usr/bin/curl', '--fail', '--location', '--retry', '4', '--retry-all-errors',
                '--connect-timeout', '20', '--max-time', '900', '--continue-at', '-', '--silent', '--show-error',
                '--output', str(temporary), f'https://huggingface.co/{repo}/resolve/{revision}/{info["rfilename"]}'], check=True)
            temporary.replace(path)
            if not valid(): raise RuntimeError(f'Model integrity check failed: {relative}')
        print('verified', relative, path.stat().st_size, flush=True)
        return {'path': relative, 'size': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        verified = list(pool.map(download, files))
    (DEST/'manifest.json').write_text(json.dumps({'model': VARIANT, 'repo': REPO, 'revision': REV,
        'tokenizer_revision': tokenizer['sha'], 'files': verified}, indent=2)+'\n')
    print('READY', sum(f['size'] for f in verified), flush=True)

if __name__ == '__main__': main()

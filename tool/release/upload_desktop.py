"""Attaches the desktop packages of a finished desktop-release.yml run to a
release (what the workflow's publish job does), and rewrites SHA256SUMS.txt.

Usage: python upload_desktop.py OWNER/REPO RUN_ID TAG WORK_DIR
Uses the github.com credential git already has; never prints it.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

repo, run_id, tag, work = sys.argv[1:]
out = subprocess.run(
    ['git', 'credential', 'fill'], input='protocol=https\nhost=github.com\n\n',
    capture_output=True, text=True, timeout=30,
    env={**os.environ, 'GCM_INTERACTIVE': 'never', 'GIT_TERMINAL_PROMPT': '0'},
).stdout
TOKEN = dict(l.split('=', 1) for l in out.splitlines() if '=' in l)['password']
api = f'https://api.github.com/repos/{repo}'


def call(method, url, body=None, content_type='application/json', timeout=60, auth=True):
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'release-script'}
    if auth:
        headers['Authorization'] = f'Bearer {TOKEN}'
    if data is not None:
        headers['Content-Type'] = content_type
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method,
                                                               headers=headers), timeout=timeout) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw and 'json' in r.headers.get('Content-Type', '') else raw)
        except urllib.error.HTTPError as e:
            if e.code < 500:
                return e.code, e.read().decode(errors='replace')[:400]
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            print(f'  retry {attempt + 1}: {e}')
        time.sleep(5 * (attempt + 1))
    raise SystemExit(f'{method} {url} kept failing')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def download_artifact(art, dest):
    req = urllib.request.Request(art['archive_download_url'], headers={
        'Authorization': f'Bearer {TOKEN}', 'User-Agent': 'release-script'})
    try:
        urllib.request.build_opener(NoRedirect).open(req, timeout=60)
        raise SystemExit('expected a redirect')
    except urllib.error.HTTPError as e:
        location = e.headers['Location']
    status, data = call('GET', location, timeout=900, auth=False)
    with open(dest, 'wb') as f:
        f.write(data)


# 1. The packages from the run.
dist = os.path.join(work, 'dist')
os.makedirs(dist, exist_ok=True)
status, arts = call('GET', f'{api}/actions/runs/{run_id}/artifacts?per_page=100')
for art in arts['artifacts']:
    if not art['name'].startswith('packages-'):
        continue
    zpath = os.path.join(work, art['name'] + '.zip')
    if not (os.path.exists(zpath) and zipfile.is_zipfile(zpath)):
        print('downloading', art['name'], f"({art['size_in_bytes'] / 1e6:.0f} MB)")
        download_artifact(art, zpath)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(dist)
files = sorted(os.listdir(dist))
print('packages:', *files, sep='\n  ')

# 2. Upload, replacing assets of the same name and the old Windows zip.
status, release = call('GET', f'{api}/releases/tags/{urllib.parse.quote(tag)}')
if status != 200:
    raise SystemExit(f'no release {tag}: {release}')
existing = {a['name']: a for a in release['assets']}
upload_base = release['upload_url'].split('{')[0]


def upload(path, name):
    if name in existing:
        call('DELETE', f"{api}/releases/assets/{existing[name]['id']}")
    with open(path, 'rb') as f:
        data = f.read()
    status, asset = call('POST', f'{upload_base}?name={urllib.parse.quote(name)}', data,
                         content_type='application/octet-stream', timeout=1800)
    print(('  uploaded' if status == 201 else f'  FAILED ({status}) {asset}'), name,
          f'({len(data) / 1e6:.1f} MB)')
    return status == 201


ok = all([upload(os.path.join(dist, n), n) for n in files])
for name, a in existing.items():
    if name.endswith('-windows-x64.zip'):
        call('DELETE', f"{api}/releases/assets/{a['id']}")
        print('  removed', name)

# 3. SHA256SUMS.txt: the APKs' lines, then every desktop package.
lines = []
if 'SHA256SUMS.txt' in existing:
    status, old = call('GET', existing['SHA256SUMS.txt']['browser_download_url'], timeout=60, auth=False)
    lines = [l for l in old.decode().splitlines() if l.rstrip().endswith('.apk')]
for n in files:
    lines.append(f'{hashlib.sha256(open(os.path.join(dist, n), "rb").read()).hexdigest()}  {n}')
sums = os.path.join(work, 'SHA256SUMS.txt')
with open(sums, 'w', newline='\n') as f:
    f.write('\n'.join(lines) + '\n')
ok &= upload(sums, 'SHA256SUMS.txt')
print('done' if ok else 'SOME UPLOADS FAILED', release['html_url'])

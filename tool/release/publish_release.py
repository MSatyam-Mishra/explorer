"""Creates a GitHub release for an existing pushed tag and uploads assets.

Usage: python publish_release.py OWNER/REPO TAG TITLE NOTES_FILE ASSET...
Uses the github.com credential git already has; never prints it.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

repo, tag, title, notes_file, *assets = sys.argv[1:]


def token():
    out = subprocess.run(
        ['git', 'credential', 'fill'],
        input='protocol=https\nhost=github.com\n\n',
        capture_output=True, text=True, timeout=30,
        env={**os.environ, 'GCM_INTERACTIVE': 'never', 'GIT_TERMINAL_PROMPT': '0'},
    ).stdout
    fields = dict(line.split('=', 1) for line in out.splitlines() if '=' in line)
    if not fields.get('password'):
        raise SystemExit('no GitHub credential available')
    return fields['password']


TOKEN = token()


def call(method, url, body=None, content_type='application/json', timeout=60):
    data = body
    if isinstance(body, (dict, list)):
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': f'Bearer {TOKEN}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'release-script',
        **({'Content-Type': content_type} if data is not None else {}),
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors='replace')[:400]
        return e.code, {'error': detail}


api = f'https://api.github.com/repos/{repo}'
status, existing = call('GET', f'{api}/releases/tags/{urllib.parse.quote(tag)}')
if status == 200:
    raise SystemExit(f'release for {tag} already exists: {existing["html_url"]}')

with open(notes_file, encoding='utf-8') as f:
    notes = f.read()
status, release = call('POST', f'{api}/releases', {
    'tag_name': tag,
    'name': title,
    'body': notes,
    'draft': False,
    'prerelease': True,
})
if status != 201:
    raise SystemExit(f'creating the release failed ({status}): {release}')
print('release:', release['html_url'])

upload_base = release['upload_url'].split('{')[0]
for path in assets:
    name = os.path.basename(path)
    ctype = ('application/vnd.android.package-archive' if name.endswith('.apk')
             else 'application/zip' if name.endswith('.zip') else 'text/plain')
    with open(path, 'rb') as f:
        data = f.read()
    status, asset = call('POST', f'{upload_base}?name={urllib.parse.quote(name)}',
                         data, content_type=ctype, timeout=900)
    if status != 201:
        print(f'  FAILED {name} ({status}): {asset}')
    else:
        print(f'  uploaded {name} ({len(data) / 1e6:.1f} MB)')

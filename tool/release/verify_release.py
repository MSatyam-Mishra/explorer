"""Checks a published release without logging in: every asset is public,
uploaded, and byte-identical (SHA-256) to the local file.

Usage: python verify_release.py OWNER/REPO TAG ASSETS_DIR
"""
import hashlib
import json
import os
import sys
import urllib.request

repo, tag, assets_dir = sys.argv[1:]
headers = {'User-Agent': 'release-verify', 'Accept': 'application/vnd.github+json'}


def get(url, timeout=60):
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout)


with get(f'https://api.github.com/repos/{repo}/releases/tags/{tag}') as r:
    release = json.load(r)
print(release['html_url'], '| prerelease:', release['prerelease'], '| draft:', release['draft'])

ok = True
for asset in release['assets']:
    name = asset['name']
    digest = hashlib.sha256()
    with get(asset['browser_download_url'], timeout=900) as r:
        while chunk := r.read(1 << 20):
            digest.update(chunk)
    remote = digest.hexdigest()
    local_path = os.path.join(assets_dir, name)
    local = hashlib.sha256(open(local_path, 'rb').read()).hexdigest() if os.path.exists(local_path) else None
    same = remote == local
    ok &= same and asset['state'] == 'uploaded'
    print(f'{name:36} {asset["state"]:9} {asset["size"]:>10}  {"matches local" if same else "DIFFERS"}  sha256:{remote}')
print('all assets verified' if ok else 'PROBLEMS FOUND')

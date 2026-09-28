#!/usr/bin/env python3
"""Explicit test-package installation; never treats an unchanged version as success."""
import argparse
import json
import time
import urllib.request
from pathlib import Path
from mcp_ocr_engines_test import Client, payload

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', required=True)
    parser.add_argument('deb')
    args = parser.parse_args()
    base = args.url.removesuffix('/mcp').rstrip('/')
    c = Client(base + '/mcp')
    for _ in range(2):
        c.call('press_home')
        time.sleep(1)
    assert not payload(c.call('get_screen_info'))['locked'], 'Unlock before installation'
    previous_pid = payload(c.call('get_frontmost_app')).get('pid')
    path = Path(args.deb)
    request = urllib.request.Request(base + '/upload_file', data=path.read_bytes(),
                                    headers={'X-Filename': path.name})
    uploaded = json.load(urllib.request.urlopen(request, timeout=60))
    response = c.call('install_deb', {'path': uploaded['path']})
    assert 'error' not in response and not response.get('result', {}).get('isError'), response
    print('Install response:', response, flush=True)
    # install_deb replies BEFORE its delayed respring. The old process may still
    # return /health and tools/list briefly, especially for same-version test builds.
    time.sleep(8)
    for _ in range(40):
        try:
            c = Client(base + '/mcp')
            tools = c.raw('tools/list', {})['result']['tools']
            assert 'engine' in next(t for t in tools if t['name'] == 'ocr_screen')['inputSchema']['properties']
            c.call('press_home'); time.sleep(1); c.call('press_home'); time.sleep(1)
            current_pid = payload(c.call('get_frontmost_app')).get('pid')
            assert previous_pid and current_pid and current_pid != previous_pid, 'Waiting for a new SpringBoard process'
            print('PASS server recovered; OCR engine schema is installed', flush=True)
            return
        except Exception:
            time.sleep(1)
    raise RuntimeError('Server did not recover')

if __name__ == '__main__':
    main()

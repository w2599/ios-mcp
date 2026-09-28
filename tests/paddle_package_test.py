#!/usr/bin/env python3
"""Audit all three actual deb archives, not just the staging directory."""
import argparse
import hashlib
import io
import json
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--version', default='1.2.8')
    p.add_argument('--arch', action='append', choices=['arm', 'arm64', 'arm64e'],
                   help='Audit selected package(s); defaults to all three')
    p.add_argument('--out', default='.codex-session-data/paddle-build/package-audit.json')
    a = p.parse_args()
    reports = []
    for arch, prefix in [('arm',''),('arm64','var/jb/'),('arm64e','')]:
        if a.arch and arch not in a.arch:
            continue
        path = ROOT/'packages'/('com.witchan.ios-mcp_%s_iphoneos-%s.deb' % (a.version,arch))
        members = subprocess.check_output(['ar','t',str(path)],text=True).splitlines()
        member = next(m.strip() for m in members if m.startswith('data.tar'))
        archive = subprocess.check_output(['ar','p',str(path),member])
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            files = {m.name.removeprefix('./'):tar.extractfile(m).read() for m in tar if m.isfile()}
        removed_helpers = ('mcp-appsync', 'mcp-appinst', 'mcp-roothelper', 'mcp-ldid')
        assert not any(any(part in name for part in removed_helpers) for name in files), 'Obsolete IPA helper in package'
        resource = prefix+'usr/share/ios-mcp/paddleocr/'
        hashes = json.loads(files[resource+'sha256.json'])
        for model in ['det.onnx','rec.onnx','dictionary.json']:
            assert hashlib.sha256(files[resource+model]).hexdigest() == hashes[model], (arch,model)
        for license in ['LICENSE-ONNXRuntime','LICENSE-PaddleOCR','LICENSE-OpenCV','LICENSE-Clipper',
                        'LICENSE-Eigen','LICENSE-OpenCV-ThirdParty.txt','ONNXRuntime-ThirdPartyNotices.txt','dependencies.lock.json']:
            assert files[prefix+'usr/share/doc/ios-mcp/paddleocr/'+license], (arch,license)
        binaries = {}
        assert not any(name.endswith('/libonnxruntime.dylib') for name in files), 'Do not ship a separate ORT dylib'
        with tempfile.TemporaryDirectory(prefix='mcp-deb-audit-') as temporary:
            for name in ['mcp-ocr-worker']:
                extracted = Path(temporary)/name
                extracted.write_bytes(files[prefix+'usr/libexec/ios-mcp/'+name])
                assert subprocess.check_output(['lipo','-archs',str(extracted)],text=True).strip() == 'arm64'
                build = subprocess.check_output(['xcrun','vtool','-show-build',str(extracted)],text=True)
                assert re.search(r'minos\s+13\.0\b',build), build
                links = subprocess.check_output(['otool','-L',str(extracted)],text=True)
                assert not re.search('Vision|CoreML|Metal|Neural',links), links
                assert 'onnxruntime' not in links, 'Worker must statically link ORT: ' + links
                binaries[name] = {'build':build,'links':links}
            tweak = Path(temporary)/'ios-mcp.dylib'
            tweak.write_bytes(files[prefix+'Library/MobileSubstrate/DynamicLibraries/ios-mcp.dylib'])
            links = subprocess.check_output(['otool','-L',str(tweak)],text=True)
            assert 'onnxruntime' not in links and 'opencv' not in links, links
        reports.append({'package':path.name,'size':path.stat().st_size,
                        'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'binaries':binaries})
        print('PASS',path.name,'models/licenses/paths/arm64/iOS13/isolated links')
    (ROOT/a.out).write_text(json.dumps(reports,indent=2))

if __name__ == '__main__':
    main()

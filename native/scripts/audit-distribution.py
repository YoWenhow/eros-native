#!/usr/bin/env python3
"""Allowlist packaged resources and compare their bytes to audited repository inputs."""
import argparse,hashlib,json,plistlib,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('ipa',type=Path);a=p.parse_args()
r=Path(__file__).resolve().parents[1];prefix='Payload/ErosNative.app/'
expected={
'ErosNative_ErosNative.bundle/ThirdPartyNotices.txt':r/'Sources/ErosNative/Resources/ThirdPartyNotices.txt',
'ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy':r/'Vendor/ZIPFoundation/Sources/ZIPFoundation/Resources/PrivacyInfo.xcprivacy',
'AppIcon.png':r/'Resources/AppIcon.png'}
platform={'Info.plist','ErosNative','embedded.mobileprovision','_CodeSignature/CodeResources','ErosNative_ErosNative.bundle/Info.plist','ZIPFoundation_ZIPFoundation.bundle/Info.plist'}
with zipfile.ZipFile(a.ipa) as z:
    files=[n for n in z.namelist() if not n.endswith('/')]
    if len(files)!=len(set(files)):raise SystemExit('Duplicate files')
    seen=set()
    for n in files:
        if not n.startswith(prefix):raise SystemExit('Unexpected archive root')
        rel=n[len(prefix):];seen.add(rel)
        if rel not in expected and rel not in platform:raise SystemExit('Unexpected packaged file: '+rel)
        if rel in expected and z.read(n)!=expected[rel].read_bytes():raise SystemExit('Resource differs from audited source: '+rel)
    if set(expected)-seen:raise SystemExit('Missing source resources')
    info=plistlib.loads(z.read(prefix+'Info.plist'))
print(json.dumps({'status':'PASS','build':info['CFBundleVersion'],'version':info['CFBundleShortVersionString'],'sha256':hashlib.sha256(a.ipa.read_bytes()).hexdigest(),'resourceFilesCompared':len(expected),'fileCount':len(files),'files':sorted(seen),'privateSourceFixturesPackaged':False,'rawLogsOrDatabasePackaged':False,'note':'Allowlist compares resource payloads to audited source. Production package excludes offline/performance fixtures and acceptance resource bundles. Signed provisioning metadata is expected and remains local; no byte-string scan claim about executable.'},indent=2))

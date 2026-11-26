#!/usr/bin/env python3
"""Numeric/hash-only build provenance; never enumerate credentials or device IDs."""
import argparse, hashlib, json, plistlib, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('configuration',choices=['debug','release']);p.add_argument('--snapshot-manifest',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def run(*cmd): return subprocess.check_output(cmd,cwd=root,text=True,stderr=subprocess.STDOUT).strip()
lock=json.loads((root/'Configuration/toolchain-lock.json').read_text())
version=run('swift','--version');xtool=run('xtool','--version')
if 'Swift version '+lock['swift']['selectedVersion']+' ' not in version: raise SystemExit('Swift version differs from lock')
if xtool != 'xtool '+lock['xtool']['selectedRelease']: raise SystemExit('xtool version differs from lock')
import shutil
if digest(Path(shutil.which('xtool'))) != lock['xtool']['sha256']: raise SystemExit('xtool binary differs from lock')
resolved=[root/'Package.resolved',*sorted((root/'Packages').glob('*/Package.resolved'))]
pins=[]
for f in resolved:
    value=json.loads(f.read_text());pins.append({'path':str(f.relative_to(root)),'sha256':digest(f),'pins':value['pins']})
if any(item['pins']!=pins[0]['pins'] for item in pins): raise SystemExit('Dependency locks disagree')
if a.snapshot_manifest:
    source=json.loads(a.snapshot_manifest.read_text())
    for item in source:
        if digest(root/item['path'])!=item['sha256']:raise SystemExit('Snapshot source changed during build: '+item['path'])
    source_digest=digest(a.snapshot_manifest)
else:
    excluded={'.build','.swiftpm','.git','dist','xtool','.xtool','__pycache__','evidence','logs'}
    source=[]
    for f in sorted(root.rglob('*')):
        rel=f.relative_to(root)
        if any(x in excluded for x in rel.parts) or not f.is_file():continue
        if f.suffix.lower() in {'.p8','.p12','.mobileprovision','.key','.ipa','.xip','.cer'} or '.local.' in f.name or f.name.startswith('.env'):continue
        source.append({'path':str(rel),'sha256':digest(f)})
    source_digest=hashlib.sha256(json.dumps(source,sort_keys=True).encode()).hexdigest()
info=plistlib.loads((root/'Configuration/Info.plist').read_bytes())
artifact=json.loads((root/f'dist/{a.configuration}/verification.json').read_text())
if artifact['status']!='PASS' or artifact['build']!=info['CFBundleVersion']:raise SystemExit('Artifact verification mismatch')
report={'schemaVersion':1,'configuration':a.configuration,'build':info['CFBundleVersion'],'bundleID':artifact['bundleID'],'swift':version,'xtool':xtool,'toolchainLockSHA256':digest(root/'Configuration/toolchain-lock.json'),'registeredSDKs':run('swift','sdk','list').splitlines(),'lockedDarwinSDK':lock['darwinSDK'],'dependencies':pins,'sourceManifestSHA256':source_digest,'sourceFileCount':len(source),'sourceFiles':source,'artifact':artifact,'signing':'NOT_RUN','reproducibilityMeaning':'clean source/build directory; SDK and installed toolchain reused; byte-identical IPA not asserted'}
out=root/f'dist/{a.configuration}/build-manifest.json';out.write_text(json.dumps(report,indent=2)+'\n');print('Build manifest verified: '+str(out.relative_to(root)))

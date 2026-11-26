#!/usr/bin/env python3
"""Validate actual T05 IPA contents, including Mach-O platform and minimum OS."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path, PurePosixPath
import struct
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('ipa', type=Path)
parser.add_argument('--expected-bundle-id', default='org.erosnative.app')
parser.add_argument('--signed', action='store_true', help='Require a profile and Mach-O code signature; device install verifies Apple trust.')
args = parser.parse_args()

def require(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)

def version(value):
    return f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'

with zipfile.ZipFile(args.ipa) as archive:
    require(archive.testzip() is None, 'ZIP CRC mismatch')
    names = archive.namelist()
    require(len(names) == len(set(names)), 'duplicate archive entries')
    prefix = 'Payload/ErosNative.app/'
    for name in names:
        path = PurePosixPath(name)
        require(not path.is_absolute() and '..' not in path.parts, 'unsafe ZIP path')
        require(name in ('Payload/', 'Payload/ErosNative.app/') or name.startswith(prefix), 'unexpected IPA root')
        require(not any(p.endswith('.sdk') or p.lower() in ('tests', 'fixtures', '.build', '.git') for p in path.parts), 'SDK/cache/test content in IPA')
        require(path.suffix.lower() not in ('.p8', '.p12', '.key', '.xip', '.swift'), 'private/source/toolchain file in IPA')
    plist = plistlib.loads(archive.read(prefix + 'Info.plist'))
    require(plist['CFBundleIdentifier'] == args.expected_bundle_id, 'unexpected bundle ID')
    require(plist['CFBundleExecutable'] == 'ErosNative', 'unexpected executable')
    require(plist['CFBundlePackageType'] == 'APPL', 'not an application bundle')
    require(plist['MinimumOSVersion'] == '27.0', 'plist deployment target differs from 27.0')
    require(plist['UIDeviceFamily'] == [1], 'device family must be iPhone only')
    orientations = ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    require(plist['UISupportedInterfaceOrientations'] == orientations, 'incorrect orientations')
    require(plist['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'not an iPhoneOS bundle')
    require(plist['UIRequiredDeviceCapabilities'] == ['arm64'], 'ARM64 capability missing')
    require(plist['LSRequiresIPhoneOS'] is True, 'iPhoneOS requirement missing')
    binary = archive.read(prefix + plist['CFBundleExecutable'])
    executable_mode = archive.getinfo(prefix + plist['CFBundleExecutable']).external_attr >> 16
    require(executable_mode & 0o111, 'executable permission missing from ZIP')
    require(len(binary) >= 32, 'truncated Mach-O')
    magic, cpu, subtype, filetype, count, command_size, flags, reserved = struct.unpack_from('<8I', binary)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 2, 'expected thin ARM64 Mach-O executable')
    offset = 32
    build = None
    has_signature = False
    for _ in range(count):
        command, size = struct.unpack_from('<II', binary, offset)
        require(size >= 8 and offset + size <= 32 + command_size <= len(binary), 'invalid Mach-O load command')
        if command == 0x32:
            platform, minimum, sdk, tools = struct.unpack_from('<4I', binary, offset + 8)
            build = {'platform': platform, 'minimumOS': version(minimum), 'sdk': version(sdk)}
        if command == 0x1D:
            signature_offset, signature_size = struct.unpack_from('<II', binary, offset + 8)
            has_signature = signature_size > 0 and signature_offset + signature_size <= len(binary)
        offset += size
    require(build is not None and build['platform'] == 2, 'Mach-O must target iOS device, not simulator/macOS')
    require(build['minimumOS'] == '27.0.0', 'Mach-O deployment target differs from plist')
    icon_name = plist['CFBundleIconFile'] + '.png'
    icon = archive.read(prefix + icon_name)
    require(icon[:8] == b'\x89PNG\r\n\x1a\n', 'icon is not PNG')
    require(struct.unpack_from('>II', icon, 16) == (1024, 1024), 'expected 1024x1024 icon')
    require(icon[25] == 2, 'icon must be opaque RGB')
    if args.signed:
        require(prefix + 'embedded.mobileprovision' in names and has_signature, 'signed artifact missing profile/code signature')
    else:
        require(prefix + 'embedded.mobileprovision' not in names, 'unsigned artifact must not contain a provisioning profile')
    report = {
        'status': 'PASS', 'artifactKind': 'development-signed-ipa' if args.signed else 'unsigned-ipa-not-for-device-install',
        'bundleID': plist['CFBundleIdentifier'], 'version': plist['CFBundleShortVersionString'],
        'build': plist['CFBundleVersion'], 'minimumOS': plist['MinimumOSVersion'],
        'deviceFamily': plist['UIDeviceFamily'], 'orientations': orientations,
        'machO': build, 'icon': icon_name, 'archiveEntryCount': len(names),
        'sha256': hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
        'signingAndDeviceInstall': 'signature-present-device-install-NOT_RUN' if args.signed else 'NOT_RUN'
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))

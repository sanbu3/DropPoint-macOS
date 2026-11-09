#!/usr/bin/env python3
"""Verify source versions/artwork and bind an installed bundle to a Git commit.

Before signing: python3 scripts/verify-release.py --stamp path/to/DropPoint.app
After installing: python3 scripts/verify-release.py --app /Applications/DropPoint.app --reference path/to/signed/DropPoint.app
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ['Sources', 'Resources', 'project.yml', 'DropPointNative.xcodeproj/project.pbxproj']


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def source_info():
    project = (ROOT / 'project.yml').read_text()
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version = re.search(r'MARKETING_VERSION:\s*([^\s]+)', project).group(1)
    build = re.search(r'CURRENT_PROJECT_VERSION:\s*([^\s]+)', project).group(1)
    require(info['CFBundleShortVersionString'] == version, 'Source version mismatch')
    require(info['CFBundleVersion'] == build, 'Source build number mismatch')
    manifest = json.loads((ROOT / 'Resources/ArtworkTimelines.json').read_text())
    for name, entry in manifest.items():
        svg = ROOT / 'Resources' / (name + '.svg')
        require(hashlib.sha256(svg.read_bytes()).hexdigest() == entry['sourceSHA256'], 'Artwork needs regeneration: ' + name)
        require((ROOT / 'Resources' / (name + ' Timeline.png')).is_file(), 'Missing animation: ' + name)
    names = run('git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', *INPUTS).split('\0')
    digest = hashlib.sha256()
    for name in sorted(set(filter(None, names))):
        if not (ROOT / name).is_file():
            continue
        digest.update(name.encode() + b'\0')
        digest.update(hashlib.sha256((ROOT / name).read_bytes()).digest())
    return dict(version=version, build=build, commit=run('git', 'rev-parse', 'HEAD'), sourceSHA256=digest.hexdigest())


def contents(app):
    return {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in app.rglob('*') if p.is_file()}


def verify_bundle(app, expected):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleShortVersionString'] == expected['version'], 'App version mismatch')
    require(info['CFBundleVersion'] == expected['build'], 'App build mismatch')
    require(info['CFBundleIdentifier'] == 'io.github.sanbu3.droppoint.macos', 'App identity mismatch')
    binary = app / 'Contents/MacOS/DropPoint'
    require(set(run('lipo', '-archs', str(binary)).split()) == {'arm64', 'x86_64'}, 'Expected Universal executable')
    require('WebKit' not in run('otool', '-L', str(binary)), 'Unexpected direct WebKit dependency')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stamp', type=Path)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--reference', type=Path)
    args = parser.parse_args()
    require(not (args.stamp and args.app), 'Choose --stamp or --app')
    expected = source_info()
    if args.stamp:
        require(not run('git', 'status', '--porcelain', '--', *INPUTS), 'Commit application inputs before stamping')
        verify_bundle(args.stamp, expected)
        provenance = args.stamp / 'Contents/Resources/ReleaseProvenance.json'
        provenance.write_text(json.dumps(expected, indent=2) + '\n')
        print('Stamped; sign the bundle before installing.')
    if args.app:
        verify_bundle(args.app, expected)
        provenance = json.loads((args.app / 'Contents/Resources/ReleaseProvenance.json').read_text())
        require(provenance == expected, 'Installed source provenance mismatch')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
        if args.reference:
            require(contents(args.app) == contents(args.reference), 'Installed bundle differs from signed reference')
    print(json.dumps(expected, indent=2))


if __name__ == '__main__':
    main()

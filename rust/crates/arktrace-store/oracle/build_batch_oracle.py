#!/usr/bin/env python3
"""Compile the actual Swift prepared eventBatch adapter with pinned source identity."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[4]
CACHE = Path('/private/tmp/arktrace-batch-swiftpm')


def main():
    xcode = subprocess.check_output(['/usr/bin/xcodebuild', '-version'], text=True).strip()
    assert xcode == 'Xcode 27.0\nBuild version 27A266a'
    source = CACHE / 'oracle-source'
    source.mkdir(parents=True, exist_ok=True)
    pins = []
    for name in ('ArkTraceCore', 'ArkTraceStore'):
        target = source / 'Sources' / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(ROOT / 'Sources' / name, target)
        pins.extend(sorted((ROOT / 'Sources' / name).rglob('*.swift')))
    shutil.copytree(ROOT / 'scripts', source / 'scripts', dirs_exist_ok=True)
    target = source / 'Sources/BatchOracle'
    target.mkdir(parents=True, exist_ok=True)
    harness = Path(__file__).with_name('BatchOracle.swift')
    shutil.copyfile(harness, target / harness.name)
    (source / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
    .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
    .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
    .executableTarget(name: "BatchOracle", dependencies: ["ArkTraceCore", "ArkTraceStore"])
], swiftLanguageModes: [.v6])
''', encoding='utf-8')
    subprocess.run(['/usr/bin/git', 'init', '--quiet'], cwd=source, check=True)
    environment = dict(os.environ, ARKTRACE_SWIFTPM_CACHE_ROOT=str(CACHE))
    with (CACHE / 'oracle-build.log').open('w') as log:
        subprocess.run(['sh', 'scripts/run-swiftpm.sh', 'build', '--disable-sandbox',
            '--config-path', str(CACHE / 'configuration'), '--security-path', str(CACHE / 'security'),
            '--product', 'BatchOracle'], cwd=source, env=environment, stdout=log,
            stderr=subprocess.STDOUT, check=True)
    assert 'warning:' not in (CACHE / 'oracle-build.log').read_text(encoding='utf-8')
    binary = CACHE / 'build/out/Products/Debug/BatchOracle'
    pins += [harness, Path(__file__), ROOT / 'scripts/run-swiftpm.sh']
    record = {'oracle': 'actual Swift SQLiteTraceRepository prepared concurrent eventBatch',
        'xcode': xcode, 'swift': subprocess.check_output(['/usr/bin/swift', '--version'], text=True).strip(),
        'executablePath': str(binary), 'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'sourceDigests': [{'path': p.relative_to(ROOT).as_posix(), 'byteCount': p.stat().st_size,
            'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in pins]}
    (CACHE / 'oracle-receipt.json').write_text(json.dumps(record, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(record))


if __name__ == '__main__':
    main()

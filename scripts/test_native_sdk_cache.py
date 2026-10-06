#!/usr/bin/env python3
"""Exercise native header switches in one miniature SwiftPM cache.

Synthetic C archives test compiler invalidation, not native Engine acceptance.
The compiler identity code is read from the actual root Package.swift.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_changed(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = contents.encode() if isinstance(contents, str) else contents
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cache-root', default='/private/tmp/arktrace-native-sdk-cache-contract')
    parser.add_argument('--output')
    args = parser.parse_args()
    cache = Path(args.cache_root)
    assert cache.is_absolute() and not cache.resolve().is_relative_to(ROOT)
    package = cache / 'workspace'
    logs = cache / 'compiler-contract-logs'; logs.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'Package.swift').read_text()
    begin = source.index('// Native SDK cache identity.')
    end = source.index('// End native SDK cache identity.')
    identity_code = source[begin:end]
    # A stable tiny test archive, with identical bytes in both SDKs. Only the
    # header digest changes, so a library-only cache identity would miss it.
    empty = cache / 'empty.c'; write_changed(empty, 'void arktrace_cache_contract_fixture(void) {}\n')
    obj = cache / 'empty.o'; archive = cache / 'empty.a'
    subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=26.0', '-c', str(empty), '-o', str(obj)], check=True)
    subprocess.run(['xcrun', 'ar', 'rcs', str(archive), str(obj)], check=True)
    current = (ROOT / 'contracts/ffi-v1.sha256').read_text().strip()
    sdks = {}
    for name, digest in [('old', '0' * 64), ('new', current)]:
        sdk = cache / 'synthetic-sdks' / name / 'CArkTrace.xcframework'
        slice_path = sdk / 'macos-arm64'; headers = slice_path / 'Headers'
        header = (ROOT / 'bindings/c/arktrace_ffi.h').read_text().replace(current, digest)
        write_changed(headers / 'arktrace_ffi.h', header)
        write_changed(headers / 'module.modulemap', (ROOT / 'bindings/c/module.modulemap').read_bytes())
        write_changed(slice_path / 'libarktrace_ffi.a', archive.read_bytes())
        write_changed(sdk / 'Info.plist', plistlib.dumps({'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64', 'LibraryPath': 'libarktrace_ffi.a', 'HeadersPath': 'Headers', 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos'}], 'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}))
        files = [{'relativePath': p.relative_to(sdk.parent).as_posix(), 'byteCount': p.stat().st_size, 'sha256': sha(p)} for p in sorted(sdk.rglob('*')) if p.is_file()]
        assert len(files) == 4
        write_changed(sdk.parent / 'receipt.json', json.dumps({'files': files, 'compilerFixtureOnly': True}, sort_keys=True))
        sdks[name] = sdk
    properties = []
    configuration = (ROOT / 'Sources/ArkTraceRustRuntime/RustConfiguration.swift').read_text()
    for line in configuration.splitlines():
        if line.startswith(('    let abiVersion:', '    let contractDigest:')):
            properties.append(line)
    assert len(properties) == 2
    write_changed(package / 'Sources/Digest/Configuration.swift', 'import CArkTrace\nstruct Configuration {\n' + '\n'.join(properties) + '\n}\n')
    write_changed(package / 'Sources/Digest/Engine.swift', 'import CArkTrace\npublic func digests() -> [String:String] { ["configuration": Configuration().contractDigest, "engine": ARKTRACE_CONTRACT_DIGEST] }\n')
    write_changed(package / 'Sources/Probe/main.swift', 'import Digest\nimport Foundation\nprint(String(data: try JSONSerialization.data(withJSONObject: digests(), options: [.sortedKeys]), encoding: .utf8)!)\n')
    write_changed(package / 'Package.swift', '''// swift-tools-version: 6.3
import PackageDescription
import Foundation
let nativeSDKPath = ProcessInfo.processInfo.environment["ARKTRACE_RUST_XCFRAMEWORK"]
''' + identity_code + '''
let package = Package(name: "SDKCacheProbe", platforms: [.macOS(.v26)], targets: [
 .binaryTarget(name: "CArkTrace", path: nativeSDKPath!),
 .target(name: "Digest", dependencies: ["CArkTrace"], cSettings: nativeSDKCSettings, swiftSettings: nativeSDKSwiftSettings),
 .executableTarget(name: "Probe", dependencies: ["Digest"])
], swiftLanguageModes: [.v6])
''')
    object_root = cache / 'build/out/Intermediates.noindex/SDKCacheProbe.build/Debug/Digest-t.build/Objects-normal/arm64'
    def objects():
        return {p.name: {'sha256': sha(p), 'mtimeNs': p.stat().st_mtime_ns} for p in object_root.glob('*.o')}
    results = []
    command = ['swift', 'build', '--package-path', str(package), '--scratch-path', str(cache / 'build'), '--cache-path', str(cache / 'dependencies'), '--disable-sandbox', '--config-path', str(cache / 'configuration'), '--security-path', str(cache / 'security'), '-Xswiftc', '-warnings-as-errors']
    for index, name in enumerate(['old', 'new', 'old', 'new', 'new']):
        environment = {**os.environ, 'ARKTRACE_RUST_XCFRAMEWORK': os.path.relpath(sdks[name], package), 'CLANG_MODULE_CACHE_PATH': str(cache / 'ModuleCache'), 'SWIFTPM_MODULECACHE_OVERRIDE': str(cache / 'ModuleCache')}
        log = logs / f'{index}-{name}.log'; before = objects()
        with log.open('wb') as output:
            subprocess.run(command, env=environment, stdout=output, stderr=subprocess.STDOUT, check=True)
        assert b'warning:' not in log.read_bytes() and b'error:' not in log.read_bytes()
        actual = json.loads(subprocess.check_output([str(cache / 'build/out/Products/Debug/Probe')]))
        expected = '0' * 64 if name == 'old' else current
        assert actual == {'configuration': expected, 'engine': expected}, actual
        after = objects(); assert len(after) == 2
        if index == 4:
            assert before == after, 'unchanged SDK must preserve compiler objects'
        results.append({'sdk': name, 'expectedDigest': expected, 'actual': actual, 'matched': True, 'objectsBefore': before, 'objectsAfter': after, 'unchangedObjectsPreserved': index == 4, 'logSHA256': sha(log)})
    report = {'scope': 'Synthetic header cache invalidation only', 'nativeEngineAcceptance': False, 'sameCacheRoot': str(cache), 'sourceConfigurationSHA256': sha(package / 'Sources/Digest/Configuration.swift'), 'actualPackageIdentityCodeSHA256': hashlib.sha256(identity_code.encode()).hexdigest(), 'builds': results}
    if args.output:
        Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()

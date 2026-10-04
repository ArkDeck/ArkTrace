#!/usr/bin/env python3
"""Dedicated caches, explicit argv, complete receipts, no production mutation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from prepare import OWN, ROOT, BASE, digest, write

CARGO = BASE / 'caches/parallel-counter-detail-presentation-cargo'
SWIFT = BASE / 'caches/parallel-counter-detail-presentation-swiftpm'
RECEIPTS = OWN / 'receipts'

def run(name, command, cwd, env, expected=0):
    original_name = name
    attempt = 1
    while (RECEIPTS / (name + '.log')).exists():
        attempt += 1
        name = original_name + '-attempt' + str(attempt)
    log = RECEIPTS / (name + '.log')
    started = time.time()
    with log.open('w', encoding='utf-8') as stream:
        r = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    receipt = {'name': name, 'command': command, 'cwd': str(cwd), 'exitCode': r.returncode,
               'expectedExitCode': expected, 'expectedExitObserved': r.returncode == expected,
               'elapsedSeconds': time.time() - started, 'log': digest(log),
               'environment': {k: v for k, v in env.items() if k.startswith(('ARKTRACE_', 'CARGO_', 'COUNTER_', 'LIBSQLITE3_', 'MACOSX_'))}}
    write(RECEIPTS / (name + '.receipt.json'), receipt)
    print(name, 'exit', r.returncode, 'expected', expected, flush=True)
    if r.returncode != expected:
        print(log.read_text(encoding='utf-8')[-7000:]); raise SystemExit(r.returncode or 1)

def cargo_env():
    CARGO.mkdir(parents=True, exist_ok=True)
    deps = CARGO / 'dependencies'
    if not deps.exists():
        seed = BASE / 'caches/parallel-inspector-counter-compat-fix-cargo/dependencies'
        if not seed.exists(): seed = BASE / 'caches/parallel-quality-adapter-conformance-cargo/dependencies'
        assert seed.exists(), seed
        shutil.copytree(seed, deps)
    env = os.environ.copy()
    env.update(CARGO_HOME=str(deps), CARGO_TARGET_DIR=str(CARGO / 'target'),
               ARKTRACE_CARGO_CACHE_ROOT=str(CARGO), ARKTRACE_CARGO_HOME=str(deps),
               MACOSX_DEPLOYMENT_TARGET='26.0', COUNTER_SWIFT_CANONICAL=str(RECEIPTS / 'swift-canonical.json'))
    return env

def swift():
    source = SWIFT / 'source/ArkTrace'; source.mkdir(parents=True, exist_ok=True)
    paths = ['Sources/ArkTraceCore', 'Sources/ArkTraceRendering', 'Tests/ArkTraceRenderingTests', 'scripts']
    for path in paths: shutil.copytree(ROOT / path, source / path, dirs_exist_ok=True)
    (source / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
 .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
 .target(name: "ArkTraceRendering", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
 .testTarget(name: "ArkTraceRenderingTests", dependencies: ["ArkTraceRendering"])
], swiftLanguageModes: [.v6])
''', encoding='utf-8')
    test = source / 'Tests/ArkTraceRenderingTests/TimelineRenderingTests.swift'
    seams = [ROOT / 'rust/crates/arktrace-viewer/oracle/OracleHarness.swift',
             ROOT / 'rust/crates/arktrace-viewer/oracle/DetailOracleHarness.swift', OWN / 'swift/CounterCombinationOracle.swift']
    for seam in seams: test.write_bytes(test.read_bytes() + b'\n' + seam.read_bytes())
    renderer = source / 'Sources/ArkTraceRendering/TimelineNSView.swift'
    renderer.write_bytes(renderer.read_bytes() + b'\n' + (OWN / 'swift/RendererAccess.swift').read_bytes())
    subprocess.run(['git', 'init', '--quiet'], cwd=source, check=True)
    env = os.environ.copy(); env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(SWIFT),
        COUNTER_SWIFT_INPUT=str(OWN / 'fixtures/swift-vectors.json'), COUNTER_SWIFT_OUTPUT=str(RECEIPTS / 'swift-canonical.json'))
    write(RECEIPTS / 'swift-source-identities.json', {
        'originalSources': [digest(p) for base in paths[:3] for p in sorted((ROOT / base).rglob('*.swift'))],
        'compiledUnchangedSources': [digest(p) for base in paths[:2] for p in sorted((source / base).rglob('*.swift')) if p != renderer],
        'cacheOnlyAppends': [digest(test), digest(renderer)], 'seams': [digest(p) for p in seams + [OWN / 'swift/RendererAccess.swift']],
        'originalLoader': digest(ROOT / 'Sources/ArkTraceRendering/TimelineSnapshotLoader.swift'),
        'compiledLoader': digest(source / 'Sources/ArkTraceRendering/TimelineSnapshotLoader.swift'),
        'manifest': digest(source / 'Package.swift'), 'copiedAlgorithms': False,
        'repositoryCarrier': 'existing frozen DetailOracleRepository returns inherited DTOs; no new SQL/repository run',
        'qualityOracleScope': 'presentation facts only; carrier does not replay repository quality'})
    run('swift-toolchain', ['swift', '--version'], source, env)
    run('xcode-toolchain', ['xcodebuild', '-version'], source, env)
    run('swift-canonical', ['sh', 'scripts/run-swiftpm.sh', 'test', '--disable-sandbox',
         '--config-path', str(SWIFT / 'configuration'), '--security-path', str(SWIFT / 'security'),
         '--filter', 'TimelineRenderingTests.testActualCounterCombinationOracle'], source, env)

def rust():
    env = cargo_env(); manifest = OWN / 'probe/Cargo.toml'
    common = ['cargo', '+1.99.0']
    run('rust-toolchain', ['rustc', '+1.99.0', '--version'], ROOT, env)
    if not (OWN / 'probe/Cargo.lock').exists():
        run('isolated-lock', common + ['generate-lockfile', '--offline', '--manifest-path', str(manifest)], ROOT, env)
    run('isolated-format', common + ['fmt', '--manifest-path', str(manifest)], ROOT, env)
    run('isolated-fmt-check', common + ['fmt', '--manifest-path', str(manifest), '--', '--check'], ROOT, env)
    run('isolated-build', common + ['build', '--offline', '--locked', '--manifest-path', str(manifest)], ROOT, env)
    run('isolated-clippy', common + ['clippy', '--offline', '--locked', '--manifest-path', str(manifest), '--all-targets', '--all-features', '--', '-D', 'warnings'], ROOT, env)
    run('isolated-observe', common + ['run', '--offline', '--locked', '--manifest-path', str(manifest), '--', str(RECEIPTS / 'rust-observations.json')], ROOT, env)
    run('isolated-controls', common + ['test', '--offline', '--locked', '--manifest-path', str(manifest), '--', '--skip', 'legal_counter_compatibility_contract'], ROOT, env)
    run('legal-counter-contract-red', common + ['test', '--offline', '--locked', '--manifest-path', str(manifest), 'tests::legal_counter_compatibility_contract', '--', '--exact', '--nocapture'], ROOT, env, expected=101)

def root_gates():
    env = cargo_env()
    # Archive snapshot has no Git index. The stock runner intentionally gets
    # its sources from Git. Give it a separate pinned cache-only checkout.
    source = CARGO / 'gate-source'
    source.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((ROOT / 'parallel-snapshot.json').read_text(encoding='utf-8'))['files']
    for item in baseline:
        p = ROOT / item['path']; target = source / item['path']
        assert digest(p)['sha256'] == item['sha256']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, target)
    subprocess.run(['git', 'init', '--quiet'], cwd=source, check=True)
    subprocess.run(['git', 'add', '--force', 'rust', 'contracts', 'ThirdParty/TraceStreamer/macx/manifest.json'], cwd=source, check=True)
    write(RECEIPTS / 'root-gate-source-identities.json', {'baselineFiles': len(baseline),
        'cacheOnlyGitIndex': str(source), 'all946OriginalBytesMatched': True,
        'sourcePins': [digest(source / v['path']) for v in baseline]})
    run('root-fmt-check', ['python3', 'scripts/run-cargo.py', 'fmt', '--all', '--', '--check'], source, env)
    run('root-clippy', ['python3', 'scripts/run-cargo.py', 'clippy', '-p', 'arktrace-viewer', '--all-targets', '--all-features', '--', '-D', 'warnings'], source, env)
    run('related-detail-presentation', ['python3', 'scripts/run-cargo.py', 'test', '-p', 'arktrace-viewer', '--test', 'detail_queries', '--test', 'detail_oracle', '--test', 'presentation_oracle', '--test', 'presentation_regressions'], source, env)
    run('contract-tests', ['python3', 'scripts/run-cargo.py', 'test', '-p', 'arktrace-contract'], source, env)
    run('workspace-license', ['python3', 'scripts/verify_rust_workspace.py'], source, env)
    root_tail()

def root_tail():
    env = cargo_env(); source = CARGO / 'gate-source'
    run('license', ['sh', 'scripts/verify_licenses.sh'], source, env)
    run('migration-contract', ['python3', 'scripts/verify_migration_contracts.py'], source, env)

if __name__ == '__main__':
    RECEIPTS.mkdir(parents=True, exist_ok=True)
    {'swift': swift, 'rust': rust, 'root': root_gates, 'root-tail': root_tail}[sys.argv[1]]()

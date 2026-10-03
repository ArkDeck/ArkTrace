#!/usr/bin/env python3
"""Build the actual Swift SQLite + Viewer oracle, preserving source identities."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[4]
CRATE = ROOT / 'rust/crates/arktrace-viewer'

def build():
    cache = Path(os.environ.get('ARKTRACE_NATIVE_VIEWPORT_ORACLE_CACHE_ROOT', '/private/tmp/arktrace-native-viewport-swiftpm'))
    if not cache.is_absolute() or cache.resolve().is_relative_to(ROOT):
        raise SystemExit('oracle cache must be absolute and outside source')
    xcode = subprocess.check_output(['xcodebuild','-version'],text=True).strip()
    assert xcode.startswith('Xcode 27.'), xcode
    source = cache / 'oracle-source'
    source.mkdir(parents=True,exist_ok=True)
    paths = [Path(__file__),CRATE/'oracle/NativeViewportOracle.swift',ROOT/'scripts/run-swiftpm.sh']
    for name in ['ArkTraceCore','ArkTraceStore','ArkTraceRendering']:
        destination = source/'Sources'/name
        if destination.exists(): shutil.rmtree(destination)
        shutil.copytree(ROOT/'Sources'/name,destination)
        paths += sorted((ROOT/'Sources'/name).rglob('*.swift'))
    shutil.copytree(ROOT/'scripts',source/'scripts',dirs_exist_ok=True)
    destination = source/'Sources/NativeViewportOracle'
    destination.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(CRATE/'oracle/NativeViewportOracle.swift',destination/'NativeViewportOracle.swift')
    augmented = source/'Sources/ArkTraceRendering/TimelineNSView.swift'
    augmented.write_text(augmented.read_text()+'''
// Oracle-only access method calls the actual private renderer style selector.
extension TimelineNSView {
    package static func detailOracleStyleName(_ category: String?) -> String {
        String(describing: visualStyle(for: category))
    }
}
''')
    models = source/'Sources/ArkTraceRendering/TimelineModels.swift'
    models.write_text(models.read_text()+'''
// Oracle-only access to the actual internal source conversion.
extension TimelineTrackSource {
    package var nativeOracleDensitySource: TraceDensitySource { densitySource }
}
''')
    (source/'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "ArkTrace", platforms: [.macOS(.v26)], targets: [
 .target(name: "ArkTraceCore", swiftSettings: [.strictMemorySafety()]),
 .target(name: "ArkTraceStore", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
 .target(name: "ArkTraceRendering", dependencies: ["ArkTraceCore"], swiftSettings: [.strictMemorySafety()]),
 .executableTarget(name: "NativeViewportOracle", dependencies: ["ArkTraceCore", "ArkTraceStore", "ArkTraceRendering"])
], swiftLanguageModes: [.v6])
''')
    subprocess.run(['git','init','--quiet'],cwd=source,check=True)
    env = os.environ.copy();env['ARKTRACE_SWIFTPM_CACHE_ROOT']=str(cache)
    log = cache/'native-viewport-build.log'
    with log.open('w') as output:
        run = subprocess.run(['sh','scripts/run-swiftpm.sh','build','--disable-sandbox','--config-path',str(cache/'configuration'),
            '--security-path',str(cache/'security'),'--product','NativeViewportOracle'],cwd=source,env=env,stdout=output,stderr=subprocess.STDOUT)
    if run.returncode:
        print(log.read_text()[-12000:]);run.check_returncode()
    assert 'warning:' not in log.read_text(), 'oracle build warning'
    executable=cache/'build/out/Products/Debug/NativeViewportOracle'
    def pin(path,relative=False):
        data=path.read_bytes()
        return {'path':path.relative_to(ROOT).as_posix() if relative else str(path),'sha256':hashlib.sha256(data).hexdigest(),'byteCount':len(data)}
    return executable, {'oracle':'actual Swift SQLiteTraceRepository + TimelineSnapshotLoader + TimelineGeometry + renderer style',
        'xcode':xcode,'swift':subprocess.check_output(['swift','--version'],text=True).strip(),
        'sourceDigests':[pin(path,True) for path in paths],
        'oracleOnlyTransformations':{'location':'cache copy only; repository source unchanged',
            'renderer':'append one access method calling actual private visualStyle; no copied mapping',
            'sourceConversion':'append one access property calling actual internal densitySource',
            'augmentedSources':[pin(augmented),pin(models)],'package':pin(source/'Package.swift')},
        'buildLog':pin(log),'executable':pin(executable)}

if __name__ == '__main__':
    executable, receipt=build()
    print(json.dumps(receipt,ensure_ascii=False,indent=2))

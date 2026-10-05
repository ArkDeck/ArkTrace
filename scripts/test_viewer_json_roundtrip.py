#!/usr/bin/env python3
"""Actual standalone production-dependency Viewer JSON consumer, with no dev feature unification.

Uses the owner's stable Cargo target, exact installed toolchain/locked dependencies and
10,000 complete Viewport roundtrips. Negative decoder evidence is retained.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('arktrace_cargo_runner', ROOT/'scripts/run-cargo.py')
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)
PROGRAM = r'''
use arktrace_viewer::Viewport;
use serde_json::json;
fn main() {
    let mut examples=Vec::new();let mut total=0;let mut rejected=0;
    for duration in 1..=100 {for width in 1..=100 {
        let input=json!({"range":{"startNs":0,"endNs":duration},"widthPoints":width as f64,"heightPoints":80.0,"verticalOffsetPoints":0.0,"generation":1});
        let viewport:Viewport=serde_json::from_value(input).unwrap();let encoded=serde_json::to_vec(&viewport).unwrap();total+=1;
        match serde_json::from_slice::<Viewport>(&encoded) {
            Ok(decoded) if decoded==viewport=>{},
            _=>{rejected+=1;if examples.len()<16 {examples.push(json!({"durationNs":duration,"widthPoints":width,"encodedUtf8":String::from_utf8(encoded).unwrap()}));}}
        }
    }}
    #[cfg(feature="product-json")]assert_eq!(rejected,0,"product JSON must accept every complete encoded Viewport");
    #[cfg(not(feature="product-json"))]assert!(rejected>0,"default decoder difference must be measured");
    println!("{}",serde_json::to_string_pretty(&json!({"cases":total,"rejected":rejected,"examples":examples,"productJSON":cfg!(feature="product-json")})).unwrap());
}
'''


def main():
    workspace = tomllib.loads((ROOT/'rust/Cargo.toml').read_text())['workspace']
    dependency = workspace['dependencies']['serde_json']
    assert isinstance(dependency,dict) and dependency['features'] == ['float_roundtrip']
    toolchain = tomllib.loads((ROOT/'rust/rust-toolchain.toml').read_text())['toolchain']['channel']
    assert toolchain == '1.99.0'
    base = Path(tempfile.mkdtemp(prefix='arktrace-viewer-wire-')).resolve()
    def inputs(workspace_root):
        manifest = '[package]\nname="arktrace-viewer-wire-consumer"\nversion="0.0.0"\nedition="2024"\nrust-version="1.99"\n\n[dependencies]\narktrace-viewer={path='+json.dumps(str(workspace_root/'rust/crates/arktrace-viewer'))+'}\nserde_json='+json.dumps(dependency['version'])+'\n\n[features]\nproduct-json=["serde_json/float_roundtrip"]\n\n[profile.dev]\nincremental=false\ndebug="line-tables-only"\n\n[profile.dev.package."*"]\ndebug=false\n'
        return {'Cargo.toml': manifest.encode(), 'src/main.rs': PROGRAM.encode()}
    commands=[]
    with RUNNER.managed_consumer('viewer-json', inputs) as consumer:
        def run(name, command, options):
            result = consumer.run(command, [*options, '--offline'], capture_output=True, timeout=120)
            (base/(name+'.log')).write_bytes(result.stderr)
            (base/(name+'.stdout')).write_bytes(result.stdout)
            commands.append({'argv': result.args, 'cwd': str(consumer.root), 'exitCode': result.returncode})
            if b'warning:' in result.stderr:
                raise RuntimeError('standalone consumer emitted a compiler warning')
            if result.returncode:
                raise RuntimeError(result.stderr.decode(errors='replace')[-8192:])
            return result.stdout
        run('lock', 'generate-lockfile', [])
        outcomes={}
        for name,options in [('default', []), ('product', ['--features','product-json'])]:
            data=run(name,'run',options);(base/(name+'.json')).write_bytes(data);outcomes[name]=json.loads(data)
        assert outcomes['default']['cases']==outcomes['product']['cases']==10000
        assert outcomes['default']['rejected']>0 and outcomes['product']['rejected']==0
        metadata=json.loads(run('metadata','metadata',['--features','product-json','--format-version','1']))
        package=next(p for p in metadata['packages'] if p['name']=='serde_json')
        node=next(n for n in metadata['resolve']['nodes'] if n['id']==package['id'])
        assert 'float_roundtrip' in node['features']
        for relative in ['Cargo.toml', 'Cargo.lock', 'src/main.rs']:
            destination=base/relative;destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(consumer.root/relative,destination)
        provenance={'commands':commands,'sourceRoot':str(consumer.workspace.source_root),
            'sourceIdentity':RUNNER.source_identity(consumer.workspace.source_root),
            'cacheRoot':str(consumer.workspace.cache),'consumerRoot':str(consumer.root),
            'owner':RUNNER.owner_id(consumer.workspace.environment.get('ARKTRACE_CARGO_OWNER',consumer.workspace.environment.get('CODEX_THREAD_ID','local'))),
            'targetRoot':consumer.workspace.environment['CARGO_TARGET_DIR'],
            'nativeHost':consumer.workspace.environment['ARKTRACE_EXPECT_NATIVE_HOST'],
            'runnerSHA256':hashlib.sha256((ROOT/'scripts/run-cargo.py').read_bytes()).hexdigest(),
            'cacheManagerSHA256':hashlib.sha256((ROOT/'scripts/cargo_cache.py').read_bytes()).hexdigest()}
        (base/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    files=[]
    for p in sorted(base.rglob('*')):
        if p.is_file() and not p.is_relative_to(base/'target'):
            data=p.read_bytes();files.append({'path':str(p),'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    print(json.dumps({'standaloneProductionDependencyConsumer':True,'toolchain':toolchain,
        'serdeJSON':{'version':package['version'],'features':node['features']},'results':outcomes,
        'retainedFiles':files,'macOSAppOrSDKAcceptance':False},ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()

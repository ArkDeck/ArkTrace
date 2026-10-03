#!/usr/bin/env python3
"""Actual standalone production-dependency Viewer JSON consumer, with no dev feature unification.

Uses a private Cargo target, exact installed toolchain/locked dependencies and
10,000 complete Viewport roundtrips. Negative decoder evidence is retained.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parent.parent
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
    (base/'src').mkdir()
    (base/'src/main.rs').write_text(PROGRAM)
    (base/'Cargo.toml').write_text('[package]\nname="arktrace-viewer-wire-consumer"\nversion="0.0.0"\nedition="2024"\nrust-version="1.99"\n\n[dependencies]\narktrace-viewer={path='+json.dumps(str(ROOT/'rust/crates/arktrace-viewer'))+'}\nserde_json='+json.dumps(dependency['version'])+'\n\n[features]\nproduct-json=["serde_json/float_roundtrip"]\n')
    environment = os.environ.copy()
    cache = Path(environment.get('ARKTRACE_CARGO_CACHE_ROOT',str(Path(tempfile.gettempdir())/'arktrace-migration-cargo')))
    assert cache.is_absolute() and not cache.resolve().is_relative_to(ROOT)
    environment.update(CARGO_HOME=str(cache/'dependencies'),CARGO_TARGET_DIR=str(base/'target'),MACOSX_DEPLOYMENT_TARGET='26.0')
    def run(name,args):
        command = ['cargo','+'+toolchain,*args,'--manifest-path',str(base/'Cargo.toml'),'--offline']
        result = subprocess.run(command,cwd=base,env=environment,capture_output=True,timeout=120)
        (base/(name+'.log')).write_bytes(result.stderr)
        if b'warning:' in result.stderr:
            raise RuntimeError('standalone consumer emitted a compiler warning')
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors='replace')[-8192:])
        return result.stdout
    run('lock',['generate-lockfile'])
    outcomes={}
    for name,args in [('default',['run','--locked']),('product',['run','--locked','--features','product-json'])]:
        data=run(name,args);(base/(name+'.json')).write_bytes(data);outcomes[name]=json.loads(data)
    assert outcomes['default']['cases']==outcomes['product']['cases']==10000
    assert outcomes['default']['rejected']>0 and outcomes['product']['rejected']==0
    # Preserve exactly which production/dependency feature set was exercised.
    metadata=json.loads(run('metadata',['metadata','--locked','--features','product-json','--format-version','1']))
    package=next(p for p in metadata['packages'] if p['name']=='serde_json')
    node=next(n for n in metadata['resolve']['nodes'] if n['id']==package['id'])
    assert 'float_roundtrip' in node['features']
    files=[]
    for p in sorted(base.rglob('*')):
        if p.is_file() and not p.is_relative_to(base/'target'):
            data=p.read_bytes();files.append({'path':str(p),'byteCount':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    print(json.dumps({'standaloneProductionDependencyConsumer':True,'toolchain':toolchain,
        'serdeJSON':{'version':package['version'],'features':node['features']},'results':outcomes,
        'retainedFiles':files,'macOSAppOrSDKAcceptance':False},ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()

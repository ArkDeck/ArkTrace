#!/usr/bin/env python3
"""Native pinned commands with immutable per-attempt logs and receipts."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tomllib
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
CARGO=ROOT.parent/'caches/parallel-counter-reveal-compat-cargo'
SWIFT=ROOT.parent/'caches/parallel-counter-reveal-compat-swiftpm'
PACKAGE=CARGO/'workspace'/OWN.relative_to(ROOT);LOGS=OWN/'verification'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def databases():
    p=OWN/'fixtures/database-copy-identities.json'
    if not p.exists():return []
    result=[]
    for r in json.loads(p.read_text(encoding='utf-8')):
        f=Path(r['path']);assert sha(f)==r['sha256']
        result.append(dict(path=str(f),sha256=sha(f),mode=oct(f.stat().st_mode&0o777),byteCount=f.stat().st_size))
    return result
def command(label,cmd,cwd,env,expected=0,output=None):
    log=LOGS/(label+'.log');receipt=LOGS/(label+'.receipt.json')
    assert not log.exists() and not receipt.exists()
    before=databases()
    with log.open('w',encoding='utf-8') as stream:
        p=subprocess.run(cmd,cwd=cwd,env=env,stdout=stream,stderr=subprocess.STDOUT)
    record=dict(label=label,command=cmd,cwd=str(cwd),exitCode=p.returncode,expectedExitCode=expected,log=str(log.relative_to(ROOT)),sha256=sha(log),byteCount=log.stat().st_size,databaseBefore=before,databaseAfter=databases(),environment={k:v for k,v in env.items() if k.startswith(('ARKTRACE_','COUNTER_REVEAL_')) or k in ('CARGO_HOME','CARGO_TARGET_DIR','CARGO_NET_OFFLINE','MACOSX_DEPLOYMENT_TARGET','GIT_DIR','GIT_WORK_TREE')})
    receipt.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(check=label,exitCode=p.returncode)),flush=True)
    if p.returncode!=expected:
        print(log.read_text(encoding='utf-8')[-8000:]);sys.exit(p.returncode or 1)
    if expected==101:
        assert 'legal real Store anchor rejected:' in log.read_text(encoding='utf-8')
    if output:shutil.copyfile(log,output)
def rust_env():
    env=os.environ.copy()
    for key in ('GIT_DIR','GIT_WORK_TREE'):env.pop(key,None)
    env.update(CARGO_HOME=str(CARGO/'dependencies'),CARGO_TARGET_DIR=str(CARGO/'consumer-target'),CARGO_NET_OFFLINE='true',MACOSX_DEPLOYMENT_TARGET='26.0',COUNTER_REVEAL_CASES=str(OWN/'fixtures/cases.json'),COUNTER_REVEAL_SWIFT=str(OWN/'fixtures/swift-controller-output.json'))
    return env
mode=sys.argv[1];base=['cargo','+1.99.0'];mp=['--manifest-path',str(PACKAGE/'Cargo.toml')]
if mode=='prepare':
    command(mode,['python3',str(OWN/'prepare.py')],ROOT,os.environ.copy())
elif mode=='rust-build':
    env=rust_env();command('lock',base+['generate-lockfile','--offline']+mp,CARGO/'workspace',env)
    root={p['name']:p for p in tomllib.loads((ROOT/'rust/Cargo.lock').read_text(encoding='utf-8'))['package'] if p.get('source')}
    pins=[]
    for p in tomllib.loads((PACKAGE/'Cargo.lock').read_text(encoding='utf-8'))['package']:
        if p.get('source'):
            assert all(p[k]==root[p['name']][k] for k in ('version','source','checksum')),p['name'];pins.append(p)
    shutil.copyfile(PACKAGE/'Cargo.lock',OWN/'Cargo.lock')
    (OWN/'fixtures/root-lock-pin-match.json').write_text(json.dumps(dict(registryPackages=len(pins),packages=pins,rootLockSHA256=sha(ROOT/'rust/Cargo.lock'),consumerLockSHA256=sha(OWN/'Cargo.lock')),indent=2)+'\n',encoding='utf-8')
    command('format',base+['fmt']+mp,CARGO/'workspace',env)
    for p in PACKAGE.rglob('*.rs'):shutil.copyfile(p,OWN/p.relative_to(PACKAGE))
    command('build',base+['build','--locked','--offline']+mp,CARGO/'workspace',env)
elif mode in ('rust-repair','rust-frame-adapter'):
    env=rust_env();command(mode+'-format',base+['fmt']+mp,CARGO/'workspace',env)
    for p in (PACKAGE/'src').glob('*.rs'):shutil.copyfile(p,OWN/'src'/p.name)
    command(mode+'-build',base+['build','--locked','--offline']+mp,CARGO/'workspace',env)
elif mode=='swift-canonical':
    env=os.environ.copy()
    for key in ('GIT_DIR','GIT_WORK_TREE','ARKTRACE_RUST_XCFRAMEWORK','ARKTRACE_RUST_SDK_FIXTURES'):env.pop(key,None)
    env.update(ARKTRACE_SWIFTPM_CACHE_ROOT=str(SWIFT/'stable-cache'),COUNTER_REVEAL_CASES=str(OWN/'fixtures/cases.json'),COUNTER_REVEAL_SWIFT=str(OWN/'fixtures/swift-controller-output.json'),COUNTER_REVEAL_DATABASES=str(SWIFT/'databases'),COUNTER_REVEAL_PARSER=str(OWN/'fixtures/parser-identity.json'))
    command(mode,['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(SWIFT/'config'),'--security-path',str(SWIFT/'security'),'--filter','CounterRevealCompatibilityOracleTests'],SWIFT/'oracle-source',env)
elif mode in ('observe','observe-valid'):
    command(mode,[str(CARGO/'consumer-target/debug/arktrace-counter-reveal-compat'),str(OWN/'fixtures/cases.json'),str(OWN/'fixtures/swift-controller-output.json')],CARGO/'workspace',rust_env(),output=OWN/'fixtures/rust-output.json')
elif mode in ('tests','tests-valid'):
    env=rust_env()
    for name in ('wrong_physical_tables_are_rejected_and_shape_validation_keeps_source_identity','native_controller_selection_and_range_reveal_preserve_real_counter_keys'):
        command(mode+'-'+name,base+['test','--locked','--offline']+mp+['--test','compat',name,'--','--exact','--nocapture'],CARGO/'workspace',env)
    command(mode+'-legal-anchor-regression',base+['test','--locked','--offline']+mp+['--test','compat','all_real_repository_counter_anchors_must_pass_navigation_intent_validation','--','--exact','--nocapture'],CARGO/'workspace',env,expected=101)
elif mode in ('checks','checks-valid'):
    env=rust_env();command(mode+'-fmt-check',base+['fmt']+mp+['--check'],CARGO/'workspace',env)
    command(mode+'-strict-clippy',base+['clippy','--locked','--offline']+mp+['--all-targets','--all-features','--','-D','warnings'],CARGO/'workspace',env)
elif mode=='swift-regressions':
    env=os.environ.copy()
    for key in ('GIT_DIR','GIT_WORK_TREE','ARKTRACE_RUST_XCFRAMEWORK','ARKTRACE_RUST_SDK_FIXTURES'):env.pop(key,None)
    env['ARKTRACE_SWIFTPM_CACHE_ROOT']=str(SWIFT/'stable-cache')
    command(mode,['sh','scripts/run-swiftpm.sh','test','--disable-sandbox','--config-path',str(SWIFT/'config'),'--security-path',str(SWIFT/'security'),'--filter','testSearchResultSteppingRevealsWithoutStealingKeyboardFocus|testTimelineKeyboardAndVoiceOverContractUsesBoundedRealEvents'],SWIFT/'oracle-source',env)
elif mode=='workspace-gates':
    env=os.environ.copy();env.update(ARKTRACE_CARGO_CACHE_ROOT=str(CARGO),CARGO_NET_OFFLINE='true',GIT_DIR=str(CARGO/'source-index.git'),GIT_WORK_TREE=str(ROOT))
    subprocess.run(['git','add','.'],cwd=ROOT,env=env,check=True)
    command('workspace-license-verifier',['python3','scripts/verify_rust_workspace.py'],ROOT,env)
    command('root-fmt-check',['python3','scripts/run-cargo.py','fmt','--all','--','--check'],ROOT,env)
else:raise ValueError(mode)

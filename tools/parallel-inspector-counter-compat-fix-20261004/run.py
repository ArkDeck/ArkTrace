#!/usr/bin/env python3
"""Record gates via original exact runner; cache and root manifest stay isolated."""
import datetime,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
OWN=Path(__file__).resolve().parent;ROOT=OWN.parents[1];CACHE=ROOT.parent/'caches/parallel-inspector-counter-compat-fix-cargo'
REC=OWN/'receipts'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def gate(name,cmd,cwd=ROOT,env=None,expected=0):
 REC.mkdir(exist_ok=True)
 if (REC/(name+'.json')).exists():
  attempt=2
  while (REC/(f'{name}-attempt-{attempt}.json')).exists():attempt+=1
  name=f'{name}-attempt-{attempt}'
 log=REC/(name+'.log');started=datetime.datetime.now(datetime.UTC).isoformat()
 with log.open('wb')as stream:p=subprocess.run([str(x)for x in cmd],cwd=cwd,env=env,stdout=stream,stderr=subprocess.STDOUT)
 (REC/(name+'.json')).write_text(json.dumps(dict(name=name,command=[str(x)for x in cmd],cwd=str(cwd),startedAtUtc=started,endedAtUtc=datetime.datetime.now(datetime.UTC).isoformat(),exitCode=p.returncode,expectedExitCode=expected,
  passed=p.returncode==expected,log=log.relative_to(ROOT).as_posix(),logSHA256=digest(log),
  productionSourceSHA256=digest(ROOT/'rust/crates/arktrace-viewer/src/inspector_projection.rs'),
  compiledSourceSHA256=digest(Path(cwd)/'rust/crates/arktrace-viewer/src/inspector_projection.rs'),
  regressionSourceSHA256=digest(ROOT/'rust/crates/arktrace-viewer/tests/inspector_counter_compat_regressions.rs')),indent=2)+'\n',encoding='utf-8')
 print(name,'exit',p.returncode,'expected',expected,flush=True)
 if p.returncode!=expected:print(log.read_text(encoding='utf-8')[-8000:]);raise SystemExit(p.returncode or 1)
def main():
 action=sys.argv[1]
 if action=='prepare':gate(action,[sys.executable,OWN/'prepare.py']);return
 if action in ['license','migration-contract']:
  env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';gate(action,['sh',ROOT/'scripts/verify_licenses.sh']if action=='license'else[sys.executable,ROOT/'scripts/verify_migration_contracts.py'],env=env);return
 source=CACHE/'validation-source';source.mkdir(parents=True,exist_ok=True)
 for name in ['rust','contracts','scripts']:shutil.copytree(ROOT/name,source/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('target','__pycache__'))
 p='ThirdParty/TraceStreamer/macx/manifest.json';(source/p).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/p,source/p)
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 registry=CACHE/'dependencies/registry'
 if not registry.exists():shutil.copytree(ROOT.parent/'caches/parallel-quality-adapter-conformance-cargo/dependencies/registry',registry)
 env=os.environ.copy();env.update(ARKTRACE_CARGO_CACHE_ROOT=str(CACHE),ARKTRACE_CARGO_HOME=str(CACHE/'dependencies'),CARGO_HOME=str(CACHE/'dependencies'),CARGO_NET_OFFLINE='true',ARKTRACE_EXPECT_NATIVE_HOST='macos-arm64',MACOSX_DEPLOYMENT_TARGET='26.0')
 for key in ['LIBSQLITE3_FLAGS','LIBSQLITE3_SYS_USE_PKG_CONFIG','LIBSQLITE3_SYS_BUNDLING','SQLITE3_LIB_DIR','SQLITE3_INCLUDE_DIR','SQLITE3_STATIC','SQLITE_MAX_VARIABLE_NUMBER','SQLITE_MAX_EXPR_DEPTH','SQLITE_MAX_COLUMN']:env.pop(key,None)
 args={'before':['test','-p','arktrace-viewer','--test','inspector_counter_compat_regressions','--offline','--','--nocapture'],
  'baseline-replay':['test','-p','arktrace-viewer','--test','inspector_counter_compat_regressions','--offline','--','--nocapture'],
  'after':['test','-p','arktrace-viewer','--test','inspector_counter_compat_regressions','--offline','--','--nocapture'],
  'related':['test','-p','arktrace-viewer','--test','inspector_projection_regressions','--test','inspector_projection_oracle','--offline'], 'fmt':['fmt','--all','--','--check'],
  'clippy':['clippy','-p','arktrace-viewer','--all-targets','--all-features','--offline','--','-D','warnings'],
  'contract':['test','-p','arktrace-contract','--offline']}
 if action=='format':
  files=[ROOT/'rust/crates/arktrace-viewer/tests/inspector_counter_compat_regressions.rs',ROOT/'rust/crates/arktrace-viewer/src/inspector_projection.rs']
  gate(action,['rustup','run','1.99.0','rustfmt','--edition','2024',*files]);return
 if action=='verify':gate(action,[sys.executable,source/'scripts/verify_rust_workspace.py'],cwd=source,env=env);return
 if action not in args:raise SystemExit('unknown action')
 if action=='baseline-replay':shutil.copyfile(OWN/'receipts/original-inspector-projection.rs',source/'rust/crates/arktrace-viewer/src/inspector_projection.rs')
 gate(action,[sys.executable,source/'scripts/run-cargo.py',*args[action]],cwd=source,env=env,expected=101 if action in ['before','baseline-replay']else 0)
if __name__=='__main__':main()

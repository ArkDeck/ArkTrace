#!/usr/bin/env python3
"""Run pinned locked checks with this task's independent persistent cache."""
import os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
CACHE=Path(os.environ.get('ARKTRACE_CARGO_CACHE_ROOT',ROOT.parent/'caches/parallel-annotations-review-fix-cargo'))
def main():
 if not CACHE.is_absolute()or CACHE.resolve().is_relative_to(ROOT):raise SystemExit('cache must be outside snapshot')
 source=CACHE/'validation-source';source.mkdir(parents=True,exist_ok=True)
 for directory in ['rust','contracts','scripts']:shutil.copytree(ROOT/directory,source/directory,dirs_exist_ok=True,ignore=shutil.ignore_patterns('target','__pycache__'))
 manifest='ThirdParty/TraceStreamer/macx/manifest.json';(source/manifest).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/manifest,source/manifest)
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 registry=CACHE/'dependencies/registry'
 if not registry.exists():
  seed=Path(os.environ.get('ARKTRACE_ANNOTATION_SEED_CARGO_HOME',ROOT.parent/'caches/parallel-annotations-cargo/dependencies'))/'registry'
  if seed.exists():shutil.copytree(seed,registry)
 env=os.environ.copy();env.update(ARKTRACE_CARGO_CACHE_ROOT=str(CACHE),ARKTRACE_CARGO_HOME=str(CACHE/'dependencies'),CARGO_NET_OFFLINE='true')
 args=sys.argv[1:]or['test','-p','arktrace-viewer','--offline']
 command=[sys.executable,'scripts/verify_rust_workspace.py']if args==['verify']else[sys.executable,'scripts/run-cargo.py',*args]
 code=subprocess.run(command,cwd=source,env=env).returncode
 if code==0 and args[0]=='fmt'and '--check'not in args:
  for p in [source/'rust/crates/arktrace-viewer/src/annotations.rs',*[source/'rust/crates/arktrace-viewer/tests'/name for name in ['annotation_oracle.rs','annotation_regressions.rs','annotation_projection_budget.rs']]]:shutil.copyfile(p,ROOT/p.relative_to(source))
 return code
if __name__=='__main__':sys.exit(main())

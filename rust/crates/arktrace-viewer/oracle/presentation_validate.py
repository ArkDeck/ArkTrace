#!/usr/bin/env python3
"""Durable independent source mirror; exact locked runner, no baseline edits."""
import os,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
DEFAULT=ROOT.parent/'caches/parallel-presentation-cargo'
CACHE=Path(os.environ.get('ARKTRACE_CARGO_CACHE_ROOT',DEFAULT))
def main():
 if not CACHE.is_absolute() or CACHE.resolve().is_relative_to(ROOT):raise SystemExit('cache must be absolute and outside snapshot')
 source=CACHE/'validation-source';source.mkdir(parents=True,exist_ok=True)
 for directory in ['rust','contracts','scripts']:
  shutil.copytree(ROOT/directory,source/directory,dirs_exist_ok=True,ignore=shutil.ignore_patterns('target','__pycache__'))
 manifest='ThirdParty/TraceStreamer/macx/manifest.json';(source/manifest).parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/manifest,source/manifest)
 subprocess.run(['git','init','--quiet'],cwd=source,check=True)
 registry=CACHE/'dependencies/registry'
 if not registry.exists() and (Path.home()/'.cargo/registry').exists():shutil.copytree(Path.home()/'.cargo/registry',registry)
 if seed:=os.environ.get('ARKTRACE_PRESENTATION_SEED_CARGO_HOME'):shutil.copytree(Path(seed)/'registry',registry,dirs_exist_ok=True)
 env=os.environ.copy();env.update(ARKTRACE_CARGO_CACHE_ROOT=str(CACHE),ARKTRACE_CARGO_HOME=str(CACHE/'dependencies'),CARGO_NET_OFFLINE='true')
 args=sys.argv[1:] or ['test','-p','arktrace-viewer','--offline']
 command=[sys.executable,'scripts/verify_rust_workspace.py'] if args==['verify']else [sys.executable,'scripts/run-cargo.py',*args]
 result=subprocess.run(command,cwd=source,env=env)
 if result.returncode==0 and args[0]=='fmt' and '--check'not in args:
  for relative in ['src/palette.rs','src/presentation.rs',*['tests/'+p.name for p in (source/'rust/crates/arktrace-viewer/tests').glob('palette*.rs')],*['tests/'+p.name for p in (source/'rust/crates/arktrace-viewer/tests').glob('presentation*.rs')]]:
   shutil.copyfile(source/'rust/crates/arktrace-viewer'/relative,ROOT/'rust/crates/arktrace-viewer'/relative)
 return result.returncode
if __name__=='__main__':sys.exit(main())

#!/usr/bin/env python3
"""Record final pinned validation without changing any shared baseline files."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
CRATE = ROOT / "rust/crates/arktrace-viewer"

def main():
    environment = os.environ.copy()
    cache = Path(environment["ARKTRACE_CARGO_CACHE_ROOT"])
    assert cache.is_absolute() and not cache.resolve().is_relative_to(ROOT)
    environment.update(GIT_DIR=str(cache / "source-index.git"), GIT_WORK_TREE=str(ROOT), CARGO_NET_OFFLINE="true")
    destination = CRATE / "tests/fixtures/navigation-verification"
    destination.mkdir(parents=True,exist_ok=True)
    # Runner sees only this snapshot through an external private index.
    subprocess.run(["git","add","."],cwd=ROOT,env=environment,check=True)
    commands=[
        ("fmt",[sys.executable,"scripts/run-cargo.py","fmt","--all","--check"]),
        ("clippy",[sys.executable,"scripts/run-cargo.py","clippy","-p","arktrace-viewer","--all-targets","--offline","--","-D","warnings"]),
        ("tests",[sys.executable,"scripts/run-cargo.py","test","-p","arktrace-viewer","--offline"]),
        ("workspace",[sys.executable,"scripts/verify_rust_workspace.py"]),
        ("licenses",["sh","scripts/verify_licenses.sh"]),
    ]
    records=[]
    for name,command in commands:
        path=destination/f"{name}.log"
        with path.open("w") as log: result=subprocess.run(command,cwd=ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
        records.append(dict(name=name,command=command,exitCode=result.returncode,log=str(path.relative_to(ROOT)),logSHA256=hashlib.sha256(path.read_bytes()).hexdigest()))
        print(json.dumps(dict(name=name,exitCode=result.returncode)))
        if result.returncode: print(path.read_text()[-10000:])
    snapshot=ROOT/"parallel-snapshot.json"
    manifest=json.loads(snapshot.read_text())
    differences=[]
    for record in manifest["files"]:
        path=ROOT/record["path"]
        if record["kind"]=="file":
            actual=hashlib.sha256(path.read_bytes()).hexdigest()
            if actual!=record["sha256"]: differences.append(dict(path=record["path"],before=record["sha256"],after=actual))
    baseline=dict(snapshotSHA256=hashlib.sha256(snapshot.read_bytes()).hexdigest(),sourceCommit=manifest["sourceCommit"],baselineFileCount=len(manifest["files"]),changedBaselineFiles=differences)
    result=dict(schemaVersion=1,environment={k:environment[k] for k in ("ARKTRACE_CARGO_CACHE_ROOT","GIT_DIR","GIT_WORK_TREE","CARGO_NET_OFFLINE")},commands=records,baseline=baseline)
    (destination/"receipt.json").write_text(json.dumps(result,indent=2)+"\n")
    assert [d["path"] for d in differences]==["rust/crates/arktrace-viewer/src/lib.rs"],differences
    return 1 if any(r["exitCode"] for r in records) else 0

if __name__=="__main__":sys.exit(main())

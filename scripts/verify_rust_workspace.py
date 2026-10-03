#!/usr/bin/env python3
"""Check actual Cargo dependency edges and frozen dependency license identities."""
import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parent.parent
ALLOWED = {
    "arktrace-contract": set(),
    "arktrace-platform": set(),
    "arktrace-parser": {"arktrace-contract", "arktrace-platform"},
    "arktrace-store": {"arktrace-contract", "arktrace-platform"},
    "arktrace-analysis": {"arktrace-contract"},
    "arktrace-viewer": {"arktrace-contract"},
    "arktrace-engine": {"arktrace-contract", "arktrace-platform", "arktrace-parser", "arktrace-store", "arktrace-analysis", "arktrace-viewer"},
    "arktrace-cli": {"arktrace-engine", "arktrace-contract", "arktrace-platform"},
    "arktrace-ffi": {"arktrace-engine", "arktrace-contract", "arktrace-viewer"},
    "arktrace-capture": {"arktrace-platform"},
    "arktrace-capture-ffi": {"arktrace-capture"},
}


def main():
    workspace = tomllib.loads((ROOT / "rust/Cargo.toml").read_text())
    assert workspace["workspace"]["lints"]["rust"]["unsafe_code"] == "forbid"
    for manifest_path in sorted((ROOT / "rust/crates").glob("*/Cargo.toml")):
        manifest = tomllib.loads(manifest_path.read_text())
        if manifest["package"]["name"] == "arktrace-platform":
            assert manifest["lints"]["rust"]["unsafe_code"] == "deny"
            platform_sources = manifest_path.parent / "src"
            for source_path in platform_sources.rglob("*.rs"):
                source = source_path.read_text()
                if source_path.name == "lib.rs":
                    assert source.count("unsafe_code") == 1
                    assert '#[cfg(target_os = "macos")]\n#[allow(unsafe_code)]\nmod macos;' in source
                elif source_path.name != "macos.rs":
                    assert "unsafe_code" not in source, "unreviewed unsafe exception"
        else:
            assert manifest["lints"]["workspace"] is True, "first-party crate relaxed workspace lints"
    metadata = json.loads(subprocess.check_output(
        [sys.executable, str(ROOT / "scripts/run-cargo.py"), "metadata", "--format-version", "1"], cwd=ROOT,
    ))
    inventory = json.loads((ROOT / "rust/dependency-licenses.json").read_text())
    actual = []
    for package in metadata["packages"]:
        if package["id"] in metadata["workspace_members"]:
            name = package["name"]
            assert name in ALLOWED, f"unknown first-party crate: {name}"
            for dep in package["dependencies"]:
                if dep["name"].startswith("arktrace-"):
                    assert dep["name"] in ALLOWED[name], f"forbidden edge {name} -> {dep['name']}"
                if dep.get("path") is not None:
                    assert "/workspace/rust/crates/" in dep["path"].replace("\\", "/"), "external checkout dependency"
        else:
            actual.append({"name": package["name"], "version": package["version"], "license": package["license"]})
    frozen = [{key: record[key] for key in ("name", "version", "license")} for record in inventory["dependencies"]]
    assert sorted(actual, key=lambda p: p["name"]) == frozen, "dependency/license identity drift"
    for record in inventory["dependencies"]:
        assert record["licenseTexts"], f"missing license text: {record['name']}"
        for license_text in record["licenseTexts"]:
            path = ROOT / license_text["path"]
            assert path.resolve().is_relative_to(ROOT / "rust/licenses") and not path.is_symlink()
            data = path.read_bytes()
            assert len(data) == license_text["byteCount"]
            assert hashlib.sha256(data).hexdigest() == license_text["sha256"], str(path.relative_to(ROOT))
    sqlite_lock = json.loads((ROOT / "rust/sqlite-build-lock.json").read_text())
    assert sqlite_lock["defines"] == ["SQLITE_ENABLE_FILESTAT=1"], "SQLite descriptor metadata support drift"
    runner_source = (ROOT / "scripts/run-cargo.py").read_text()
    assert 'environment["LIBSQLITE3_FLAGS"] = "-DSQLITE_ENABLE_FILESTAT=1"' in runner_source
    sqlite_dependency = workspace["workspace"]["dependencies"]["rusqlite"]
    assert sqlite_dependency == {
        "version": "=" + sqlite_lock["rusqliteVersion"],
        "default-features": sqlite_lock["defaultFeatures"],
        "features": sqlite_lock["features"],
    }, "SQLite feature or source selection drift"
    sqlite_package = next(p for p in metadata["packages"] if p["name"] == sqlite_lock["crate"])
    assert sqlite_package["version"] == sqlite_lock["crateVersion"]
    sqlite_root = Path(sqlite_package["manifest_path"]).parent
    for source in sqlite_lock["sourceFiles"]:
        path = sqlite_root / source["path"]
        assert path.resolve().is_relative_to(sqlite_root) and not path.is_symlink()
        data = path.read_bytes()
        assert len(data) == source["byteCount"] and hashlib.sha256(data).hexdigest() == source["sha256"], "bundled SQLite source drift"
    declaration = sqlite_lock["publicDomainDeclaration"]
    path = ROOT / declaration["path"]
    assert path.resolve().is_relative_to(ROOT / "rust/licenses") and not path.is_symlink()
    data = path.read_bytes()
    assert len(data) == declaration["byteCount"] and hashlib.sha256(data).hexdigest() == declaration["sha256"]
    store_source = (ROOT / "rust/crates/arktrace-store/src/lib.rs").read_text()
    assert f'"{sqlite_lock["sqliteVersion"]}"' in store_source and f'"{sqlite_lock["sqliteSourceID"]}"' in store_source
    print(f"Rust workspace: {len(metadata['workspace_members'])} crates, {len(actual)} frozen third-party license expressions; unsafe confined to macOS syscall module")


if __name__ == "__main__":
    main()

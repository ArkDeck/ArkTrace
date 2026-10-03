#!/usr/bin/env python3
"""Export three actual pinned fixtures through the Rust native supervisor.

Development evidence: indexed snapshots and ephemeral Engine Ready, plus native
process/owner/recovery faults. No product acceptance or production signature claim.
Preserves its private root on failure; never edits the parser or raw fixtures.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def cargo(*arguments):
    result = subprocess.run([sys.executable, str(ROOT / "scripts/run-cargo.py"), *arguments],
                            cwd=ROOT, capture_output=True, timeout=120)
    if result.returncode:
        sys.stderr.buffer.write(result.stderr[:16384])
        result.check_returncode()
    return result.stdout


def main():
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise SystemExit("native macOS arm64 required; no simulated PASS")
    parser = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
    manifest = json.loads((parser.parent / "manifest.json").read_text())
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    assert digest(parser) == manifest["binarySHA256"] == oracle["parser"]["binarySHA256"]
    for fixture in oracle["corpus"]:
        assert digest(ROOT / fixture["path"]) == fixture["sha256"]
    cargo("build", "-p", "arktrace-platform", "--bin", "arktrace-host-process", "--example", "macos_parser_process_probe")
    target = Path(json.loads(cargo("metadata", "--format-version", "1", "--no-deps"))["target_directory"])
    helper = target / "debug/arktrace-host-process"
    base = Path(tempfile.mkdtemp(prefix="arktrace-parser-process-空 格-")).resolve()
    try:
        # A later Cargo all-features build may replace the shared target path.
        # Pin this run's private complete artifact, never recompute that path.
        helper_input = base / "helper-input"
        shutil.copyfile(helper, helper_input)
        helper_input.chmod(0o500)
        helper_pin = digest(helper_input)
        report = json.loads(cargo("run", "-p", "arktrace-platform", "--example", "macos_parser_process_probe", "--",
                                 str(base), str(helper_input), helper_pin, str(parser), manifest["binarySHA256"], str(ROOT / "Fixtures/traces")))
        assert digest(base / "tools/host-process") == helper_pin
        report["helperExecutableSHA256"] = helper_pin
        assert report["readyAcceptance"] is False
        for index, export in enumerate(report["exports"]):
            session = base / export["sessionDirectory"]
            assert session.resolve().is_relative_to(base)
            database = session / "partial.db"
            export["databaseMode"] = database.stat().st_mode & 0o777
            assert export["databaseMode"] == 0o600
            sidecar = session / "partial.db.ohos.ts"
            if export["sidecar"] is not None:
                export["sidecar"]["mode"] = sidecar.stat().st_mode & 0o777
                assert export["sidecar"]["mode"] == 0o600
            assert export["rawBytesUnchanged"] is True
            assert export["liveOutputFileBytes"] == [
                export["databaseByteCount"],
                export["sidecar"]["byteCount"] if export["sidecar"] is not None else None,
            ]
            with sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True) as connection:
                check = connection.execute("PRAGMA quick_check").fetchall()
                assert check == [("ok",)]
                export["quickCheck"] = "ok"
                export["tableCount"] = connection.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
            assert digest(database) == export["databaseSHA256"]
            published = base / export["publishedDirectory"]
            assert published.resolve().is_relative_to(base)
            assert export["sealedPublicationVerified"] is True
            assert (published / "trace.db").stat().st_mode & 0o777 == 0o400
            assert (published / "probe.json").stat().st_mode & 0o777 == 0o400
            assert digest(published / "trace.db") == export["databaseSHA256"]
            marker = json.loads((published / "probe.json").read_text())
            assert marker["readyAcceptance"] is False
            assert marker["databaseSHA256"] == export["databaseSHA256"]
            with sqlite3.connect((published / "trace.db").as_uri() + "?mode=ro&immutable=1", uri=True) as connection:
                assert connection.execute("PRAGMA quick_check").fetchall() == [("ok",)]
            export["publishedQuickCheck"] = "ok"
            owner_record = base / "stage/.owners" / f"{export['publishedOwnerIdentifier']}.json"
            assert owner_record.stat().st_mode & 0o777 == 0o400
            record = json.loads(owner_record.read_text())
            assert set(record) == {"formatVersion", "state", "device", "inode", "relativePath"}
            assert record["formatVersion"] == 2 and record["state"] == "ready"
            assert record["relativePath"] == export["publishedDirectory"]
            assert record["device"] == published.stat().st_dev
            assert record["inode"] == published.stat().st_ino
            export["publishedOwnerIdentityVerified"] = True
        store = json.loads(cargo("run", "-p", "arktrace-engine", "--example", "macos_store_probe", "--", str(base)))
        assert store["readyAcceptance"] is False
        sqlite_lock = json.loads((ROOT / "rust/sqlite-build-lock.json").read_text())
        assert store["sqliteVersion"] == sqlite_lock["sqliteVersion"]
        assert store["sqliteSourceID"] == sqlite_lock["sqliteSourceID"]
        assert store["sqliteRuntime"]["fileStatFunctionAvailable"] is True
        assert len(store["results"]) == 3
        for index, result in enumerate(store["results"]):
            assert result["caseIndex"] == index and result["snapshotUnchanged"] is True
            export = report["exports"][index]
            assert result["databaseSHA256"] == export["databaseSHA256"]
            assert result["databaseByteCount"] == export["databaseByteCount"]
            identifier = Path(oracle["corpus"][index]["path"]).stem
            swift = next(row["document"] for row in oracle["records"] if row["id"] == identifier + "/inspect")
            summary = next(row["document"] for row in oracle["records"] if row["id"] == identifier + "/summary")
            expected = {"capabilities": swift["result"]["capabilities"], "dataQuality": swift["dataQuality"],
                        "schemaFingerprint": swift["trace"]["schemaFingerprint"], "durationNs": summary["result"]["durationNs"]}
            actual = {key: result["inspection"][key] for key in expected}
            canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
            assert canonical(actual) == canonical(expected)
            prep = result["preparation"]
            assert prep["indexSchemaVersion"] == 3 and prep["schemaAdapterVersion"] == "2"
            assert prep["upstreamDatabaseSha256"] == result["databaseSHA256"]
            assert prep["upstreamDatabaseByteCount"] == result["databaseByteCount"]
            assert result["preparedOwnerCleaned"] is True
            progress = result["indexProgress"]
            assert progress == ([{"phase": "Bootstrap", "completed": n, "total": 5} for n in range(1, 6)] +
                                [{"phase": "Ready", "completed": n, "total": 19} for n in range(1, 20)])
            indexed = base / f"indexed-case-{index}.db"
            assert indexed.stat().st_mode & 0o777 == 0o400
            assert digest(indexed) == prep["preparedDatabaseSha256"]
            assert indexed.stat().st_size == prep["preparedDatabaseByteCount"]
            definitions = json.loads((ROOT / "contracts/index-definitions.json").read_text())["definitions"]
            with sqlite3.connect(indexed.as_uri() + "?mode=ro&immutable=1", uri=True) as connection:
                assert connection.execute("PRAGMA quick_check").fetchall() == [("ok",)]
                assert connection.execute("PRAGMA journal_mode").fetchone() == ("delete",)
                names = sorted(row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'arktrace_%'"))
                assert names == prep["applicableIndexNames"] == sorted(d["name"] for d in definitions)
                for definition in definitions:
                    quote = lambda value: '"' + value.replace('"', '""') + '"'
                    rows = connection.execute(f"PRAGMA index_xinfo({quote(definition['name'])})").fetchall()
                    index_rows = [row for row in connection.execute(f"PRAGMA index_list({quote(definition['table'])})")
                                  if row[1] == definition["name"]]
                    assert len(index_rows) == 1 and index_rows[0][2] == 0 and index_rows[0][4] == 0
                    key_columns = [row for row in rows if row[5] == 1]
                    assert [row[2] for row in key_columns] == definition["columns"]
                    assert all(row[3] == 0 and row[4] == 'BINARY' for row in key_columns)
                result["independentIndexedQuickCheckAndClosure"] = "pass"
            result["swiftOracleSchemaCapabilitiesQualityAndDuration"] = "T0"
        report["rustStore"] = store
        identity = {key: manifest[key] for key in ["name", "reportedVersion", "binarySHA256", "upstreamRepository",
                    "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"]}
        engine = json.loads(cargo("run", "-p", "arktrace-engine", "--features", "process-fixtures", "--example", "macos_engine_probe", "--",
                                  str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin))
        assert engine["readyAcceptance"] is False and engine["engineNoCacheReadyPublication"] is True
        assert engine["developmentTrustOnly"] is True
        assert engine["simultaneousIndependentNoCacheSessions"] is True
        assert engine["explicitCloseRemovedReadyOwnersAndLeases"] is True
        for index, result in enumerate(engine["results"]):
            assert result["fixture"] == report["exports"][index]["fixture"]
            assert result["sourceSHA256"] == oracle["corpus"][index]["sha256"]
            assert result["sourceByteCount"] == oracle["corpus"][index]["byteCount"]
            assert result["inspection"] == store["results"][index]["inspection"]
            path = base / f"engine-case-{index}.db"
            metadata = json.loads((base / f"engine-case-{index}-metadata.json").read_text())
            assert metadata == result["metadata"]
            assert metadata["parser"] == identity and metadata["sourceSHA256"] == result["sourceSHA256"]
            assert metadata["databaseByteCount"] == path.stat().st_size == result["databaseByteCount"]
            assert path.stat().st_mode & 0o777 == 0o400 and digest(path) == result["databaseSHA256"]
            assert set(metadata) == {"formatVersion", "cacheKey", "parser", "traceSHA256", "sourceSHA256", "sourceByteCount",
                                     "schemaFingerprint", "schemaAdapterVersion", "indexSchemaVersion", "databasePreparation",
                                     "databaseByteCount", "createdAt", "lastAccessedAt"}
            with sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True) as connection:
                assert connection.execute("PRAGMA quick_check").fetchall() == [("ok",)]
                assert connection.execute("PRAGMA journal_mode").fetchone() == ("delete",)
                assert connection.execute("SELECT count(*) FROM sqlite_master WHERE type='index' AND name LIKE 'arktrace_%'").fetchone() == (24,)
            assert result["progress"][-1] == "Ready" and "OpeningDatabase" in result["progress"]
        failures = {row["scenario"]: row for row in engine["negativeCases"]}
        expected_failures = {
            "cancel-source": {"stage": "SourceSnapshot", "failure": {"Host": "Cancelled"}},
            "cancel-parse": {"stage": "Parsing", "failure": {"Process": "Cancelled"}},
            "cancel-index": {"stage": "Indexing", "failure": {"Store": "Cancelled"}},
            "cancel-publish": {"stage": "Publishing", "failure": {"Host": "Cancelled"}},
            "cancel-after-publish": {"stage": "Validating", "failure": {"Host": "Cancelled"}},
            "deadline-after-publish": {"stage": "Validating", "failure": {"Host": "DeadlineExceeded"}},
            "writable-after-publish": {"stage": "Validating", "failure": "InvalidMetadata"},
            "replace-ready-directory": {"stage": "Validating", "failure": {"Host": "IdentityMismatch"}},
            "database-output-budget": {"stage": "Parsing", "failure": {"Process": {"OutputFileLimitExceeded": {"index": 0}}}},
            "scratch-output-budget": {"stage": "Parsing", "failure": {"Process": {"OutputFileLimitExceeded": {"index": 2}}}},
            "parser-version": {"stage": "ParserIdentity", "failure": "ParserVersionMismatch"},
        }
        assert set(failures) == set(expected_failures)
        for scenario, error in expected_failures.items():
            row = failures[scenario]
            assert row["error"] == error, (scenario, row["error"])
            assert row["returnedReady"] is False and row["transientsRemoved"] is True and row["rawUnchanged"] is True
        report["rustEngine"] = engine
        recoveries = {row["scenario"]: row for row in engine["recoveryCases"]}
        assert set(recoveries) == {"active-ready", "dropped-ready", "moved-ready", "invalid-metadata"}
        assert recoveries["active-ready"]["recovery"][0]["outcome"] == {"Owner": "active"}
        assert recoveries["active-ready"]["activeSessionPreserved"] is True
        for scenario in ["dropped-ready", "moved-ready", "invalid-metadata"]:
            assert recoveries[scenario]["recovery"][0]["outcome"] == {"Owner": "removed"}
            assert recoveries[scenario]["rawUnchanged"] is True
            assert recoveries[scenario]["ownedReadyAndLeaseRemoved"] is True
        assert recoveries["moved-ready"]["foreignReplacementPreserved"] is True
        assert recoveries["invalid-metadata"]["initialRejection"][0]["outcome"] == {"Rejected": "InvalidMetadata"}
        crash_recoveries = []
        for window in ["OpeningDatabase", "Ready", "Returned", "BeforeRename", "AfterRename", "Cleanup0", "Cleanup1", "Cleanup2", "Cleanup3", "Cleanup4", "LeaseUnlink0", "LeaseUnlink1"]:
            command = [sys.executable, str(ROOT / "scripts/run-cargo.py"), "run", "-p", "arktrace-engine",
                       "--features", "process-fixtures", "--example", "macos_engine_probe", "--", str(base), str(ROOT / "Fixtures/traces"),
                       json.dumps(identity), helper_pin, "--pause-ready", window]
            worker = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      start_new_session=True)
            try:
                marker_name = ("owner-window.json" if window.startswith("Cleanup") else
                               "ephemeral-window.json" if window in ["BeforeRename", "AfterRename", "LeaseUnlink0", "LeaseUnlink1"]
                               else "worker-window.json")
                marker = base / f"engine-crash-{window}" / marker_name
                end = time.monotonic() + 30
                while not marker.exists():
                    assert worker.poll() is None, worker.communicate()
                    assert time.monotonic() < end, "worker missed actual Engine pause window"
                    time.sleep(0.01)
                state = json.loads(marker.read_text())
                assert os.getpgid(state["pid"]) == worker.pid
                if marker_name == "worker-window.json":
                    assert state["window"] == window
                else:
                    expected_point = int(window[-1]) if window.startswith("Cleanup") else {
                        "BeforeRename": 0, "AfterRename": 1, "LeaseUnlink0": 2, "LeaseUnlink1": 3}[window]
                    assert state["point"] == expected_point
                os.kill(state["pid"], signal.SIGKILL)
                worker.communicate(timeout=10)
                assert worker.returncode != 0
                result = json.loads(cargo("run", "-p", "arktrace-engine", "--features", "process-fixtures", "--example", "macos_engine_probe", "--",
                                          str(base), str(ROOT / "Fixtures/traces"), json.dumps(identity), helper_pin,
                                          "--recover-ready", window))
                assert result["window"] == window and result["readyAcceptance"] is False
                assert len(result["recovery"]) == (2 if window in ["OpeningDatabase", "BeforeRename", "AfterRename"] else 1)
                assert result["rawUnchanged"] is True
                if window == "Cleanup3":
                    assert result["recovery"][0]["outcome"] == {"Owner": "identityUnresolved"}
                    assert result["unresolvedIdentityAndBoundLeaseRetained"] is True
                    assert result["readyOwnersAndLeasesRemoved"] is False
                else:
                    assert all(row["outcome"] == {"Owner": "removed"} for row in result["recovery"])
                    assert result["readyOwnersAndLeasesRemoved"] is True
                result["actualEngineWorkerSIGKILL"] = True
                crash_recoveries.append(result)
            finally:
                if worker.poll() is None:
                    os.killpg(worker.pid, signal.SIGKILL)
                    worker.communicate(timeout=10)
        report["engineReadyCrashRecovery"] = crash_recoveries
        assert len(report["budgetFailures"]) == 2
        for index, failure in enumerate(report["budgetFailures"]):
            assert failure["failure"] == {"OutputFileLimitExceeded": {"index": index}}
            assert failure["rawBytesUnchanged"] is True
            assert failure["published"] is False
            assert not (base / "published" / f"budget-{failure['kind']}").exists()
        recovery = json.loads(cargo("run", "-p", "arktrace-platform", "--example", "macos_parser_process_probe", "--", "--recover-staging", str(base)))
        assert recovery["ownerEvidenceVersion"] == 2
        outcomes = [row["outcome"] for row in recovery["results"]]
        assert outcomes.count("removed") == 5
        assert outcomes.count("publishedNeedsEntryLease") == 3
        assert len(outcomes) == 8
        for export in report["exports"]:
            assert not (base / export["sessionDirectory"]).exists()
            assert (base / export["publishedDirectory"]).exists()
            assert digest(base / export["publishedDirectory"] / "trace.db") == export["databaseSHA256"]
        for failure in report["budgetFailures"]:
            assert not (base / failure["sessionDirectory"]).exists()
        report["ownerRecovery"] = recovery
        for fixture in oracle["corpus"]:
            assert digest(ROOT / fixture["path"]) == fixture["sha256"]
        assert digest(parser) == manifest["binarySHA256"]
        report["rawInputsAndOriginalParserUnchanged"] = True
        report["mode"] = "immutableSnapshot-development-signature"
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        print(json.dumps(report, sort_keys=True))
    except BaseException:
        sys.stderr.write(f"Failed probe preserved its owned private root: {base}\n")
        raise


if __name__ == "__main__":
    main()

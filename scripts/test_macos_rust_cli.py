#!/usr/bin/env python3
"""Run actual packaged Rust CLI commands and native signal/resource failures."""
import copy
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import select
import socket
import signal
import subprocess
import sys
import tempfile
import time

from build_macos_rust_cli_candidate import build_app
from test_macos_parser_process import ROOT, digest
from test_macos_event_queries import arguments as query_arguments
from test_macos_event_queries import install_swift
from test_macos_slice_queries import arguments as slice_arguments
from test_macos_counter_queries import arguments as counter_arguments


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def main():
    options = argparse.ArgumentParser(description=__doc__)
    options.add_argument("--swift-cli", type=Path)
    options.add_argument("--named-oracle", type=Path, default=ROOT / "docs/migration-runs/AT-RUST-007-009-2026-10-03-named-hot.json")
    options.add_argument("--counter-oracle", type=Path)
    args = options.parse_args()
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise SystemExit("native macOS arm64 required; no simulated PASS")
    base = Path(tempfile.mkdtemp(prefix="arktrace-rust-cli-空 格-")).resolve()
    oracle = json.loads((ROOT / "docs/migration-runs/AT-RUST-001-2026-10-02-small-oracle.json").read_text())
    namespace = "com.arktrace.ArkTrace.rust-e2e-" + base.name.rsplit("-", 1)[-1]
    # Independently verify the documented environment-free, euid-scoped root.
    native_temp = Path("/private/tmp")
    session_root = native_temp / (namespace + "-u" + str(os.geteuid()))
    tools_root = native_temp / ("com.arktrace.ArkTrace.rust-tools-u" + str(os.geteuid())) / ".tool-staging"
    before_tools = set(tools_root.rglob("*")) if tools_root.exists() else set()
    report = {"readyAcceptance": False, "productionCliReplacement": False, "developmentTrustOnly": True, "results": [], "queryResults": [], "queryPresentations": [], "negativeCases": [], "namedQueryResults": [], "counterQueryResults": []}
    try:
        print("building default fail-closed and explicit development candidates", file=sys.stderr, flush=True)
        production = build_app(base / "Default.app", development=False, namespace=namespace)
        app = build_app(base / "Candidate.app", development=True, namespace=namespace)
        # Running from a relocated bundle, with an unrelated cwd and spoofed
        # argv[0]/TMPDIR/HOME/PATH, must still use its sealed native resources.
        relocated = base / "迁移 后 Candidate.app"
        app["bundle"].rename(relocated)
        executable = relocated / "Contents/MacOS/arktrace"
        assert digest(executable) == app["executableSHA256"]
        environment = {"PATH": "/usr/bin:/bin", "TMPDIR": str(base / "untrusted-temp"), "HOME": str(base / "untrusted-home"), "DYLD_LIBRARY_PATH": str(base / "untrusted-libraries")}
        limits = ["--timeout-ms", "30000", "--max-rows", "128", "--max-events", "128", "--max-output-bytes", "8388608"]

        def clean():
            if session_root.exists():
                assert not list((session_root / ".ready").glob("*"))
                assert not list((session_root / ".leases").glob("*"))
                assert not list((session_root / ".staging/.owners").glob("*"))
                assert not [p for p in (session_root / ".staging").glob("*") if p.name != ".owners"]
            assert (set(tools_root.rglob("*")) if tools_root.exists() else set()) - before_tools <= {tools_root / ".owners"}

        def run(args, *, expected=0, exe=executable, stdout=None, setup=None):
            result = subprocess.run(["spoofed-argv-zero", *map(str, args)], executable=str(exe), cwd=base, env=environment,
                                    stdin=subprocess.DEVNULL, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE, timeout=130, preexec_fn=setup)
            assert result.returncode == expected, (result.returncode, result.stderr[:2048], result.stdout[:2048] if result.stdout else None)
            assert not result.stderr if expected == 0 else len(result.stderr) <= 262144
            if result.stdout:
                assert len(result.stdout) + len(result.stderr) <= 262144
            clean()
            return result

        def error(name, args, code, status, *, exe=executable):
            result = run(args, expected=status, exe=exe)
            value = json.loads(result.stdout)
            assert set(value) == {"schemaVersion", "tool", "request", "error"}
            assert set(value["error"]) == {"code", "message", "retryable", "stage", "details"}
            assert value["error"]["code"] == code, value
            assert value["tool"]["buildRevision"] == digest(exe)
            assert str(base) not in result.stdout.decode() + result.stderr.decode()
            report["negativeCases"].append({"scenario": name, "exitStatus": status, "error": value["error"], "explicitCloseRemovedReadyOwnersAndLeases": True})

        assert run(["--help"]).stdout.startswith(b"ArkTrace Rust migration CLI")
        assert run(["--version"]).stdout == b"arktrace 0.1.0\n"
        first_trace = ROOT / "Fixtures/traces/zlib.htrace"
        error("default-rejects-development-seal", ["inspect", first_trace, "--json", "--no-cache"], "INTERNAL_ERROR", 9, exe=production["executable"])
        for fixture in oracle["corpus"]:
            trace = ROOT / fixture["path"]
            for command in ["inspect", "processes", "threads"]:
                print(f"packaged CLI: {trace.name}/{command}", file=sys.stderr, flush=True)
                value = json.loads(run([command, trace, "--json", "--no-cache", *limits]).stdout)
                expected = copy.deepcopy(next(r["document"] for r in oracle["records"] if r["id"] == trace.stem + "/" + command))
                tolerances = [{"pointer": "/tool/buildRevision", "reason": "actual packaged Rust Mach-O replaces actual Swift executable", "swift": expected["tool"]["buildRevision"], "rust": app["executableSHA256"]}]
                expected["tool"]["buildRevision"] = app["executableSHA256"]
                if trace.name == "hiprofiler_data_ability.htrace" and value["provenance"]["upstreamDatabaseSha256"] != expected["provenance"]["upstreamDatabaseSha256"]:
                    tolerances.append({"pointer": "/provenance/upstreamDatabaseSha256", "reason": "existing fixed C++ exporter nondeterminism", "swift": expected["provenance"]["upstreamDatabaseSha256"], "rust": value["provenance"]["upstreamDatabaseSha256"]})
                    expected["provenance"]["upstreamDatabaseSha256"] = value["provenance"]["upstreamDatabaseSha256"]
                assert canonical(value) == canonical(expected), (trace.name, command, value)
                report["results"].append({"fixture": trace.name, "command": command, "document": value, "tolerances": tolerances, "allOtherMachineFacts": "T0", "rawBytesUnchanged": digest(trace) == fixture["sha256"], "explicitCloseRemovedReadyOwnersAndLeases": True})
        query_oracle_path = ROOT / "docs/migration-runs/AT-RUST-007-2026-10-03-scheduling-queries.json"
        query_oracle = json.loads(query_oracle_path.read_text())["nativeSchedulingQueries"]
        report["schedulingOracleSHA256"] = digest(query_oracle_path)
        for row in query_oracle["swiftRecords"]:
            stem, view, scenario = row["id"].split("/")
            fixture = next(f for f in oracle["corpus"] if Path(f["path"]).stem == stem)
            trace = ROOT / fixture["path"]
            print(f"packaged query: {row['id']}", file=sys.stderr, flush=True)
            value = json.loads(run([*query_arguments(trace.name, view, row["query"]), "--json", "--no-cache", *limits]).stdout)
            expected = copy.deepcopy(row["swift"]["document"])
            tolerances = [{"pointer": "/tool/buildRevision", "reason": "actual packaged Rust Mach-O replaces actual Swift executable", "swift": expected["tool"]["buildRevision"], "rust": app["executableSHA256"]}]
            expected["tool"]["buildRevision"] = app["executableSHA256"]
            if trace.name == "hiprofiler_data_ability.htrace" and value["provenance"]["upstreamDatabaseSha256"] != expected["provenance"]["upstreamDatabaseSha256"]:
                tolerances.append({"pointer": "/provenance/upstreamDatabaseSha256", "reason": "existing fixed C++ exporter nondeterminism", "swift": expected["provenance"]["upstreamDatabaseSha256"], "rust": value["provenance"]["upstreamDatabaseSha256"]})
                expected["provenance"]["upstreamDatabaseSha256"] = value["provenance"]["upstreamDatabaseSha256"]
            assert canonical(value) == canonical(expected), (row["id"], value)
            report["queryResults"].append({"id": row["id"], "document": value, "tolerances": tolerances,
                                          "allOtherMachineFacts": "T0", "rawBytesUnchanged": digest(trace) == fixture["sha256"],
                                          "explicitCloseRemovedReadyOwnersAndLeases": True})
        assert len(report["queryResults"]) == 51
        named_report = json.loads(args.named_oracle.read_text())
        named_oracle = named_report.get("nativeNamedQueries", named_report)
        report["namedOracleSHA256"] = digest(args.named_oracle)
        assert len(named_oracle["swiftRecords"]) in [45, 48]
        for row in named_oracle["swiftRecords"]:
            stem = row["id"].split("/")[0]
            fixture = next(f for f in oracle["corpus"] if Path(f["path"]).stem == stem)
            trace = ROOT / fixture["path"]
            print(f"packaged named query: {row['id']}", file=sys.stderr, flush=True)
            value = json.loads(run([*slice_arguments(trace.name, row["query"]), "--json", "--no-cache", *limits]).stdout)
            expected = copy.deepcopy(row["swift"]["document"])
            tolerances = [{"pointer": "/tool/buildRevision", "reason": "actual packaged Rust Mach-O replaces actual Swift executable", "swift": expected["tool"]["buildRevision"], "rust": app["executableSHA256"]}]
            expected["tool"]["buildRevision"] = app["executableSHA256"]
            if trace.name == "hiprofiler_data_ability.htrace" and value["provenance"]["upstreamDatabaseSha256"] != expected["provenance"]["upstreamDatabaseSha256"]:
                tolerances.append({"pointer": "/provenance/upstreamDatabaseSha256", "reason": "existing fixed C++ exporter nondeterminism", "swift": expected["provenance"]["upstreamDatabaseSha256"], "rust": value["provenance"]["upstreamDatabaseSha256"]})
                expected["provenance"]["upstreamDatabaseSha256"] = value["provenance"]["upstreamDatabaseSha256"]
            assert canonical(value) == canonical(expected), (row["id"], value)
            report["namedQueryResults"].append({"id":row["id"], "document":value, "tolerances":tolerances,
                "allOtherMachineFacts":"T0", "rawBytesUnchanged":digest(trace)==fixture["sha256"],
                "explicitCloseRemovedReadyOwnersAndLeases":True})
        print("checking argv, presentation, resource and native signal failures", file=sys.stderr, flush=True)
        error("missing-trace", ["inspect", "--json", "--no-cache"], "INVALID_ARGUMENT", 2)
        error("duplicate-json", ["inspect", first_trace, "--json", "--json"], "INVALID_ARGUMENT", 2)
        error("unknown-option", ["inspect", first_trace, "--json", "--unknown-option"], "INVALID_ARGUMENT", 2)
        error("thread-filter-conflict", ["threads", first_trace, "--json", "--no-cache", "--pid", "1", "--process-key", "2"], "INVALID_ARGUMENT", 2)
        error("row-budget", ["processes", first_trace, "--json", "--no-cache", "--max-rows", "1", "--limit", "2"], "INVALID_ARGUMENT", 2)
        query_base = ["query", first_trace, "--view", "cpu-slices", "--start-ns", "0", "--end-ns", "10", "--json", "--no-cache"]
        for name, extra in [("events-row-budget", ["--max-rows", "10", "--max-events", "1", "--limit", "2"]),
                            ("query-directory-row-budget", ["--max-rows", "1", "--max-events", "10", "--limit", "2"]),
                            ("query-inapplicable-state", ["--state", "running"]),
                            ("query-inapplicable-name", ["--name", "name"]),
                            ("query-absent-key-sentinel", ["--thread-key", "0"]),
                            ("query-filter-conflict", ["--process-key", "2", "--pid", "3"]),
                            ("query-duplicate-view", ["--view", "cpu-slices"])]:
            error(name, [*query_base, *extra], "INVALID_ARGUMENT", 2)
        error("query-missing-range", ["query", first_trace, "--view", "cpu-slices", "--json", "--no-cache"], "INVALID_ARGUMENT", 2)
        error("query-int64-overflow", ["query", first_trace, "--view", "cpu-slices", "--start-ns", "0", "--end-ns", "9223372036854775808", "--json", "--no-cache"], "INVALID_ARGUMENT", 2)
        error("query-outside-trace-even-unavailable", ["query", first_trace, "--view", "cpu-slices", "--start-ns", "0", "--end-ns", "9223372036854775807", "--json", "--no-cache"], "INVALID_ARGUMENT", 2)
        error("query-output-limit", ["query", ROOT / "Fixtures/traces/trace_small_10.systrace", "--view", "cpu-slices", "--start-ns", "0", "--end-ns", "1000000000", "--json", "--no-cache", "--max-output-bytes", "1024"], "OUTPUT_LIMIT_EXCEEDED", 7)
        error("query-state-utf8-byte-budget", ["query", first_trace, "--view", "thread-states", "--start-ns", "0", "--end-ns", "10", "--raw-state", "界" * 86, "--json", "--no-cache"], "INVALID_ARGUMENT", 2)
        if args.counter_oracle:
            counter_report = json.loads(args.counter_oracle.read_text())
            counter_oracle = counter_report.get("nativeCounterQueries", counter_report)
            report["counterOracleSHA256"] = digest(args.counter_oracle)
            assert len(counter_oracle["swiftRecords"]) == 48
            for row in counter_oracle["swiftRecords"]:
                stem = row["id"].split("/")[0]
                fixture = next(f for f in oracle["corpus"] if Path(f["path"]).stem == stem)
                trace = ROOT / fixture["path"]
                print(f"packaged counter query: {row['id']}", file=sys.stderr, flush=True)
                value = json.loads(run([*counter_arguments(trace.name, row["query"]), "--json", "--no-cache", *limits]).stdout)
                expected = copy.deepcopy(row["swift"]["document"])
                tolerances = [{"pointer": "/tool/buildRevision", "reason": "actual packaged Rust Mach-O replaces actual Swift executable", "swift": expected["tool"]["buildRevision"], "rust": app["executableSHA256"]}]
                expected["tool"]["buildRevision"] = app["executableSHA256"]
                if trace.name == "hiprofiler_data_ability.htrace" and value["provenance"]["upstreamDatabaseSha256"] != expected["provenance"]["upstreamDatabaseSha256"]:
                    tolerances.append({"pointer": "/provenance/upstreamDatabaseSha256", "reason": "existing fixed C++ exporter nondeterminism", "swift": expected["provenance"]["upstreamDatabaseSha256"], "rust": value["provenance"]["upstreamDatabaseSha256"]})
                    expected["provenance"]["upstreamDatabaseSha256"] = value["provenance"]["upstreamDatabaseSha256"]
                assert canonical(value) == canonical(expected), (row["id"], value)
                report["counterQueryResults"].append({"id": row["id"], "document": value, "tolerances": tolerances, "allOtherMachineFacts": "T0", "rawBytesUnchanged": digest(trace) == fixture["sha256"], "explicitCloseRemovedReadyOwnersAndLeases": True})
        counter_base = ["query", first_trace, "--view", "counters", "--start-ns", "0", "--end-ns", "1000000000", "--json", "--no-cache"]
        for name, extra in [("cpu-process-scope", ["--cpu", "0", "--process-key", "1"]), ("cpu-pid-scope", ["--cpu", "0", "--pid", "1"]), ("thread-key", ["--thread-key", "1"]), ("tid", ["--tid", "1"]), ("depth", ["--depth", "0"]), ("duration", ["--min-duration-ns", "0"]), ("raw-state", ["--raw-state", "R"]), ("state", ["--state", "running"]), ("filter-id-overflow", ["--filter-id", "9223372036854775808"]), ("duplicate-filter-id", ["--filter-id", "1", "--filter-id", "1"]), ("name-byte-budget", ["--name", "界" * 85 + "aa"]), ("empty-name", ["--name", ""]), ("name-match-without-name", ["--name-match", "prefix"])]:
            error("counter-" + name, [*counter_base, *extra], "INVALID_ARGUMENT", 2)
        error("counter-filter-on-slices", ["query", first_trace, "--view", "slices", "--start-ns", "0", "--end-ns", "10", "--filter-id", "0", "--json", "--no-cache"], "INVALID_ARGUMENT", 2)
        named_base = ["query", first_trace, "--view", "slices", "--start-ns", "0", "--end-ns", "1000000000", "--json", "--no-cache"]
        for name, extra in [
                ("name-byte-budget", ["--name", "界" * 85 + "aa"]), ("empty-name", ["--name", ""]),
                ("match-without-name", ["--name-match", "prefix"]), ("unknown-match", ["--name", "a", "--name-match", "regex"]),
                ("inapplicable-cpu", ["--cpu", "0"]), ("inapplicable-state", ["--state", "running"]),
                ("negative-duration", ["--min-duration-ns", "-1"]), ("negative-depth", ["--depth", "-1"]),
                ("duration-overflow", ["--min-duration-ns", "9223372036854775808"]),
                ("duplicate-depth", ["--depth", "0", "--depth", "1"]), ("private-argument-handle", ["--includes-argument-set"])]:
            error("named-" + name, [*named_base, *extra], "INVALID_ARGUMENT", 2)
        error("named-output-limit", [*named_base, "--limit", "128", "--max-output-bytes", "1024"], "OUTPUT_LIMIT_EXCEEDED", 7)
        error("explicit-no-cache-required", ["inspect", first_trace, "--json"], "INVALID_ARGUMENT", 2)
        error("missing-input", ["inspect", base / "does-not-exist.htrace", "--json", "--no-cache"], "TRACE_FILE_NOT_FOUND", 3)
        unsupported = base / "not-a-trace.txt"
        unsupported.write_bytes(b"raw trace is never edited")
        error("unsupported-format", ["inspect", unsupported, "--json", "--no-cache"], "TRACE_FORMAT_UNSUPPORTED", 3)
        error("output-limit", ["inspect", first_trace, "--json", "--no-cache", "--max-output-bytes", "1024"], "OUTPUT_LIMIT_EXCEEDED", 7)
        error("error-echo-limit", ["threads", base / "missing.htrace", "--json", "--pretty", "--no-cache", "--max-output-bytes", "1024", "--name", "界" * 1365], "OUTPUT_LIMIT_EXCEEDED", 7)
        error("deadline", ["inspect", ROOT / "Fixtures/traces/trace_small_10.systrace", "--json", "--no-cache", "--timeout-ms", "100"], "QUERY_TIMEOUT", 7)
        human = run(["inspect", first_trace, "--no-cache", "--max-output-bytes", "1024"]).stdout
        assert human.startswith(b"Trace SHA-256: ") and b"Cache hit: no\n" in human and len(human) <= 1024
        pretty = run(["processes", first_trace, "--json", "--pretty", "--no-cache", "--limit", "1"]).stdout
        assert pretty.startswith(b"{\n") and len(json.loads(pretty)["result"]["items"]) == 1
        installed_swift = install_swift(args.swift_cli.resolve(strict=True), base, ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer") if args.swift_cli else None
        report["freshHumanSwiftComparison"] = installed_swift is not None
        if installed_swift:
            report["humanSwiftExecutableSHA256"] = digest(installed_swift)
        for view in ["cpu-slices", "thread-states", "slices"] + (["counters"] if args.counter_oracle else []):
            fixture = "hiprofiler_data_ability.htrace" if view == "counters" else "zlib.htrace" if view == "slices" else "trace_small_10.systrace"
            end_ns = "48516841334" if view == "counters" else "1000000000"
            query_args = ["query", ROOT / "Fixtures/traces" / fixture, "--view", view, "--start-ns", "0", "--end-ns", end_ns, "--limit", "1", "--no-cache"]
            human_query = run(query_args).stdout
            result_key = {"cpu-slices":"cpuSlices", "thread-states":"threadStates", "slices":"slices", "counters":"counters"}[view]
            assert human_query.startswith(f"View: {result_key}\nRange ns: [0, {end_ns})\nCapability available: true\n".encode())
            assert human_query.endswith("… result truncated\n".encode())
            assert {"cpu-slices":b"event=sched_slice:0", "thread-states":b"event=thread_state:0", "slices":b"event=callstack:0", "counters":b"event=process_measure:"}[view] in human_query
            if installed_swift:
                actual_swift = subprocess.run([str(installed_swift), "--trace-streamer", str(ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"), *map(str,query_args)],cwd=ROOT,capture_output=True,timeout=45)
                assert actual_swift.returncode==0 and not actual_swift.stderr and actual_swift.stdout==human_query
            machine_query = run([*query_args, "--json", "--pretty"]).stdout
            assert machine_query.startswith(b"{\n") and len(json.loads(machine_query)["result"][result_key]) == 1
            report["queryPresentations"].append({"view": view, "human": human_query.decode(), "humanByteCount": len(human_query), "prettyByteCount": len(machine_query), "freshSwiftHumanParity":"T0" if installed_swift else None, "explicitCloseRemovedReadyOwnersAndLeases": True})
        human_unavailable = run(["query", first_trace, "--view", "cpu-slices", "--start-ns", "0", "--end-ns", "10", "--no-cache", "--max-output-bytes", "1024"]).stdout
        assert human_unavailable == b"View: cpuSlices\nRange ns: [0, 10)\nCapability available: false\n"
        report["queryPresentations"].append({"view": "cpu-slices", "scenario": "unavailable-1024-byte-human", "human": human_unavailable.decode(), "humanByteCount": len(human_unavailable), "explicitCloseRemovedReadyOwnersAndLeases": True})
        dash_trace = base / "--json.htrace"
        shutil.copyfile(first_trace, dash_trace)
        literal = run(["inspect", "--json", "--no-cache", "--", dash_trace.name]).stdout
        assert json.loads(literal)["trace"]["sha256"] == digest(first_trace)
        empty = json.loads(run(["processes", first_trace, "--json", "--no-cache", "--name", "no-such-process-迁移"]).stdout)
        assert empty["result"] == {"items": []} and empty["truncation"]["truncated"] is False
        override = ROOT / "ThirdParty/TraceStreamer/macx/trace_streamer"
        assert json.loads(run(["inspect", first_trace, "--json", "--no-cache", "--trace-streamer", override]).stdout)["trace"]["parser"]["binarySha256"] == digest(override)
        fake = base / "wrong-parser"
        fake.write_bytes(b"not the fixed parser")
        error("parser-pin-mismatch", ["inspect", first_trace, "--json", "--no-cache", "--trace-streamer", fake], "TRACE_STREAMER_IDENTITY_MISMATCH", 4)
        with open(os.devnull, "wb") as sink:
            run(["inspect", first_trace, "--json", "--no-cache"], stdout=sink)
        broken = subprocess.Popen([str(executable), "inspect", str(first_trace), "--json", "--no-cache"], cwd=base, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        broken.stdout.close()
        broken.stdout = None
        _, broken_stderr = broken.communicate(timeout=35)
        assert broken.returncode == 9 and broken_stderr.startswith(b"INTERNAL_ERROR:")
        assert str(base).encode() not in broken_stderr
        clean()
        report["negativeCases"].append({"scenario": "closed-stdout-pipe", "exitStatus": 9, "signalPipeIgnored": True, "explicitCloseRemovedReadyOwnersAndLeases": True})
        for scenario in ["blocked-stdout-deadline","blocked-stdout-cancel","partial-stdout-close"]:
            receiver,writer=socket.socketpair()
            writer.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,1024)
            send_buffer=writer.getsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF)
            original_flags=fcntl.fcntl(writer,fcntl.F_GETFL)
            pipe = subprocess.Popen([str(executable), "threads", str(ROOT / "Fixtures/traces/hiprofiler_data_ability.htrace"), "--json", "--no-cache", "--timeout-ms", "10000"], cwd=base, env=environment, stdin=subprocess.DEVNULL, stdout=writer, stderr=subprocess.PIPE)
            assert select.select([receiver],[],[],10)[0], scenario
            assert pipe.poll() is None, scenario
            if scenario=="blocked-stdout-cancel":
                pipe.send_signal(signal.SIGINT)
            if scenario=="partial-stdout-close":
                prefix=receiver.recv(256)
                receiver.close()
            pipe.wait(timeout=12)
            # XNU sets FWASWRITTEN (0x10000) even for an ordinary child write;
            # F_SETFL cannot clear this kernel bookkeeping bit. Compare every
            # other flag exactly, especially O_NONBLOCK/ASYNC/APPEND.
            assert fcntl.fcntl(writer,fcntl.F_GETFL)&~0x10000==original_flags&~0x10000, (scenario,original_flags,fcntl.fcntl(writer,fcntl.F_GETFL),pipe.returncode)
            writer.close()
            output=prefix if scenario=="partial-stdout-close" else b""
            if scenario!="partial-stdout-close":
                receiver.settimeout(1)
                while data:=receiver.recv(65536):
                    output+=data
                receiver.close()
            diagnostic=pipe.stderr.read()
            status=7 if scenario=="blocked-stdout-deadline" else 8 if scenario=="blocked-stdout-cancel" else 9
            code="QUERY_TIMEOUT" if status==7 else "CANCELLED" if status==8 else "INTERNAL_ERROR"
            assert pipe.returncode==status and diagnostic.startswith((code+":").encode()), (scenario,pipe.returncode,diagnostic,output[:256])
            assert output.startswith(b'{"schemaVersion":"1.0"') and not output.endswith(b"\n")
            assert len(output)+len(diagnostic)<=8388608 and str(base).encode() not in diagnostic
            clean()
            report["negativeCases"].append({"scenario":scenario,"transport":"unix-domain socket stdout","sendBufferBytes":send_buffer,"exitStatus":status,"partialSuccessBytes":len(output),"secondJsonFrameEmitted":False,"boundedCombinedOutput":True,"inheritedOutputFlagsRestored":True,"explicitCloseRemovedReadyOwnersAndLeases":True})
        receiver,writer=socket.socketpair()
        writer.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,1024)
        original_flags=fcntl.fcntl(writer,fcntl.F_GETFL)
        merged = subprocess.Popen([str(executable),"threads",str(ROOT / "Fixtures/traces/hiprofiler_data_ability.htrace"),"--json","--no-cache","--timeout-ms","10000"],cwd=base,env=environment,stdin=subprocess.DEVNULL,stdout=writer,stderr=subprocess.STDOUT)
        assert select.select([receiver],[],[],10)[0]
        assert merged.poll() is None
        merged.wait(timeout=12)
        assert merged.returncode==7 and fcntl.fcntl(writer,fcntl.F_GETFL)&~0x10000==original_flags&~0x10000
        writer.close()
        receiver.settimeout(1)
        output=b""
        while data:=receiver.recv(65536):
            output+=data
        receiver.close()
        assert output.startswith(b'{"schemaVersion":"1.0"') and not output.endswith(b"\n") and len(output)<=8388608
        clean()
        report["negativeCases"].append({"scenario":"blocked-merged-stdout-stderr","exitStatus":7,"transport":"unix-domain socket shared by stdout/stderr","partialSuccessBytes":len(output),"secondJsonFrameEmitted":False,"boundedCombinedOutput":True,"inheritedOutputFlagsRestored":True,"explicitCloseRemovedReadyOwnersAndLeases":True})
        for number, blocked, marker in [(signal.SIGINT,False,"source.systrace"),(signal.SIGTERM,False,"partial.db"),(signal.SIGINT,True,"partial.db")]:
            large = ROOT / "Fixtures/traces/trace_small_10.systrace"
            setup=(lambda: signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGINT,signal.SIGTERM})) if blocked else None
            process = subprocess.Popen([str(executable), "inspect", str(large), "--json", "--no-cache", *limits], cwd=base, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,preexec_fn=setup)
            until = time.monotonic() + 10
            while not list(session_root.glob(".staging/session-*/"+marker)):
                assert process.poll() is None
                assert time.monotonic() < until
                time.sleep(0.005)
            process.send_signal(number)
            stdout, stderr = process.communicate(timeout=15)
            assert process.returncode == 8 and not stderr, (process.returncode, stdout, stderr)
            value = json.loads(stdout)
            assert value["error"]["code"] == "CANCELLED" and value["tool"]["buildRevision"] == app["executableSHA256"]
            clean()
            report["negativeCases"].append({"scenario": signal.Signals(number).name + ("-inherited-blocked" if blocked else ""), "observedPrivateMarker":marker, "exitStatus": 8, "error": value["error"], "explicitCloseRemovedReadyOwnersAndLeases": True})
        resource = relocated / "Contents/Resources/ArkTraceRust/runtime.json"
        old = resource.read_bytes()
        resource.write_bytes(old.replace(b'"maximumSourceBytes": 1073741824', b'"maximumSourceBytes": 1073741825'))
        error("broken-resource-seal", ["inspect", first_trace, "--json", "--no-cache"], "INTERNAL_ERROR", 9)
        resource.write_bytes(old)
        assert not (base / "untrusted-temp").exists() and not (base / "untrusted-home").exists()
        assert digest(executable) == app["executableSHA256"]
        for fixture in oracle["corpus"]:
            assert digest(ROOT / fixture["path"]) == fixture["sha256"]
        clean()
        report.update({"toolExecutableSHA256": app["executableSHA256"], "defaultExecutableSHA256": production["executableSHA256"], "helperExecutableSHA256": app["helperSHA256"], "parserExecutableSHA256": app["parserSHA256"], "relocatedBundleSealedResources": True, "kernelMappedExecutableIdentity": True, "spoofedArgvZeroAndTemporaryEnvironmentIgnored": True, "prettyAndHumanAndEmpty": True, "rawInputsAndOriginalParserUnchanged": True})
        shutil.rmtree(session_root)
        shutil.rmtree(base)
        report["ownedTemporaryRootRemoved"] = True
        print(json.dumps(report, sort_keys=True))
    except BaseException:
        (base / "partial-cli-report.json").write_text(json.dumps(report, sort_keys=True))
        sys.stderr.write(f"Failed CLI check preserved its private root: {base}\n")
        raise


if __name__ == "__main__":
    main()

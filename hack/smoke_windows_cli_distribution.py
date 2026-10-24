#!/usr/bin/env python3
"""Smoke an extracted Windows ArkTrace CLI distribution outside the repository.

    python hack/smoke_windows_cli_distribution.py <distribution ZIP> <new absolute work directory>

Extracts the verified ZIP, then from a renamed copy runs, with only
PATH/SystemRoot/WINDIR and NUL stdin: ArkDeck's doctor argv, `licenses --json`,
ArkDeck's summary argv and an `analyze --kind cpu` on a staged copy of
test/fixtures/traces/zlib.htrace. It then moves the tree again and re-runs doctor, and
checks tamper refusals (a modified license file, an extra license file, a
replaced parser). A clean host (no toolchain or VC++ runtime) is NOT covered.
"""
import argparse
import importlib.util
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verifier = load("verify_windows_cli_distribution")
# One module instance, so one ContractError class.
contract = verifier.contract
SYSTEM_ROOT = os.environ.get("SystemRoot", r"C:\Windows")
ENVIRONMENT = {"PATH": SYSTEM_ROOT + r"\System32", "SystemRoot": SYSTEM_ROOT, "WINDIR": SYSTEM_ROOT}
CAPTURES = None
CAPTURE_NUMBER = 0


def run(tree, *args, timeout=180, working_directory=None):
    global CAPTURE_NUMBER
    executable = str(tree / 'arktrace.exe')
    result = subprocess.run([executable, *args], executable=executable, stdin=subprocess.DEVNULL,
                            capture_output=True, env=ENVIRONMENT,
                            cwd=str(working_directory or tree.parent), timeout=timeout)
    CAPTURE_NUMBER += 1
    name = f'{CAPTURE_NUMBER:03d}-{args[0].lstrip("-")}'
    (CAPTURES / (name + '.stdout')).write_bytes(result.stdout)
    (CAPTURES / (name + '.stderr')).write_bytes(result.stderr)
    (CAPTURES / (name + '.json')).write_text(json.dumps({
        'argv': [str(tree / 'arktrace.exe'), *args], 'exit': result.returncode,
        'stdoutSha256': hashlib.sha256(result.stdout).hexdigest(),
        'stderrSha256': hashlib.sha256(result.stderr).hexdigest(),
    }, indent=2) + '\n', encoding='utf-8')
    document = None
    if result.stdout:
        try:
            document = json.loads(result.stdout)
        except json.JSONDecodeError:
            document = None
    return result.returncode, document, result.stdout, result.stderr


def check(name, condition, results):
    results.append({"check": name, "pass": bool(condition)})


def main():
    global CAPTURES
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('distribution', type=Path)
    parser.add_argument('work', type=Path)
    parser.add_argument('--storage-root', type=Path,
                        help='existing owner-private host root; validated by the CLI on every call')
    options = parser.parse_args()
    archive, work = options.distribution, options.work
    if options.storage_root is not None:
        if not options.storage_root.is_absolute() or not options.storage_root.is_dir():
            raise SystemExit('storage root must be an existing absolute host-owned directory')
        ENVIRONMENT['ARKTRACE_STORAGE_ROOT'] = str(options.storage_root)
    if not work.is_absolute() or work.exists():
        raise SystemExit("work directory must be absolute and absent")
    work.mkdir(parents=True)
    CAPTURES = work / 'captures'
    CAPTURES.mkdir()
    results = []
    extracted = verifier.extract(archive, work / "extract")
    verifier.verify_tree(extracted)
    tree = work / "Install Copy ArkTrace 安装"
    shutil.copytree(extracted, tree)
    source = work / "trace source"
    source.mkdir()
    trace = source / "zlib.htrace"
    shutil.copyfile(ROOT / "test/fixtures/traces/zlib.htrace", trace)
    manifest = json.loads((tree / contract.MANIFEST_NAME).read_text(encoding="utf-8"))
    tool_sha = manifest["tool"]["binarySHA256"]
    parser_sha = manifest["traceStreamer"]["binarySHA256"]

    doctor = ("doctor", "--self-test", "--json", "--no-cache", "--timeout-ms", "120000", "--max-output-bytes", "262144")
    code, document, _, stderr = run(tree, *doctor)
    check("doctor exit 0, 9 ok checks, empty stderr", code == 0 and not stderr and document
          and [c["status"] for c in document["result"]["checks"]] == ["ok"] * 9, results)
    check("doctor buildRevision is the signed tool SHA", document and document["tool"]["buildRevision"] == tool_sha,
          results)

    code, document, _, stderr = run(tree, "licenses", "--json")
    licenses_result = (document or {}).get('result', {})
    files = licenses_result.get('licenseFiles', [])
    windows = licenses_result.get('windows', {}).get('licenseFiles', [])
    rust = licenses_result.get('rust', {})
    # Windows: one entry per (owner, file); the GPL text serves the GCC tool and runtime.
    check("licenses exit 0, 18 + 7 entries over 6 Windows files, counts 14/2/3/3", code == 0 and not stderr
          and document and len(files) == 18 and len(windows) == 7
          and len({f["resource"] for f in windows}) == 6 and document["result"]["componentCount"] == 14
          and document["result"]["buildToolCount"] == 2 and document["result"]["windows"]["buildToolCount"] == 3
          and document["result"]["windows"]["staticRuntimeCount"] == 3, results)
    check('licenses includes the frozen 37 Rust dependencies and 76 texts',
          rust.get('dependencyCount') == 37 and len(rust.get('licenseFiles', [])) == 76
          and rust.get('inventory') == 'rust/dependency-licenses.json', results)
    code, _, human, _ = run(tree, "licenses")
    check("human licenses lists the GCC runtime exception", code == 0 and b"GCC-exception-3.1" in human, results)
    code, _, human, _ = run(tree, '--help')
    check('help exposes the licenses command', code == 0 and b'licenses' in human, results)
    for format_args in (('--json',), ()):
        code, document, stdout, stderr = run(tree, 'licenses', *format_args, '--max-output-bytes', '1024')
        error_only = (document and document.get('error', {}).get('code') == 'OUTPUT_LIMIT_EXCEEDED'
                      and 'result' not in document and not stderr) if format_args else (not stdout and stderr)
        check('licenses output budget returns only a complete error ' + repr(format_args),
              code != 0 and error_only, results)

    summary = ("summary", "--json", "--no-cache", "--timeout-ms", "30000", "--max-rows", "1000", "--max-events",
               "10000", "--max-output-bytes", "8388608", str(trace))
    code, document, raw, stderr = run(tree, *summary)
    check("summary exit 0, signed parser identity, provenance", code == 0 and not stderr and document
          and document["trace"]["parser"]["binarySha256"] == parser_sha
          and document["provenance"]["indexSchemaVersion"] == 4
          and document["provenance"]["parserBuildRecipeVersion"] == manifest["traceStreamer"]["buildRecipeVersion"],
          results)
    check("summary leaks no source or drive path", str(trace).encode() not in raw and b":\\\\" not in raw, results)
    inspect = ('inspect', '--json', '--no-cache', '--timeout-ms', '30000', '--max-rows', '1000',
               '--max-events', '10000', '--max-output-bytes', '8388608', str(trace))
    code, document, _, stderr = run(tree, *inspect)
    check('inspect exit 0 with the same parser and index identity', code == 0 and not stderr and document
          and document['trace']['parser']['binarySha256'] == parser_sha
          and document['result']['indexSchemaVersion'] == 4, results)
    analyze = ("analyze", "--json", "--no-cache", "--timeout-ms", "60000", "--max-rows", "1000", "--max-events",
               "10000", "--max-output-bytes", "8388608", "--kind", "cpu", "--threshold-ns", "1000000", "--limit",
               "20", str(trace))
    code, document, _, stderr = run(tree, *analyze)
    check("analyze cpu exit 0", code == 0 and not stderr and document and document["result"] is not None, results)

    artifact_trace = source / 'ART-htrace'
    shutil.copyfile(trace, artifact_trace)
    for command in (summary, inspect, analyze):
        code, document, _, stderr = run(tree, *command[:-1], str(artifact_trace))
        check(command[0] + ' accepts an extensionless htrace Artifact ID',
              code == 0 and not stderr and document and document.get('result') is not None, results)
    systrace = source / 'ART-systrace'
    shutil.copyfile(ROOT / 'test/fixtures/traces/trace_small_10.systrace', systrace)
    code, document, _, stderr = run(tree, *summary[:-1], str(systrace))
    check('summary accepts an extensionless systrace Artifact ID',
          code == 0 and not stderr and document and document.get('result') is not None, results)
    unsupported = source / 'unsupported.txt'
    shutil.copyfile(trace, unsupported)
    code, document, _, _ = run(tree, *summary[:-1], str(unsupported))
    check('an explicit unsupported suffix still refuses', code != 0 and document
          and document.get('error', {}).get('code') == 'TRACE_FORMAT_UNSUPPORTED', results)

    # WinTrust can terminate an application whose own filename exceeds the
    # legacy caller limit. The CLI must reject before trust, with a complete
    # error. Before executable identity is available, the existing CLI contract
    # uses its path-free stderr error instead of inventing a Machine tool identity.
    # The launch itself uses an explicit application path.
    long_tree = work / ('long' * 56) / 'install'
    shutil.copytree(tree, long_tree)
    assert len(str(long_tree / 'arktrace.exe').encode('utf-16-le')) // 2 >= 260
    code, document, _, stderr = run(long_tree, 'licenses', '--json', working_directory=work)
    check('an overlong installation returns a typed error before native trust',
          code == 9 and document is None
          and stderr == b'INTERNAL_ERROR: ArkTrace encountered an internal error.\n', results)

    moved = work / "moved again"
    if not tree.resolve().is_relative_to(work.resolve()) or moved.exists() or moved.parent.resolve() != work.resolve():
        raise SystemExit('smoke move escaped its new private work directory')
    shutil.move(str(tree), str(moved))
    code, document, _, _ = run(moved, *doctor)
    check("doctor after moving the tree", code == 0 and document
          and [c["status"] for c in document["result"]["checks"]] == ["ok"] * 9, results)

    license_file = moved / "resources/licenses/LICENSES/zlib-Zlib.txt"
    original = license_file.read_bytes()
    license_file.write_bytes(original + b"\n")
    code, document, _, _ = run(moved, "licenses", "--json")
    check("modified license file refuses licenses", code != 0, results)
    license_file.write_bytes(original)
    extra = moved / "resources/licenses/LICENSES-windows/extra.txt"
    extra.write_bytes(b"undeclared\n")
    code, _, _, _ = run(moved, "licenses", "--json")
    check("extra license file refuses licenses", code != 0, results)
    extra.unlink()
    rust_license = moved / 'resources/licenses' / next(iter(contract.RUST_LICENSES))
    original_rust = rust_license.read_bytes()
    rust_license.write_bytes(original_rust + b'\n')
    code, _, _, _ = run(moved, 'licenses', '--json')
    check('modified Rust license refuses licenses', code != 0, results)
    rust_license.write_bytes(original_rust)
    extra_rust = moved / 'resources/licenses/rust/licenses/extra'
    extra_rust.mkdir()
    code, _, _, _ = run(moved, 'licenses', '--json')
    check('extra Rust directory refuses licenses', code != 0, results)
    extra_rust.rmdir()
    parser = moved / contract.LAYOUT["parserExecutable"]
    original_parser = parser.read_bytes()
    parser.write_bytes(original_parser[:-1] + bytes([original_parser[-1] ^ 1]))
    code, _, _, _ = run(moved, *summary)
    check("modified parser refuses summary", code != 0, results)
    code, _, _, _ = run(moved, *doctor)
    check("modified parser fails doctor", code != 0, results)
    try:
        verifier.verify_tree(moved)
        check("verifier refuses the modified parser", False, results)
    except contract.ContractError:
        check("verifier refuses the modified parser", True, results)
    parser.write_bytes(original_parser)
    code, _, _, _ = run(moved, *doctor)
    check("restored tree passes doctor", code == 0, results)

    report = {"cleanHost": False,
              'storageRootMode': 'explicit-owner-private' if options.storage_root else 'known-folder',
              "results": results,
              "passed": sum(r["pass"] for r in results), "total": len(results)}
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    # Keep every native command's original bytes and the isolated copies for
    # review. A failed smoke must not erase the inputs that explain it.
    print(json.dumps(report, indent=2))
    sys.exit(0 if all(r["pass"] for r in results) else 1)


if __name__ == "__main__":
    main()

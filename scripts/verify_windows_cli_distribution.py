#!/usr/bin/env python3
"""Verify a Windows x64 ArkTrace CLI distribution (ZIP or extracted tree).

Refuses: schema/key/value drift, an extra, missing or modified file, a link or
reparse point, a case-insensitive name collision, a path escape, tree-digest
drift, runtime/parser-manifest/inventory inconsistency and — for the
`authenticode-publisher` policy — any executable whose Authenticode signature
is not valid for exactly the manifest's publisher (subject O=, else CN=).

    python verify_windows_cli_distribution.py <zip-or-directory> [--skip-signatures]

`--skip-signatures` exists for host-independent contract tests only; it is
not a verification of a release.
"""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

_spec = importlib.util.spec_from_file_location(
    "windows_cli_distribution", Path(__file__).resolve().parent / "windows_cli_distribution.py")
contract = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(contract)
require = contract.require


def extract(archive, destination):
    """A ZIP holding exactly one top-level distribution directory, every member
    a safe relative regular file (no absolute/escaping/colliding names)."""
    with zipfile.ZipFile(archive) as bundle:
        names, folded, tops = [], set(), set()
        entries = bundle.infolist()
        require(len(entries) <= contract.MAXIMUM_FILES + len(contract.DIRECTORIES) + 2, 'archive entry count')
        require(sum(info.file_size for info in entries) <= contract.MAXIMUM_TOTAL_BYTES, 'archive size')
        for info in entries:
            name = info.filename
            # Validate the raw spelling before PurePosixPath can collapse './'
            # or repeated separators into an otherwise acceptable path.
            path = PurePosixPath(*contract.safe_relative(name[:-1] if info.is_dir() else name))
            kind = (info.external_attr >> 16) & 0o170000
            require(kind in ((0, 0o040000) if info.is_dir() else (0, 0o100000)), 'archive entry kind')
            require(not info.flag_bits & 1, 'encrypted archive')
            require(path.as_posix().lower() not in folded, "archive case-insensitive collision")
            folded.add(path.as_posix().lower())
            tops.add(path.parts[0])
            if info.is_dir():
                require(len(path.parts) == 1 or '/'.join(path.parts[1:]) in contract.DIRECTORIES,
                        'archive undeclared directory')
            else:
                require(len(path.parts) >= 2, "archive top-level file")
                require(0 < info.file_size <= contract.MAXIMUM_FILE_BYTES, "archive member size")
                names.append(info)
        require(len(tops) == 1 and len(names) <= contract.MAXIMUM_FILES + 1, "archive shape")
        top = tops.pop()
        contract.safe_relative(top)
        for info in names:
            target = destination.joinpath(*PurePosixPath(info.filename).parts)
            require(target.resolve().is_relative_to(destination.resolve()), "archive path escape")
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(info) as source, open(target, "xb") as sink:
                shutil.copyfileobj(source, sink)
        return destination / top


def signer(path):
    """(status, subject) of the embedded Authenticode signature."""
    literal = "'" + str(path).replace("'", "''") + "'"
    script = ("$s = Get-AuthenticodeSignature -LiteralPath " + literal + "; "
              "[Console]::Out.Write((@{status=[string]$s.Status; "
              "subject=$(if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { '' }); "
              "timestamped=($null -ne $s.TimeStamperCertificate)} | ConvertTo-Json -Compress))")
    # Windows PowerShell must not inherit a PowerShell 7 module path.
    environment = {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}
    powershell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    result = subprocess.run([str(powershell), "-NoProfile", "-NonInteractive", "-Command", script],
                            capture_output=True, text=True, timeout=60, env=environment)
    require(result.returncode == 0 and not result.stderr.strip(), "signature query")
    value = json.loads(result.stdout)
    require(value.get("status") and type(value.get('timestamped')) is bool, "signature query")
    return value["status"], value["subject"], value['timestamped']


def publisher_of(subject):
    """ArkTrace's Windows trust rule: the single O= value, else the single CN=."""
    if not isinstance(subject, str) or len(subject) > 8192:
        return None
    parts, current, quoted, escaped = [], [], False, False
    for char in subject:
        if escaped:
            current.extend(('\\', char))
            escaped = False
        elif char == '\\':
            escaped = True
        elif char == '"':
            quoted = not quoted
            current.append(char)
        elif char in ',+' and not quoted:
            parts.append(''.join(current))
            current = []
        else:
            current.append(char)
    if quoted or escaped:
        return None
    parts.append(''.join(current))
    fields = {}
    for part in parts:
        key, separator, value = part.strip().partition('=')
        if not separator or not key.strip():
            return None
        value = value.strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1].replace('""', '"')
        decoded = bytearray()
        index = 0
        while index < len(value):
            if value[index] == '\\':
                index += 1
                if index >= len(value):
                    return None
                if len(value) - index >= 2 and all(c in '0123456789abcdefABCDEF' for c in value[index:index + 2]):
                    decoded.append(int(value[index:index + 2], 16))
                    index += 2
                    continue
            decoded.extend(value[index].encode('utf-8'))
            index += 1
        try:
            text = decoded.decode('utf-8')
        except UnicodeDecodeError:
            return None
        if not text or text.strip() != text or any(ord(c) < 32 or ord(c) == 127 for c in text):
            return None
        fields.setdefault(key.strip().upper(), []).append(text)
    for key in ("O", "CN"):
        if key in fields:
            return fields[key][0] if len(fields[key]) == 1 else None
    return None


def verify_tree(root, skip_signatures=False):
    root = Path(root)
    tree_files = contract.walk_tree(root)
    manifest_path = root / contract.MANIFEST_NAME
    require(manifest_path.is_file() and not manifest_path.is_symlink()
            and manifest_path.stat().st_size <= contract.MAXIMUM_MANIFEST_BYTES, "manifest missing or oversized")
    contract_manifest_bytes = manifest_path.read_bytes()
    manifest = contract.strict_load(contract_manifest_bytes)
    contract.validate_manifest(manifest)
    facts = {}
    for relative, path in tree_files:
        if relative == contract.MANIFEST_NAME:
            continue
        facts[relative] = (path.stat().st_size, contract.sha256_file(path))
    contract.cross_check(manifest, facts)
    contract.cross_check_content(manifest, lambda relative: (root / relative).read_bytes())
    for relative in contract.EXECUTABLES:
        imports = contract.pe_imports(root / relative)
        if relative == contract.LAYOUT['parserExecutable']:
            parser = contract.strict_load((root / contract.LAYOUT['parserManifest']).read_bytes())
            require(isinstance(parser.get('imports'), list)
                    and all(isinstance(name, str) for name in parser['imports'])
                    and imports == sorted({name.lower() for name in parser['imports']}), 'parser DLL imports')
    # Re-measure after the content reads: nothing changed underneath.
    for relative, (byte_count, digest) in facts.items():
        require(contract.sha256_file(root / relative) == digest, "file changed during verification")
    signatures = []
    if manifest["signing"]["policy"] == "authenticode-publisher" and not skip_signatures:
        for relative in contract.EXECUTABLES:
            status, subject, timestamped = signer(root / relative)
            require(status == "Valid", "signature not valid")
            require(publisher_of(subject) == manifest["signing"]["publisher"], "wrong signer publisher")
            require(not manifest['signing']['timestamped'] or timestamped, 'missing signature timestamp')
            signatures.append({"path": relative, "status": status, "publisher": publisher_of(subject),
                               'timestamped': timestamped})
    # Signature queries are external calls. Re-enumerate and remeasure after
    # them too, rather than accepting bytes that changed during trust checking.
    final_facts = {relative: (path.stat().st_size, contract.sha256_file(path))
                   for relative, path in contract.walk_tree(root) if relative != contract.MANIFEST_NAME}
    require(final_facts == facts and (root / contract.MANIFEST_NAME).read_bytes() == contract_manifest_bytes,
            'file changed during verification')
    return {"verified": True, "treeSHA256": manifest["integrity"]["treeSHA256"],
            "fileCount": manifest["integrity"]["fileCount"], "signingPolicy": manifest["signing"]["policy"],
            "publisher": manifest["signing"]["publisher"], "signatures": signatures,
            "signaturesChecked": bool(signatures)}


def verify(target, skip_signatures=False):
    try:
        target = Path(target)
        if target.is_dir():
            return verify_tree(target, skip_signatures)
        require(target.is_file() and target.suffix.lower() == ".zip", "distribution input")
        work = Path(tempfile.mkdtemp(prefix="arktrace-verify-")).resolve()
        temporary_root = Path(tempfile.gettempdir()).resolve()
        require(work.parent == temporary_root, 'verification temporary root')
        try:
            return verify_tree(extract(target, work), skip_signatures)
        finally:
            if work.resolve().parent == temporary_root and not work.is_symlink():
                shutil.rmtree(work, ignore_errors=True)
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile, NotImplementedError):
        raise contract.ContractError('distribution input invalid or unreadable') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("distribution", type=Path)
    parser.add_argument("--skip-signatures", action="store_true")
    options = parser.parse_args()
    try:
        print(json.dumps(verify(options.distribution, options.skip_signatures), sort_keys=True))
    except contract.ContractError as error:
        print(json.dumps({"verified": False, "reason": str(error)}, sort_keys=True))
        sys.exit(1)


if __name__ == "__main__":
    main()

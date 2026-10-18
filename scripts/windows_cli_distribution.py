#!/usr/bin/env python3
"""Closed Windows x64 ArkTrace CLI distribution contract (AT-RUST-016).

Shared by package_windows_cli_distribution.py, verify_windows_cli_distribution.py
and test_windows_cli_distribution_contract.py. The schema mirrors
contracts/distribution/arktrace-cli-distribution-windows-x86_64-v1.schema.json;
the contract test keeps the two key closures equal.

Trust (ArkDeck TASK-XPA-021 maintainer rulings, 2026-10-14):
  (a) the parser is ArkTrace's in-repo Windows recipe (its committed manifest);
  (b) Authenticode signer pinned by publisher identity (never a leaf hash) plus
      every file's SHA-256 and byte count;
  (c) the NTFS tree digest is the macOS record format with a fixed
      manifest-declared executable marker instead of a POSIX mode, under a
      platform prefix, so it can never equal a macOS digest.
"""
import hashlib
import json
import re
import shutil
import stat
import struct
from pathlib import Path

SCHEMA = "arktrace.cli-distribution.windows-x86_64/1"
TREE_DIGEST = "arktrace-windows-x86_64-tree/1"
MANIFEST_NAME = "distribution-manifest.json"
PRODUCT = {"name": "arktrace", "version": "0.1.0", "build": "1", "architecture": "x86_64",
           "jsonContract": {"major": 1, "minor": 0}}
LAYOUT = {
    "executable": "arktrace.exe",
    "helperExecutable": "resources/Helpers/arktrace-host-process.exe",
    "parserExecutable": "resources/Helpers/trace_streamer.exe",
    "parserManifest": "resources/TraceStreamer/manifest.json",
    "runtimeManifest": "resources/ArkTraceRust/runtime.json",
    "selfTestFixture": "resources/zlib.htrace",
    "licenseDirectory": "resources/licenses",
}
EXECUTABLES = sorted([LAYOUT["executable"], LAYOUT["helperExecutable"], LAYOUT["parserExecutable"]])
PROVENANCE = {"parserAdapterVersion": "1", "schemaAdapterVersion": "2", "indexSchemaVersion": 4}
UPGRADE_POLICY = {"identity": "distribution-manifest+tool-parser-hashes", "installMode": "versioned-directory",
                  "pathSelection": "reviewed-absolute-descriptor-only", "rollback": "retain-prior-exact-directory"}
SIGNING_POLICIES = ("authenticode-publisher", "development-pinned")
SELF_TEST_SHA256 = "eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe"
STORAGE_NAMESPACE = "com.arktrace.ArkTrace.CLI"
LICENSE_FILE_COUNT = 18
WINDOWS_LICENSE_FILE_COUNT = 6
ROOT = Path(__file__).resolve().parent.parent
RUST_INVENTORY_BYTES = (ROOT / 'rust/dependency-licenses.json').read_bytes()
RUST_DEPENDENCIES = json.loads(RUST_INVENTORY_BYTES)['dependencies']
RUST_LICENSES = {entry['path']: (entry['byteCount'], entry['sha256'])
                 for dependency in RUST_DEPENDENCIES for entry in dependency['licenseTexts']}
RUST_DEPENDENCY_COUNT = len(RUST_DEPENDENCIES)
RUST_LICENSE_FILE_COUNT = len(RUST_LICENSES)
MAXIMUM_FILES = 256
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 64 * 1024
MAXIMUM_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAXIMUM_SOURCE_BYTES = 1024 * 1024 * 1024
MAXIMUM_DATABASE_BYTES = 4 * 1024 * 1024 * 1024
DIRECTORIES = {
    'resources', 'resources/Helpers', 'resources/TraceStreamer',
    'resources/ArkTraceRust', 'resources/licenses',
    'resources/licenses/LICENSES', 'resources/licenses/LICENSES-windows',
}
for _relative in ['rust/dependency-licenses.json', *RUST_LICENSES]:
    DIRECTORIES.update('resources/licenses/' + parent.as_posix()
                       for parent in Path(_relative).parents if parent.as_posix() != '.')
SYSTEM_DLLS = {
    'advapi32.dll', 'bcrypt.dll', 'bcryptprimitives.dll', 'cabinet.dll',
    'combase.dll', 'comctl32.dll', 'comdlg32.dll', 'crypt32.dll', 'dbghelp.dll', 'gdi32.dll',
    'imm32.dll', 'iphlpapi.dll', 'kernel32.dll', 'kernelbase.dll', 'msvcrt.dll',
    'ncrypt.dll', 'netapi32.dll', 'ntdll.dll', 'ole32.dll', 'oleaut32.dll',
    'powrprof.dll', 'profapi.dll', 'psapi.dll', 'rpcrt4.dll', 'secur32.dll',
    'setupapi.dll', 'shell32.dll', 'shlwapi.dll', 'ucrtbase.dll', 'user32.dll',
    'userenv.dll', 'version.dll', 'winhttp.dll', 'winmm.dll', 'wintrust.dll',
    'ws2_32.dll', 'wtsapi32.dll',
}
SHA = re.compile(r"^[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
COMPONENT = re.compile(r"^[A-Za-z0-9_.+-]+$")

KEYS = {
    "": ["schema", "formatVersion", "source", "product", "layout", "tool", "helper", "traceStreamer",
         "provenance", "signing", "integrity", "attribution", "upgradePolicy"],
    "source": ["revision", "dirty"],
    "product": ["name", "version", "build", "architecture", "jsonContract"],
    "product.jsonContract": ["major", "minor"],
    "layout": list(LAYOUT),
    "tool": ["binarySHA256", "byteCount", "unsignedBinarySHA256"],
    "helper": ["binarySHA256", "byteCount", "unsignedBinarySHA256"],
    "traceStreamer": ["unsignedBinarySHA256", "binarySHA256", "byteCount", "manifestSHA256", "manifestByteCount",
                      "reportedVersion", "upstreamRevision", "buildRecipeVersion"],
    "provenance": list(PROVENANCE),
    "signing": ["policy", "publisher", "timestamped"],
    "integrity": ["treeDigest", "treeSHA256", "fileCount", "executables", "files"],
    "integrity.files[]": ["path", "sha256", "byteCount"],
    "attribution": ["license", "licenseSHA256", "licenseByteCount", "notice", "noticeSHA256", "noticeByteCount",
                    "inventory", "inventorySHA256", "inventoryByteCount", "windowsInventory",
                    "windowsInventorySHA256", "windowsInventoryByteCount", "licenseFileCount",
                    "windowsLicenseFileCount", "selfTestFixtureSHA256", "selfTestFixtureByteCount"],
    "upgradePolicy": list(UPGRADE_POLICY),
}
KEYS['attribution'] += ['rustInventory', 'rustInventorySHA256', 'rustInventoryByteCount',
                        'rustDependencyCount', 'rustLicenseFileCount']


class ContractError(Exception):
    """A closed, path-free refusal reason."""


def require(condition, reason):
    if not condition:
        raise ContractError(reason)


def sha256_file(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def stage_attribution(source_root, destination):
    """Stage the same closed attribution set in development and signed installs."""
    source_root, destination = Path(source_root), Path(destination)
    sources = {
        'LICENSE': source_root / 'LICENSE',
        'THIRD_PARTY_NOTICES.md': source_root / 'THIRD_PARTY_NOTICES.md',
        'license-inventory.json': source_root / 'ThirdParty/TraceStreamer/license-inventory.json',
        'windows-license-inventory.json': source_root / 'ThirdParty/TraceStreamer/windows-license-inventory.json',
        'rust/dependency-licenses.json': source_root / 'rust/dependency-licenses.json',
    }
    sources.update({relative: source_root / relative for relative in RUST_LICENSES})
    for directory in ('LICENSES', 'LICENSES-windows'):
        for path in (source_root / 'ThirdParty/TraceStreamer' / directory).iterdir():
            sources[directory + '/' + path.name] = path
    for relative, source in sorted(sources.items()):
        safe_relative(relative)
        require(source.is_file() and not source.is_symlink()
                and not getattr(source.lstat(), 'st_file_attributes', 0) & 0x400
                and source.resolve().is_relative_to(source_root.resolve()), 'attribution source')
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


def safe_relative(path):
    """A closed relative spelling: '/'-separated plain components."""
    require(isinstance(path, str) and 0 < len(path) <= 512, "path spelling")
    parts = path.split("/")
    reserved = {'con', 'prn', 'aux', 'nul'} | {prefix + str(n) for prefix in ('com', 'lpt') for n in range(1, 10)}
    require(all(COMPONENT.fullmatch(p) and p not in (".", "..") and not p.endswith('.')
                and p.split('.')[0].lower() not in reserved for p in parts), "path spelling")
    return parts


def tree_digest(records, executables):
    """Ruling (c). `records` are (path, byteCount, sha256) of every file below
    the distribution root except the manifest itself."""
    executables = set(executables)
    hasher = hashlib.sha256()
    hasher.update(TREE_DIGEST.encode() + b"\0")
    for path, byte_count, digest in sorted(records, key=lambda r: r[0].encode("utf-8")):
        hasher.update(b"F\0")
        hasher.update(b"x" if path in executables else b"r")
        hasher.update(b"\0" + path.encode("utf-8") + b"\0")
        hasher.update(str(byte_count).encode() + b"\0")
        hasher.update(digest.encode() + b"\0")
    return hasher.hexdigest()


def walk_tree(root):
    """Every file below `root` as (relative path, Path): no link, reparse
    point, empty file, device or case-insensitive name collision."""
    root = Path(root)
    found, folded = [], set()

    def visit(directory, prefix):
        for entry in sorted(directory.iterdir(), key=lambda p: p.name):
            info = entry.lstat()
            reparse = getattr(info, "st_file_attributes", 0) & 0x400
            require(not stat.S_ISLNK(info.st_mode) and not reparse, "linked entry")
            relative = prefix + entry.name
            safe_relative(relative)
            require(relative.lower() not in folded, "case-insensitive name collision")
            folded.add(relative.lower())
            if stat.S_ISDIR(info.st_mode):
                require(relative in DIRECTORIES, "undeclared directory")
                visit(entry, relative + "/")
            else:
                require(stat.S_ISREG(info.st_mode), "non-regular entry")
                require(info.st_nlink == 1, 'multiply-linked file')
                require(0 < info.st_size <= MAXIMUM_FILE_BYTES, "empty or oversized file")
                found.append((relative, entry))
                require(len(found) <= MAXIMUM_FILES, "too many files")

    require(root.is_dir() and not root.is_symlink()
            and not getattr(root.lstat(), 'st_file_attributes', 0) & 0x400, "distribution root")
    visit(root, "")
    return found


def strict_load(data):
    """JSON with no duplicate keys and no non-integral numbers where integers appear."""
    def pairs(items):
        keys = [k for k, _ in items]
        require(len(keys) == len(set(keys)), "duplicate JSON key")
        return dict(items)

    def no_float(_):
        raise ContractError("float value")

    require(len(data) <= MAXIMUM_MANIFEST_BYTES, "manifest size")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_float=no_float,
                          parse_constant=no_float)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError):
        raise ContractError("manifest JSON")


def _keys(value, expected, where):
    require(isinstance(value, dict) and sorted(value) == sorted(expected), "key closure: " + where)


def _sha(value, where):
    require(isinstance(value, str) and SHA.match(value), "sha256: " + where)


def _count(value, where):
    require(type(value) is int and 0 < value <= MAXIMUM_FILE_BYTES, "byte count: " + where)


def _exact(value, expected, where):
    """JSON booleans must never satisfy an integer constant."""
    require(type(value) is type(expected), where)
    if isinstance(expected, dict):
        _keys(value, expected, where)
        for key, wanted in expected.items():
            _exact(value[key], wanted, where)
    elif isinstance(expected, list):
        require(len(value) == len(expected), where)
        for item, wanted in zip(value, expected):
            _exact(item, wanted, where)
    else:
        require(value == expected, where)


def pe_imports(path):
    """Read bounded PE headers and normal/delay imports without loading code.

    Every shipped image must be PE32+ AMD64. Its DLL dependencies must be
    Windows system libraries, since this closed ZIP ships no runtime DLLs.
    """
    size = path.stat().st_size
    require(0 < size <= MAXIMUM_FILE_BYTES, 'PE size')
    with path.open('rb') as stream:
        def read(offset, count):
            require(0 <= offset <= size and 0 <= count <= 1024 * 1024 and count <= size - offset, 'PE bounds')
            stream.seek(offset)
            data = stream.read(count)
            require(len(data) == count, 'PE truncation')
            return data

        dos = read(0, 64)
        require(dos[:2] == b'MZ', 'PE signature')
        start = struct.unpack_from('<I', dos, 60)[0]
        require(64 <= start <= 1024 * 1024, 'PE header offset')
        coff = read(start, 24)
        require(coff[:4] == b'PE\0\0', 'PE signature')
        machine, count, _, _, _, optional_size, flags = struct.unpack_from('<HHIIIHH', coff, 4)
        require(machine == 0x8664 and 0 < count <= 96 and flags & 2 and 112 <= optional_size <= 4096,
                'PE architecture')
        optional = read(start + 24, optional_size)
        require(struct.unpack_from('<H', optional)[0] == 0x20b, 'PE architecture')
        headers = struct.unpack_from('<I', optional, 60)[0]
        directory_count = struct.unpack_from('<I', optional, 108)[0]
        require(directory_count <= 16 and 112 + 8 * directory_count <= optional_size, 'PE directories')
        table = read(start + 24 + optional_size, count * 40)
        sections = [struct.unpack_from('<IIII', table, n * 40 + 8) for n in range(count)]
        for _, _, raw_size, raw_offset in sections:
            require(raw_offset <= size and raw_size <= size - raw_offset, 'PE section bounds')

        def offset(rva, length):
            candidates = []
            if rva < headers and length <= headers - rva:
                candidates.append(rva)
            for _, virtual, raw_size, raw_offset in sections:
                if virtual <= rva and rva - virtual <= raw_size and length <= raw_size - (rva - virtual):
                    candidates.append(raw_offset + rva - virtual)
            require(len(candidates) == 1, 'PE RVA')
            return candidates[0]

        def name(rva):
            value = bytearray()
            for i in range(256):
                byte = read(offset(rva + i, 1), 1)[0]
                if byte == 0:
                    break
                value.append(byte)
            else:
                raise ContractError('PE import name')
            require(value and all(32 < byte < 127 for byte in value), 'PE import name')
            result = value.decode('ascii').lower()
            require(result in SYSTEM_DLLS or re.fullmatch(r'(?:api|ext)-ms-win-[a-z0-9-]+\.dll', result),
                    'unshipped DLL dependency: ' + result)
            return result

        imports = set()
        for index, stride, name_index in ((1, 20, 3), (13, 32, 1)):
            if index >= directory_count:
                continue
            rva, length = struct.unpack_from('<II', optional, 112 + index * 8)
            if rva == 0 and length == 0:
                continue
            require(rva > 0 and stride <= length <= 1024 * 1024, 'PE imports')
            for i in range(min(length // stride, 257)):
                words = struct.unpack('<' + 'I' * (stride // 4), read(offset(rva + i * stride, stride), stride))
                if not any(words):
                    break
                require(i < 256 and (index != 13 or words[0] == 1), 'PE imports')
                imports.add(name(words[name_index]))
            else:
                raise ContractError('PE import terminator')
        return sorted(imports)


def validate_manifest(manifest):
    """The closed schema and fixed contract values; tree facts are checked
    separately against the physical distribution."""
    _keys(manifest, KEYS[""], "root")
    require(manifest["schema"] == SCHEMA and manifest["formatVersion"] == 1 and type(manifest["formatVersion"]) is int,
            "schema")
    _keys(manifest["source"], KEYS["source"], "source")
    require(isinstance(manifest["source"]["revision"], str) and REVISION.match(manifest["source"]["revision"]),
            "source revision")
    require(type(manifest["source"]["dirty"]) is bool, "source dirty")
    _keys(manifest["product"], KEYS["product"], "product")
    _keys(manifest["product"]["jsonContract"], KEYS["product.jsonContract"], "jsonContract")
    _exact(manifest["product"], PRODUCT, "product")
    _keys(manifest["layout"], KEYS["layout"], "layout")
    require(manifest["layout"] == LAYOUT, "layout")
    for group in ("tool", "helper"):
        _keys(manifest[group], KEYS[group], group)
        _sha(manifest[group]["binarySHA256"], group)
        _sha(manifest[group]["unsignedBinarySHA256"], group)
        _count(manifest[group]["byteCount"], group)
    parser = manifest["traceStreamer"]
    _keys(parser, KEYS["traceStreamer"], "traceStreamer")
    for key in ("unsignedBinarySHA256", "binarySHA256", "manifestSHA256", "buildRecipeVersion"):
        _sha(parser[key], "traceStreamer." + key)
    _count(parser["byteCount"], "traceStreamer.byteCount")
    _count(parser["manifestByteCount"], "traceStreamer.manifestByteCount")
    require(isinstance(parser["reportedVersion"], str) and 0 < len(parser["reportedVersion"]) <= 64, "parser version")
    require(isinstance(parser["upstreamRevision"], str) and REVISION.match(parser["upstreamRevision"]),
            "parser upstream revision")
    _keys(manifest["provenance"], KEYS["provenance"], "provenance")
    require(manifest["provenance"] == PROVENANCE and type(manifest["provenance"]["indexSchemaVersion"]) is int,
            "provenance")
    signing = manifest["signing"]
    _keys(signing, KEYS["signing"], "signing")
    require(signing["policy"] in SIGNING_POLICIES and type(signing["timestamped"]) is bool, "signing policy")
    if signing["policy"] == "authenticode-publisher":
        require(isinstance(signing["publisher"], str) and 0 < len(signing["publisher"]) <= 256
                and signing["publisher"].strip() == signing["publisher"]
                and not any(ord(c) < 32 or ord(c) == 127 for c in signing["publisher"]), "signing publisher")
    else:
        require(signing["publisher"] is None and signing["timestamped"] is False, "development signing")
    integrity = manifest["integrity"]
    _keys(integrity, KEYS["integrity"], "integrity")
    require(integrity["treeDigest"] == TREE_DIGEST, "tree digest algorithm")
    _sha(integrity["treeSHA256"], "treeSHA256")
    require(integrity["executables"] == EXECUTABLES, "executables")
    files = integrity["files"]
    require(isinstance(files, list) and 0 < len(files) <= MAXIMUM_FILES
            and type(integrity["fileCount"]) is int and integrity["fileCount"] == len(files), "file count")
    folded = set()
    for entry in files:
        _keys(entry, KEYS["integrity.files[]"], "integrity.files[]")
        safe_relative(entry["path"])
        require(entry["path"] != MANIFEST_NAME, "manifest lists itself")
        require(entry["path"].lower() not in folded, "duplicate file")
        folded.add(entry["path"].lower())
        _sha(entry["sha256"], "file sha256")
        _count(entry["byteCount"], "file byte count")
    require([e["path"] for e in files] == sorted((e["path"] for e in files), key=lambda p: p.encode()),
            "file order")
    attribution = manifest["attribution"]
    _keys(attribution, KEYS["attribution"], "attribution")
    for name in ("license", "notice", "inventory", "windowsInventory", "rustInventory"):
        _sha(attribution[name + "SHA256"], name)
        _count(attribution[name + "ByteCount"], name)
    require(attribution["license"] == "resources/licenses/LICENSE"
            and attribution["notice"] == "resources/licenses/THIRD_PARTY_NOTICES.md"
            and attribution["inventory"] == "resources/licenses/license-inventory.json"
            and attribution["windowsInventory"] == "resources/licenses/windows-license-inventory.json"
            and attribution['rustInventory'] == 'resources/licenses/rust/dependency-licenses.json',
            "attribution paths")
    require(attribution["licenseFileCount"] == LICENSE_FILE_COUNT
            and attribution["windowsLicenseFileCount"] == WINDOWS_LICENSE_FILE_COUNT
            and type(attribution['rustDependencyCount']) is int
            and attribution['rustDependencyCount'] == RUST_DEPENDENCY_COUNT
            and type(attribution['rustLicenseFileCount']) is int
            and attribution['rustLicenseFileCount'] == RUST_LICENSE_FILE_COUNT, "license file counts")
    require(attribution["selfTestFixtureSHA256"] == SELF_TEST_SHA256, "self-test fixture")
    _count(attribution["selfTestFixtureByteCount"], "self-test fixture")
    _keys(manifest["upgradePolicy"], KEYS["upgradePolicy"], "upgradePolicy")
    require(manifest["upgradePolicy"] == UPGRADE_POLICY, "upgrade policy")


def cross_check(manifest, facts):
    """`facts`: path -> (byteCount, sha256) of the physical tree (manifest
    excluded). Binds every manifest identity to the measured bytes."""
    files = {e["path"]: (e["byteCount"], e["sha256"]) for e in manifest["integrity"]["files"]}
    require(set(files) == set(facts), "extra or missing file")
    require(all(files[p] == facts[p] for p in files), "file identity drift")
    require(tree_digest([(p, b, s) for p, (b, s) in facts.items()], EXECUTABLES)
            == manifest["integrity"]["treeSHA256"], "tree digest drift")
    layout = manifest["layout"]
    for group, key in (("tool", "executable"), ("helper", "helperExecutable"),
                       ("traceStreamer", "parserExecutable")):
        require(layout[key] in facts and facts[layout[key]] ==
                (manifest[group]["byteCount"], manifest[group]["binarySHA256"]), group + " identity")
    parser = manifest["traceStreamer"]
    require(facts.get(layout["parserManifest"]) == (parser["manifestByteCount"], parser["manifestSHA256"]),
            "parser manifest identity")
    attribution = manifest["attribution"]
    for name in ("license", "notice", "inventory", "windowsInventory", "rustInventory"):
        require(facts.get(attribution[name]) == (attribution[name + "ByteCount"], attribution[name + "SHA256"]),
                name + " identity")
    require(facts.get(layout["selfTestFixture"]) ==
            (attribution["selfTestFixtureByteCount"], attribution["selfTestFixtureSHA256"]), "self-test fixture")
    licenses = [p for p in facts if p.startswith("resources/licenses/LICENSES/")]
    windows = [p for p in facts if p.startswith("resources/licenses/LICENSES-windows/")]
    require(len(licenses) == attribution["licenseFileCount"]
            and len(windows) == attribution["windowsLicenseFileCount"], "license closure")
    rust = {'resources/licenses/' + relative: identity for relative, identity in RUST_LICENSES.items()}
    require(all(facts.get(relative) == identity for relative, identity in rust.items()), 'Rust license identity')
    allowed = set(layout[k] for k in LAYOUT if k != "licenseDirectory") | {
        attribution[n] for n in ("license", "notice", "inventory", "windowsInventory", "rustInventory")
    } | set(licenses) | set(windows) | set(rust)
    require(set(facts) == allowed, "undeclared file")


def cross_check_content(manifest, read):
    """Contents that bind identities: the parser manifest and runtime.json.
    `read(path) -> bytes` reads a measured distribution file."""
    layout, parser = manifest["layout"], manifest["traceStreamer"]
    parser_manifest = strict_load(read(layout["parserManifest"]))
    require(isinstance(parser_manifest, dict)
            and parser_manifest.get("binarySHA256") == parser["unsignedBinarySHA256"]
            and parser_manifest.get("buildRecipeVersion") == parser["buildRecipeVersion"]
            and parser_manifest.get("reportedVersion") == parser["reportedVersion"]
            and parser_manifest.get("upstreamRevision") == parser["upstreamRevision"]
            and parser_manifest.get("architecture") == "x86_64"
            and parser_manifest.get("signed") is False, "parser manifest content")
    runtime = strict_load(read(layout["runtimeManifest"]))
    identity_keys = ('name', 'reportedVersion', 'binarySHA256', 'upstreamRepository', 'upstreamRevision',
                     'architecture', 'adapterVersion', 'buildRecipeVersion')
    require(all(key in parser_manifest for key in identity_keys), 'parser manifest content')
    identity = {key: parser_manifest[key] for key in identity_keys}
    identity.update(name='trace_streamer', binarySHA256=parser['binarySHA256'])
    expected_runtime = {
        'formatVersion': 1, 'productVersion': PRODUCT['version'], 'architecture': 'x86_64',
        'development': manifest['signing']['policy'] == 'development-pinned',
        'helperSHA256': manifest['helper']['binarySHA256'],
        'unsignedParserSHA256': parser['unsignedBinarySHA256'], 'parser': identity,
        'maximumSourceBytes': MAXIMUM_SOURCE_BYTES, 'maximumDatabaseBytes': MAXIMUM_DATABASE_BYTES,
        'storageNamespace': STORAGE_NAMESPACE,
    }
    _exact(runtime, expected_runtime, 'runtime manifest content')
    inventory = strict_load(read(manifest["attribution"]["inventory"]))
    windows = strict_load(read(manifest["attribution"]["windowsInventory"]))
    require(read(manifest['attribution']['rustInventory']) == RUST_INVENTORY_BYTES, 'Rust inventory content')
    for document, sections in ((inventory, {'components': 14, 'buildTools': 2}),
                               (windows, {'buildTools': 3, 'staticRuntime': 3})):
        require(isinstance(document, dict), 'inventory content')
        for section, count in sections.items():
            require(isinstance(document.get(section), list) and len(document[section]) == count
                    and all(isinstance(entry, dict) for entry in document[section]), 'inventory content')
    measured = {entry['path']: (entry['byteCount'], entry['sha256']) for entry in manifest['integrity']['files']}

    def license_records(entries, prefix):
        names = set()
        for entry in entries:
            require(isinstance(entry.get('licenseFile'), str), 'inventory license path')
            records = [(entry['licenseFile'], entry.get('licenseByteCount'), entry.get('licenseSHA256'))]
            extra = entry.get('additionalLicenseFiles', [])
            require(isinstance(extra, list) and len(extra) <= 8, 'inventory additional files')
            for value in extra:
                require(isinstance(value, dict) and set(value) == {'path', 'byteCount', 'sha256'},
                        'inventory additional files')
                records.append((value['path'], value['byteCount'], value['sha256']))
            for path, count, digest in records:
                parts = safe_relative(path)
                require(len(parts) == 2 and parts[0] == prefix, 'inventory license path')
                _count(count, 'inventory license bytes')
                _sha(digest, 'inventory license digest')
                require(measured.get('resources/licenses/' + path) == (count, digest), 'inventory license identity')
                names.add(path)
        return names

    names = license_records(inventory['components'] + inventory['buildTools'], 'LICENSES')
    windows_names = license_records(windows['buildTools'] + windows['staticRuntime'], 'LICENSES-windows')
    require(len(names) == LICENSE_FILE_COUNT and len(windows_names) == WINDOWS_LICENSE_FILE_COUNT,
            "inventory closure")
    files = {e["path"] for e in manifest["integrity"]["files"]}
    require({"resources/licenses/" + n for n in names | windows_names}
            == {p for p in files if p.startswith("resources/licenses/LICENSES")}, "inventory file closure")


def manifest_schema():
    """The distributable JSON schema; generation is checked by the contract tests."""
    sha = {'type': 'string', 'pattern': '^[0-9a-f]{64}$'}
    count = {'type': 'integer', 'minimum': 1, 'maximum': MAXIMUM_FILE_BYTES}

    def constant(value):
        kind = {str: 'string', int: 'integer', bool: 'boolean', type(None): 'null'}
        if isinstance(value, dict):
            return obj({key: constant(v) for key, v in value.items()})
        if isinstance(value, list):
            return {'type': 'array', 'const': value, 'items': {'type': 'string'}}
        return {'type': kind[type(value)], 'const': value}

    def obj(properties):
        return {'type': 'object', 'additionalProperties': False, 'required': list(properties), 'properties': properties}

    image = obj({'binarySHA256': sha, 'byteCount': count, 'unsignedBinarySHA256': sha})
    parser = {key: (count if key.endswith('ByteCount') or key == 'byteCount' else sha)
              for key in KEYS['traceStreamer']}
    parser['reportedVersion'] = {'type': 'string', 'minLength': 1, 'maxLength': 64}
    parser['upstreamRevision'] = {'type': 'string', 'pattern': '^[0-9a-f]{40}$'}
    attribution = {}
    for name, filename in (('license', 'LICENSE'), ('notice', 'THIRD_PARTY_NOTICES.md'),
                           ('inventory', 'license-inventory.json'), ('windowsInventory', 'windows-license-inventory.json'),
                           ('rustInventory', 'rust/dependency-licenses.json')):
        attribution[name] = constant('resources/licenses/' + filename)
        attribution[name + 'SHA256'] = sha
        attribution[name + 'ByteCount'] = count
    attribution.update(licenseFileCount=constant(LICENSE_FILE_COUNT),
                       windowsLicenseFileCount=constant(WINDOWS_LICENSE_FILE_COUNT),
                       rustDependencyCount=constant(RUST_DEPENDENCY_COUNT),
                       rustLicenseFileCount=constant(RUST_LICENSE_FILE_COUNT),
                       selfTestFixtureSHA256=constant(SELF_TEST_SHA256), selfTestFixtureByteCount=count)
    signing = obj({'policy': {'type': 'string', 'enum': list(SIGNING_POLICIES)},
                   'publisher': {'type': ['string', 'null'], 'minLength': 1, 'maxLength': 256},
                   'timestamped': {'type': 'boolean'}})
    signing['allOf'] = [{
        'if': {'properties': {'policy': {'const': 'development-pinned'}}},
        'then': {'properties': {'publisher': {'type': 'null'}, 'timestamped': {'const': False}}},
        'else': {'properties': {'publisher': {'type': 'string'}}},
    }]
    file_record = obj({'path': {'type': 'string', 'minLength': 1, 'maxLength': 512,
                              'pattern': '^[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)*$'},
                       'sha256': sha, 'byteCount': count})
    schema = obj({
        'schema': constant(SCHEMA), 'formatVersion': constant(1),
        'source': obj({'revision': {'type': 'string', 'pattern': '^[0-9a-f]{40}$'}, 'dirty': {'type': 'boolean'}}),
        'product': constant(PRODUCT), 'layout': constant(LAYOUT), 'tool': image, 'helper': image,
        'traceStreamer': obj(parser), 'provenance': constant(PROVENANCE), 'signing': signing,
        'integrity': obj({'treeDigest': constant(TREE_DIGEST), 'treeSHA256': sha,
                          'fileCount': {'type': 'integer', 'minimum': 1, 'maximum': MAXIMUM_FILES},
                          'executables': constant(EXECUTABLES),
                          'files': {'type': 'array', 'minItems': 1, 'maxItems': MAXIMUM_FILES, 'items': file_record}}),
        'attribution': obj(attribution), 'upgradePolicy': constant(UPGRADE_POLICY),
    })
    schema['$schema'] = 'https://json-schema.org/draft/2020-12/schema'
    schema['$id'] = 'https://arktrace.dev/contracts/distribution/arktrace-cli-distribution-windows-x86_64-v1.schema.json'
    schema['$comment'] = 'Generated by scripts/windows_cli_distribution.py; physical tree and cross-field rules also require its verifier.'
    return schema


if __name__ == '__main__':
    import sys
    json.dump(manifest_schema(), sys.stdout, indent=2)
    sys.stdout.write('\n')

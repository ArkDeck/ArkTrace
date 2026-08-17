#!/usr/bin/env python3
"""Verify the closed ArkTrace CLI distribution layout used by ArkDeck.

The verifier deliberately knows the complete public manifest schema and the
few paths ArkDeck is allowed to pin.  It does not trust path strings from the
manifest until every component has been walked below the supplied physical
root, and it hashes every file through a single no-follow descriptor.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import stat
import sys
import ctypes
import errno
from pathlib import Path, PurePosixPath


MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TREE_BYTES = 256 * 1024 * 1024
MAX_TREE_FILES = 256
MAX_TREE_ENTRIES = 512
MAX_TREE_DEPTH = 32
MAX_RELATIVE_PATH_BYTES = 1024
MAX_NAME_BYTES = 255
RENAME_EXCL = 0x00000004
MAX_MANIFEST_BYTES = 64 * 1024
HEX = set("0123456789abcdef")
PRODUCT_LICENSE_SHA256 = "27ec10adbe109a67f514a5620190460e52b09352214aaf1d9869be568b6f46d9"
PRODUCT_LICENSE_BYTES = 1_078
NOTICE_SHA256 = "9e03235bfb104fdeb7a91dfc8321294be0603ecd514729edcf2eace41f5a1a72"
NOTICE_BYTES = 1_517
INVENTORY_SHA256 = "b16397dbbe593a067a0906a496627c8f300b2a4a860eab489181549b35c81e1e"
INVENTORY_BYTES = 6_939
SELF_TEST_SHA256 = "eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe"
SELF_TEST_BYTES = 67_837
LICENSE_FILE_COUNT = 18


class VerificationError(Exception):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def require_keys(value: object, expected: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != expected:
        fail(f"{label} schema is not exact")
    return value


def require_text(value: object, label: str, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        fail(f"{label} is invalid")
    return value


def require_hex(value: object, label: str, count: int) -> str:
    text = require_text(value, label, count)
    if len(text) != count or any(character not in HEX for character in text):
        fail(f"{label} is invalid")
    return text


def require_positive_int(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{label} is invalid")
    return value


def relative_path(value: object, label: str) -> PurePosixPath:
    text = require_text(value, label, 512)
    candidate = PurePosixPath(text)
    if candidate.is_absolute() or any(part in ("", ".", "..") for part in candidate.parts):
        fail(f"{label} is not a closed relative path")
    return candidate


def encoded_name(value: str, label: str) -> bytes:
    if not value or value in (".", "..") or "/" in value:
        fail(f"{label} is invalid")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        fail(f"{label} is not valid UTF-8")
    if len(encoded) > MAX_NAME_BYTES:
        fail(f"{label} exceeds its byte bound")
    return encoded


def bounded_directory_entries(
    descriptor: int, maximum: int
) -> list[tuple[bytes, str]]:
    if maximum < 0:
        fail("distribution directory exceeds its entry bound")
    entries: list[tuple[bytes, str]] = []
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            if len(entries) >= maximum:
                fail("distribution directory exceeds its entry bound")
            entries.append(
                (encoded_name(entry.name, "distribution entry name"), entry.name)
            )
    entries.sort(key=lambda item: item[0])
    return entries


def open_relative(root_fd: int, relative: PurePosixPath) -> int:
    current = os.dup(root_fd)
    try:
        for component in relative.parts[:-1]:
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
                dir_fd=current,
            )
            os.close(current)
            current = next_fd
        return os.open(
            relative.parts[-1], os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=current,
        )
    finally:
        os.close(current)


def open_directory_relative(root_fd: int, relative: PurePosixPath | None = None) -> int:
    if relative is None:
        return os.dup(root_fd)
    current = os.dup(root_fd)
    try:
        for component in relative.parts:
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
                dir_fd=current,
            )
            os.close(current)
            current = next_fd
        return current
    except Exception:
        os.close(current)
        raise


def snapshot(descriptor: int) -> tuple[int, int, int, int, int, int]:
    info = os.fstat(descriptor)
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def read_descriptor(
    descriptor: int, relative: PurePosixPath, maximum: int
) -> tuple[bytes, int]:
    initial = os.fstat(descriptor)
    if not stat.S_ISREG(initial.st_mode) or not 0 < initial.st_size <= maximum:
        fail(f"{relative} is not a bounded regular file")
    remaining = initial.st_size
    chunks: list[bytes] = []
    while remaining:
        block = os.read(descriptor, min(1024 * 1024, remaining))
        if not block:
            fail(f"{relative} changed while it was read")
        chunks.append(block)
        remaining -= len(block)
    if os.read(descriptor, 1):
        fail(f"{relative} grew while it was read")
    if snapshot(descriptor) != (
        initial.st_dev,
        initial.st_ino,
        initial.st_mode,
        initial.st_size,
        initial.st_mtime_ns,
        initial.st_ctime_ns,
    ):
        fail(f"{relative} changed while it was read")
    return b"".join(chunks), stat.S_IMODE(initial.st_mode)


def read_relative(
    root_fd: int, relative: PurePosixPath, maximum: int = MAX_FILE_BYTES
) -> tuple[bytes, int]:
    descriptor = open_relative(root_fd, relative)
    try:
        return read_descriptor(descriptor, relative, maximum)
    finally:
        os.close(descriptor)


def hash_relative(root_fd: int, relative: PurePosixPath, maximum: int = MAX_FILE_BYTES) -> tuple[str, int, int]:
    data, mode = read_relative(root_fd, relative, maximum)
    return hashlib.sha256(data).hexdigest(), len(data), mode


def decode_json(data: bytes, relative: PurePosixPath) -> object:
    try:
        return json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail(f"{relative} is malformed")


def read_json_identity(
    root_fd: int, relative: PurePosixPath
) -> tuple[object, str, int]:
    data, mode = read_relative(root_fd, relative, MAX_MANIFEST_BYTES)
    if mode != 0o644:
        fail(f"{relative} mode is not reviewed")
    return decode_json(data, relative), hashlib.sha256(data).hexdigest(), len(data)


def read_json(root_fd: int, relative: PurePosixPath) -> object:
    value, _, _ = read_json_identity(root_fd, relative)
    return value


def physical_root(path: Path) -> tuple[Path, int]:
    if not path.is_absolute():
        fail("distribution root must be absolute")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail("distribution root is not a physical directory")
    resolved = path.resolve(strict=True)
    if resolved != path:
        fail("distribution root contains a symlink")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY)
    opened = os.fstat(descriptor)
    if (
        opened.st_dev != info.st_dev
        or opened.st_ino != info.st_ino
        or opened.st_mode != info.st_mode
    ):
        os.close(descriptor)
        fail("distribution root changed while it was opened")
    return resolved, descriptor


def tree_projection_descriptor(root_fd: int) -> tuple[str, str]:
    records: list[tuple[bytes, str, int, int, tuple[int, int, int, int, int, int]]] = []
    directories: list[tuple[bytes, tuple[int, int, int, int, int, int]]] = []
    total = 0
    entry_count = 1

    def walk(
        directory_fd: int,
        prefix: PurePosixPath | None,
        raw_prefix: bytes,
        depth: int,
    ) -> None:
        nonlocal total, entry_count
        if depth > MAX_TREE_DEPTH:
            fail("distribution tree exceeds its depth bound")
        initial = snapshot(directory_fd)
        directories.append((raw_prefix, initial))
        encoded_names = bounded_directory_entries(
            directory_fd, MAX_TREE_ENTRIES - entry_count
        )
        names = [name for _, name in encoded_names]
        raw_names = [raw for raw, _ in encoded_names]
        if len(raw_names) != len(set(raw_names)):
            fail("distribution tree contains duplicate names")
        entry_count += len(encoded_names)
        for raw_name, name in encoded_names:
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            relative = PurePosixPath(name) if prefix is None else prefix / name
            raw_relative = raw_name if not raw_prefix else raw_prefix + b"/" + raw_name
            if len(raw_relative) > MAX_RELATIVE_PATH_BYTES:
                fail("distribution tree exceeds its path byte bound")
            if stat.S_ISDIR(info.st_mode):
                child = os.open(
                    name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
                    dir_fd=directory_fd,
                )
                try:
                    walk(child, relative, raw_relative, depth + 1)
                finally:
                    os.close(child)
            elif stat.S_ISREG(info.st_mode):
                descriptor = os.open(
                    name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
                try:
                    data, mode = read_descriptor(descriptor, relative, MAX_FILE_BYTES)
                    file_state = snapshot(descriptor)
                finally:
                    os.close(descriptor)
                digest = hashlib.sha256(data).hexdigest()
                records.append(
                    (raw_relative, digest, len(data), mode, file_state)
                )
                total += len(data)
                if len(records) > MAX_TREE_FILES or total > MAX_TREE_BYTES:
                    fail("distribution tree exceeds its audit bound")
            else:
                fail("distribution tree contains a symlink or non-regular file")
        if (
            snapshot(directory_fd) != initial
            or [name for _, name in bounded_directory_entries(directory_fd, len(names))]
            != names
        ):
            fail("distribution tree changed while it was read")

    walk(root_fd, None, b"", 0)
    result = hashlib.sha256()
    for raw_path, digest, size, mode, _ in sorted(records, key=lambda item: item[0]):
        result.update(b"F\0")
        result.update(f"{mode:o}".encode("ascii"))
        result.update(b"\0")
        result.update(raw_path)
        result.update(b"\0")
        result.update(str(size).encode("ascii"))
        result.update(b"\0")
        result.update(digest.encode("ascii"))
        result.update(b"\0")
    state = hashlib.sha256()
    for kind, raw_path, file_state in sorted(
        [(b"D", path, value) for path, value in directories]
        + [(b"F", path, value) for path, _, _, _, value in records],
        key=lambda item: (item[1], item[0]),
    ):
        state.update(kind)
        state.update(b"\0")
        state.update(raw_path)
        state.update(b"\0")
        for component in file_state:
            state.update(str(component).encode("ascii"))
            state.update(b"\0")
    return result.hexdigest(), state.hexdigest()


def tree_sha_descriptor(root_fd: int) -> str:
    return tree_projection_descriptor(root_fd)[0]


def tree_sha(path: Path) -> str:
    _, root_fd = physical_root(path)
    try:
        return tree_sha_descriptor(root_fd)
    finally:
        os.close(root_fd)


def directory_names(root_fd: int, relative: PurePosixPath | None = None) -> list[str]:
    descriptor = open_directory_relative(root_fd, relative)
    try:
        initial = snapshot(descriptor)
        encoded_names = bounded_directory_entries(descriptor, MAX_TREE_ENTRIES)
        names = [name for _, name in encoded_names]
        if len(encoded_names) > MAX_TREE_ENTRIES or len(encoded_names) != len(
            {raw for raw, _ in encoded_names}
        ):
            fail("distribution directory contains duplicate names")
        for name in names:
            info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                fail("distribution directory contains a symlink or special file")
        if snapshot(descriptor) != initial or [
            name for _, name in bounded_directory_entries(descriptor, len(names))
        ] != names:
            fail("distribution directory changed while it was read")
        return names
    finally:
        os.close(descriptor)


def require_directory_names(
    root_fd: int, relative: PurePosixPath | None, expected: list[str], label: str
) -> None:
    if directory_names(root_fd, relative) != sorted(
        expected, key=lambda item: item.encode("utf-8")
    ):
        fail(f"{label} closure is invalid")


def require_file_identity(
    root_fd: int,
    relative: PurePosixPath,
    expected_sha: str,
    expected_bytes: int,
    expected_mode: int = 0o644,
) -> bytes:
    data, mode = read_relative(root_fd, relative)
    if (
        len(data) != expected_bytes
        or hashlib.sha256(data).hexdigest() != expected_sha
        or mode != expected_mode
    ):
        fail(f"{relative} identity drifted")
    return data


def inventory_license_records(value: object) -> dict[str, tuple[str, int]]:
    inventory = require_keys(
        value, {"formatVersion", "policy", "buildTools", "components"}, "license inventory"
    )
    if inventory["formatVersion"] != 1:
        fail("license inventory version is unsupported")
    components = inventory["components"]
    build_tools = inventory["buildTools"]
    if not isinstance(components, list) or len(components) != 14:
        fail("license component closure is invalid")
    if not isinstance(build_tools, list) or len(build_tools) != 2:
        fail("license build-tool closure is invalid")

    records: dict[str, tuple[str, int]] = {}

    def append(path_value: object, sha_value: object, bytes_value: object) -> None:
        path = relative_path(path_value, "license file")
        if len(path.parts) != 2 or path.parts[0] != "LICENSES":
            fail("license file path is not closed")
        sha = require_hex(sha_value, "license file SHA-256", 64)
        byte_count = require_positive_int(bytes_value, "license file byte count")
        if byte_count > 128 * 1024 or path.as_posix() in records:
            fail("license file identity is invalid")
        records[path.as_posix()] = (sha, byte_count)

    component_keys = {
        "name", "repository", "revision", "licenseExpression", "licenseFile",
        "licenseSHA256", "licenseByteCount", "usage",
    }
    for item in components:
        if not isinstance(item, dict) or not component_keys.issubset(item) or not set(item).issubset(
            component_keys | {"additionalLicenseFiles"}
        ):
            fail("license component schema is not exact")
        append(item["licenseFile"], item["licenseSHA256"], item["licenseByteCount"])
        additional = item.get("additionalLicenseFiles", [])
        if not isinstance(additional, list) or len(additional) > 8:
            fail("additional license closure is invalid")
        for extra in additional:
            extra = require_keys(extra, {"path", "sha256", "byteCount"}, "additional license")
            append(extra["path"], extra["sha256"], extra["byteCount"])

    build_tool_keys = {
        "name", "repository", "revision", "artifactURL", "artifactSHA256",
        "artifactByteCount", "licenseExpression", "licenseFile", "licenseSHA256",
        "licenseByteCount", "usage",
    }
    for item in build_tools:
        item = require_keys(item, build_tool_keys, "license build tool")
        append(item["licenseFile"], item["licenseSHA256"], item["licenseByteCount"])
    if len(records) != LICENSE_FILE_COUNT:
        fail("license file closure is invalid")
    return records


def app_relative(app_prefix: PurePosixPath | None, value: str) -> PurePosixPath:
    suffix = PurePosixPath(value)
    return suffix if app_prefix is None else app_prefix / suffix


def validate_resources(
    root_fd: int,
    attribution: dict[str, object] | None,
    app_prefix: PurePosixPath | None,
    distribution_copies: bool,
) -> None:
    resource_root = app_relative(
        app_prefix, "Contents/Resources/ArkTraceCLIResources"
    )
    attribution_root = app_relative(app_prefix, "Contents/Resources/Attribution")
    require_directory_names(
        root_fd,
        resource_root,
        ["LICENSE", "LICENSES", "THIRD_PARTY_NOTICES.md", "license-inventory.json", "zlib.htrace"],
        "CLI resource bundle",
    )
    require_directory_names(
        root_fd,
        attribution_root,
        ["LICENSE", "LICENSES", "THIRD_PARTY_NOTICES.md", "license-inventory.json"],
        "App attribution",
    )

    manifest_resource_root = app_relative(
        app_prefix, "Contents/Resources/ArkTraceCLIResources"
    ).as_posix()
    expected_attribution: dict[str, object] = {
        "license": "LICENSE",
        "licenseSHA256": PRODUCT_LICENSE_SHA256,
        "licenseByteCount": PRODUCT_LICENSE_BYTES,
        "notice": "THIRD_PARTY_NOTICES.md",
        "noticeSHA256": NOTICE_SHA256,
        "noticeByteCount": NOTICE_BYTES,
        "inventory": f"{manifest_resource_root}/license-inventory.json",
        "inventorySHA256": INVENTORY_SHA256,
        "inventoryByteCount": INVENTORY_BYTES,
        "licenseFileCount": LICENSE_FILE_COUNT,
        "selfTestFixture": f"{manifest_resource_root}/zlib.htrace",
        "selfTestFixtureSHA256": SELF_TEST_SHA256,
        "selfTestFixtureByteCount": SELF_TEST_BYTES,
    }
    if attribution is not None and attribution != expected_attribution:
        fail("attribution identity is unsupported")

    if distribution_copies:
        root_license = require_file_identity(
            root_fd, PurePosixPath("LICENSE"), PRODUCT_LICENSE_SHA256, PRODUCT_LICENSE_BYTES
        )
        root_notice = require_file_identity(
            root_fd, PurePosixPath("THIRD_PARTY_NOTICES.md"), NOTICE_SHA256, NOTICE_BYTES
        )
    else:
        root_license = require_file_identity(
            root_fd, resource_root / "LICENSE", PRODUCT_LICENSE_SHA256, PRODUCT_LICENSE_BYTES
        )
        root_notice = require_file_identity(
            root_fd,
            resource_root / "THIRD_PARTY_NOTICES.md",
            NOTICE_SHA256,
            NOTICE_BYTES,
        )
    inventory_path = resource_root / "license-inventory.json"
    inventory_data = require_file_identity(
        root_fd, inventory_path, INVENTORY_SHA256, INVENTORY_BYTES
    )
    require_file_identity(
        root_fd, resource_root / "zlib.htrace", SELF_TEST_SHA256,
        SELF_TEST_BYTES,
    )
    for relative, expected in (
        (resource_root / "LICENSE", root_license),
        (attribution_root / "LICENSE", root_license),
        (resource_root / "THIRD_PARTY_NOTICES.md", root_notice),
        (attribution_root / "THIRD_PARTY_NOTICES.md", root_notice),
        (attribution_root / "license-inventory.json", inventory_data),
    ):
        data, mode = read_relative(root_fd, relative)
        if data != expected or mode != 0o644:
            fail(f"{relative} drifted")

    try:
        inventory_object = json.loads(inventory_data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("license inventory is malformed")
    records = inventory_license_records(inventory_object)
    expected_names = sorted(
        (PurePosixPath(path).name for path in records), key=lambda item: item.encode("utf-8")
    )
    require_directory_names(root_fd, resource_root / "LICENSES", expected_names, "CLI licenses")
    require_directory_names(root_fd, attribution_root / "LICENSES", expected_names, "App licenses")
    for path, (expected_sha, expected_bytes) in records.items():
        name = PurePosixPath(path).name
        resource_data = require_file_identity(
            root_fd, resource_root / "LICENSES" / name, expected_sha, expected_bytes
        )
        attribution_data, mode = read_relative(
            root_fd, attribution_root / "LICENSES" / name, 128 * 1024
        )
        if attribution_data != resource_data or mode != 0o644:
            fail("App license copy drifted")


def validate_info_plist(
    root_fd: int, product: dict[str, object], app_prefix: PurePosixPath | None
) -> None:
    path = app_relative(app_prefix, "Contents/Info.plist")
    data, mode = read_relative(root_fd, path, MAX_MANIFEST_BYTES)
    if mode != 0o644:
        fail("Info.plist mode is not reviewed")
    try:
        value = plistlib.loads(data)
    except plistlib.InvalidFileException:
        fail("Info.plist is malformed")
    expected = {
        "CFBundleExecutable": "arktrace",
        "CFBundleIdentifier": "com.arktrace.ArkTrace.CLI",
        "CFBundleName": "ArkTraceCLI",
        "CFBundleDisplayName": "ArkTraceCLI",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "26.0",
        "LSBackgroundOnly": True,
        "NSHighResolutionCapable": True,
    }
    if value != expected:
        fail("Info.plist identity is unsupported")
    if product["version"] != value["CFBundleShortVersionString"] or product["build"] != value[
        "CFBundleVersion"
    ] or product["bundleIdentifier"] != value["CFBundleIdentifier"]:
        fail("product identity does not bind Info.plist")


def validate_app_layout(
    root_fd: int, app_prefix: PurePosixPath | None, stapled_required: bool
) -> None:
    if app_prefix is None:
        require_directory_names(root_fd, None, ["Contents"], "App")
    else:
        require_directory_names(root_fd, app_prefix, ["Contents"], "App")
    contents = app_relative(app_prefix, "Contents")
    expected_contents = ["Helpers", "Info.plist", "MacOS", "Resources", "_CodeSignature"]
    if stapled_required:
        expected_contents.append("CodeResources")
    require_directory_names(
        root_fd,
        contents,
        expected_contents,
        "App Contents",
    )
    require_directory_names(
        root_fd, app_relative(app_prefix, "Contents/MacOS"), ["arktrace"], "App MacOS"
    )
    require_directory_names(
        root_fd,
        app_relative(app_prefix, "Contents/Helpers"),
        ["trace_streamer"],
        "App Helpers",
    )
    require_directory_names(
        root_fd,
        app_relative(app_prefix, "Contents/Resources"),
        ["ArkTraceCLIResources", "Attribution", "TraceStreamer"],
        "App Resources",
    )
    require_directory_names(
        root_fd,
        app_relative(app_prefix, "Contents/_CodeSignature"),
        ["CodeResources"],
        "App code-signature resources",
    )
    _, code_resources_mode = read_relative(
        root_fd, app_relative(app_prefix, "Contents/_CodeSignature/CodeResources")
    )
    if code_resources_mode != 0o644:
        fail("App CodeResources mode is not reviewed")
    if stapled_required:
        _, ticket_mode = read_relative(
            root_fd, app_relative(app_prefix, "Contents/CodeResources"), 64 * 1024
        )
        if ticket_mode != 0o600:
            fail("stapled App ticket mode is not reviewed")


def verify_app(root_path: Path, stapled_required: bool) -> None:
    _, root_fd = physical_root(root_path)
    try:
        initial_tree_projection = tree_projection_descriptor(root_fd)
        product: dict[str, object] = {
            "name": "arktrace",
            "version": "0.1.0",
            "build": "1",
            "architecture": "arm64",
            "bundleIdentifier": "com.arktrace.ArkTrace.CLI",
            "jsonContract": {"major": 1, "minor": 0},
        }
        validate_app_layout(root_fd, None, stapled_required=stapled_required)
        validate_info_plist(root_fd, product, None)
        validate_resources(root_fd, None, None, distribution_copies=False)
        require_directory_names(
            root_fd,
            PurePosixPath("Contents/Resources/TraceStreamer"),
            ["distribution-signing.json", "manifest.json"],
            "TraceStreamer resources",
        )
        _, _, tool_mode = hash_relative(
            root_fd, PurePosixPath("Contents/MacOS/arktrace")
        )
        parser_sha, _, parser_mode = hash_relative(
            root_fd, PurePosixPath("Contents/Helpers/trace_streamer")
        )
        if tool_mode != 0o755 or parser_mode != 0o755:
            fail("App executable mode is not reviewed")
        parser_manifest_value, _, _ = read_json_identity(
            root_fd, PurePosixPath("Contents/Resources/TraceStreamer/manifest.json")
        )
        parser_manifest = require_keys(
            parser_manifest_value,
            {
                "name", "upstreamRepository", "upstreamRevision", "reportedVersion",
                "binarySHA256", "architecture", "adapterVersion", "buildRecipeVersion",
                "plugins", "localPatches", "thirdPartySources", "thirdPartyRevisions",
                "hostToolchain", "builtAt",
            },
            "parser manifest",
        )
        if (
            parser_manifest["name"] != "trace_streamer"
            or parser_manifest["binarySHA256"] != parser_sha
            or parser_manifest["architecture"] != "arm64"
        ):
            fail("parser manifest does not bind the installed helper")
        require_hex(parser_manifest["upstreamRevision"], "parser upstream revision", 40)
        recipe = require_hex(parser_manifest["buildRecipeVersion"], "parser recipe version", 64)
        parser_signing_value, _, _ = read_json_identity(
            root_fd,
            PurePosixPath("Contents/Resources/TraceStreamer/distribution-signing.json"),
        )
        parser_signing = require_keys(
            parser_signing_value,
            {
                "formatVersion", "unsignedBinarySHA256", "signedBinarySHA256",
                "buildRecipeVersion", "teamIdentifier", "signingIdentity",
                "signingCertificateSHA1", "signingPolicy",
            },
            "parser signing record",
        )
        if (
            parser_signing["formatVersion"] != 1
            or parser_signing["signedBinarySHA256"] != parser_sha
            or parser_signing["buildRecipeVersion"] != recipe
            or parser_signing["signingPolicy"] != "developer-id-runtime-timestamp"
        ):
            fail("parser signing record does not bind the installed helper")
        require_hex(
            parser_signing["unsignedBinarySHA256"], "unsigned parser SHA-256", 64
        )
        require_text(parser_signing["teamIdentifier"], "team identifier", 32)
        require_text(parser_signing["signingIdentity"], "signing identity", 256)
        certificate = require_text(
            parser_signing["signingCertificateSHA1"], "signing certificate SHA-1", 40
        )
        if len(certificate) != 40 or any(
            character not in "0123456789ABCDEF" for character in certificate
        ):
            fail("signing certificate SHA-1 is invalid")
        if tree_projection_descriptor(root_fd) != initial_tree_projection:
            fail("App changed during verification")
    finally:
        os.close(root_fd)


def snapshot_json(source: Path, destination: Path) -> None:
    if not source.is_absolute() or not destination.is_absolute():
        fail("JSON snapshot paths must be absolute")
    if source.name in ("", ".", "..") or destination.name in ("", ".", ".."):
        fail("JSON snapshot path is invalid")
    _, source_parent_fd = physical_root(source.parent)
    try:
        descriptor = open_relative(source_parent_fd, PurePosixPath(source.name))
        try:
            data, mode = read_descriptor(descriptor, PurePosixPath(source.name), MAX_MANIFEST_BYTES)
        finally:
            os.close(descriptor)
        if mode not in (0o600, 0o644):
            fail("JSON snapshot source mode is not reviewed")
        decode_json(data, PurePosixPath(source.name))
    finally:
        os.close(source_parent_fd)

    _, destination_parent_fd = physical_root(destination.parent)
    try:
        output = os.open(
            destination.name,
            os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=destination_parent_fd,
        )
        try:
            offset = 0
            while offset < len(data):
                offset += os.write(output, data[offset:])
            os.fsync(output)
        finally:
            os.close(output)
    finally:
        os.close(destination_parent_fd)


def snapshot_file(source: Path, destination: Path) -> None:
    if not source.is_absolute() or not destination.is_absolute():
        fail("file snapshot paths must be absolute")
    if source.name in ("", ".", "..") or destination.name in ("", ".", ".."):
        fail("file snapshot path is invalid")
    _, source_parent_fd = physical_root(source.parent)
    try:
        descriptor = open_relative(source_parent_fd, PurePosixPath(source.name))
        try:
            data, mode = read_descriptor(
                descriptor, PurePosixPath(source.name), MAX_FILE_BYTES
            )
        finally:
            os.close(descriptor)
    finally:
        os.close(source_parent_fd)

    _, destination_parent_fd = physical_root(destination.parent)
    try:
        output = os.open(
            destination.name,
            os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=destination_parent_fd,
        )
        try:
            offset = 0
            while offset < len(data):
                offset += os.write(output, data[offset:])
            os.fchmod(output, mode)
            os.fsync(output)
        finally:
            os.close(output)
    finally:
        os.close(destination_parent_fd)


def snapshot_tree(source: Path, destination: Path) -> None:
    if not source.is_absolute() or not destination.is_absolute():
        fail("tree snapshot paths must be absolute")
    if source.name in ("", ".", "..") or destination.name in ("", ".", ".."):
        fail("tree snapshot path is invalid")

    _, source_fd = physical_root(source)
    _, destination_parent_fd = physical_root(destination.parent)
    destination_fd = -1
    try:
        source_root_mode = stat.S_IMODE(os.fstat(source_fd).st_mode)
        initial_projection = tree_projection_descriptor(source_fd)
        if leaf_stat(destination_parent_fd, destination.name) is not None:
            fail("tree snapshot destination already exists")
        os.mkdir(destination.name, 0o700, dir_fd=destination_parent_fd)
        destination_fd = os.open(
            destination.name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
            dir_fd=destination_parent_fd,
        )
        entry_count = 1
        file_count = 0
        total_bytes = 0

        def copy_directory(
            input_fd: int,
            output_fd: int,
            prefix: PurePosixPath | None,
            raw_prefix: bytes,
            depth: int,
        ) -> None:
            nonlocal entry_count, file_count, total_bytes
            if depth > MAX_TREE_DEPTH:
                fail("tree snapshot exceeds its depth bound")
            input_initial = snapshot(input_fd)
            entries = bounded_directory_entries(
                input_fd, MAX_TREE_ENTRIES - entry_count
            )
            entry_count += len(entries)
            for raw_name, name in entries:
                info = os.stat(name, dir_fd=input_fd, follow_symlinks=False)
                relative = PurePosixPath(name) if prefix is None else prefix / name
                raw_relative = raw_name if not raw_prefix else raw_prefix + b"/" + raw_name
                if len(raw_relative) > MAX_RELATIVE_PATH_BYTES:
                    fail("tree snapshot exceeds its path byte bound")
                if stat.S_ISDIR(info.st_mode):
                    child_input = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
                        dir_fd=input_fd,
                    )
                    child_output = -1
                    try:
                        opened = os.fstat(child_input)
                        if (
                            opened.st_dev != info.st_dev
                            or opened.st_ino != info.st_ino
                            or opened.st_mode != info.st_mode
                        ):
                            fail("tree snapshot directory changed while it was opened")
                        os.mkdir(name, 0o700, dir_fd=output_fd)
                        child_output = os.open(
                            name,
                            os.O_RDONLY
                            | os.O_CLOEXEC
                            | os.O_NOFOLLOW
                            | os.O_DIRECTORY,
                            dir_fd=output_fd,
                        )
                        copy_directory(
                            child_input,
                            child_output,
                            relative,
                            raw_relative,
                            depth + 1,
                        )
                        os.fchmod(child_output, stat.S_IMODE(info.st_mode))
                    finally:
                        if child_output >= 0:
                            os.close(child_output)
                        os.close(child_input)
                elif stat.S_ISREG(info.st_mode):
                    input_file = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                        dir_fd=input_fd,
                    )
                    output_file = -1
                    try:
                        opened = os.fstat(input_file)
                        if (
                            opened.st_dev != info.st_dev
                            or opened.st_ino != info.st_ino
                            or opened.st_mode != info.st_mode
                        ):
                            fail("tree snapshot file changed while it was opened")
                        data, mode = read_descriptor(input_file, relative, MAX_FILE_BYTES)
                        file_count += 1
                        total_bytes += len(data)
                        if file_count > MAX_TREE_FILES or total_bytes > MAX_TREE_BYTES:
                            fail("tree snapshot exceeds its audit bound")
                        output_file = os.open(
                            name,
                            os.O_WRONLY
                            | os.O_CLOEXEC
                            | os.O_NOFOLLOW
                            | os.O_CREAT
                            | os.O_EXCL,
                            0o600,
                            dir_fd=output_fd,
                        )
                        offset = 0
                        while offset < len(data):
                            offset += os.write(output_file, data[offset:])
                        os.fchmod(output_file, mode)
                        os.fsync(output_file)
                    finally:
                        if output_file >= 0:
                            os.close(output_file)
                        os.close(input_file)
                else:
                    fail("tree snapshot refuses a symlink or special file")
            if (
                snapshot(input_fd) != input_initial
                or bounded_directory_entries(input_fd, len(entries)) != entries
            ):
                fail("tree snapshot source changed while it was copied")

        copy_directory(source_fd, destination_fd, None, b"", 0)
        os.fchmod(destination_fd, source_root_mode)
        os.fsync(destination_fd)
        if tree_projection_descriptor(source_fd) != initial_projection:
            fail("tree snapshot source changed while it was copied")
        if tree_sha_descriptor(destination_fd) != initial_projection[0]:
            fail("tree snapshot destination identity drifted")
    finally:
        if destination_fd >= 0:
            os.close(destination_fd)
        os.close(destination_parent_fd)
        os.close(source_fd)


def rename_exclusive(
    source_parent_fd: int, source_name: str, destination_parent_fd: int, destination_name: str
) -> None:
    source_raw = encoded_name(source_name, "publication source name")
    destination_raw = encoded_name(destination_name, "publication destination name")
    library = ctypes.CDLL(None, use_errno=True)
    function = library.renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(
        source_parent_fd,
        ctypes.c_char_p(source_raw),
        destination_parent_fd,
        ctypes.c_char_p(destination_raw),
        RENAME_EXCL,
    ) != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            fail("publication destination already exists")
        raise OSError(error, "exclusive publication rename failed")


def leaf_stat(parent_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def open_publication_source(parent_fd: int, name: str, kind: str) -> int:
    info = leaf_stat(parent_fd, name)
    if info is None or stat.S_ISLNK(info.st_mode):
        fail("publication source is unavailable")
    required = stat.S_ISREG if kind == "file" else stat.S_ISDIR
    if not required(info.st_mode):
        fail("publication source type is invalid")
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    if kind == "directory":
        flags |= os.O_DIRECTORY
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    opened = os.fstat(descriptor)
    if (
        opened.st_dev != info.st_dev
        or opened.st_ino != info.st_ino
        or opened.st_mode != info.st_mode
    ):
        os.close(descriptor)
        fail("publication source changed while it was opened")
    return descriptor


def verify_published_object(publication: dict[str, object]) -> None:
    destination_parent_fd = int(publication["destination_parent_fd"])
    descriptor = int(publication["descriptor"])
    source_name = str(publication["source_name"])
    destination_name = str(publication["destination_name"])
    kind = str(publication["kind"])
    expected = publication["expected"]
    destination_info = leaf_stat(destination_parent_fd, destination_name)
    opened = os.fstat(descriptor)
    if destination_info is None or (
        destination_info.st_dev != opened.st_dev
        or destination_info.st_ino != opened.st_ino
        or destination_info.st_mode != opened.st_mode
    ):
        fail("published path no longer binds the moved object")
    if kind == "file":
        os.lseek(descriptor, 0, os.SEEK_SET)
        data, _ = read_descriptor(
            descriptor, PurePosixPath(destination_name), MAX_FILE_BYTES
        )
        actual = (hashlib.sha256(data).hexdigest(), len(data))
    else:
        actual = tree_projection_descriptor(descriptor)[0]
    if actual != expected:
        fail("published object identity drifted")
    final_info = leaf_stat(destination_parent_fd, destination_name)
    final_opened = os.fstat(descriptor)
    if final_info is None or (
        final_info.st_dev != final_opened.st_dev
        or final_info.st_ino != final_opened.st_ino
        or final_info.st_mode != final_opened.st_mode
    ):
        fail("published path changed during verification")


def rollback_publication(publication: dict[str, object]) -> bool:
    source_parent_fd = int(publication["source_parent_fd"])
    destination_parent_fd = int(publication["destination_parent_fd"])
    source_name = str(publication["source_name"])
    destination_name = str(publication["destination_name"])
    try:
        if leaf_stat(source_parent_fd, source_name) is not None:
            return False
        verify_published_object(publication)
        rename_exclusive(
            destination_parent_fd,
            destination_name,
            source_parent_fd,
            source_name,
        )
        descriptor = int(publication["descriptor"])
        restored = leaf_stat(source_parent_fd, source_name)
        if (
            leaf_stat(destination_parent_fd, destination_name) is not None
            or restored is None
        ):
            return False
        opened = os.fstat(descriptor)
        return restored.st_dev == opened.st_dev and restored.st_ino == opened.st_ino
    except (OSError, VerificationError):
        return False


def publish_object(
    source: Path, destination: Path, kind: str, expected: object
) -> dict[str, object]:
    if not source.is_absolute() or not destination.is_absolute():
        fail("publication paths must be absolute")
    _, source_parent_fd = physical_root(source.parent)
    _, destination_parent_fd = physical_root(destination.parent)
    descriptor = -1
    moved = False
    publication: dict[str, object] | None = None
    try:
        if os.fstat(source_parent_fd).st_dev != os.fstat(destination_parent_fd).st_dev:
            fail("publication source and destination are on different filesystems")
        if leaf_stat(destination_parent_fd, destination.name) is not None:
            fail("publication destination already exists")
        descriptor = open_publication_source(source_parent_fd, source.name, kind)
        if kind == "file":
            data, _ = read_descriptor(
                descriptor, PurePosixPath(source.name), MAX_FILE_BYTES
            )
            before = (hashlib.sha256(data).hexdigest(), len(data))
        else:
            before = tree_projection_descriptor(descriptor)[0]
        if before != expected:
            fail("publication source identity drifted")
        rename_exclusive(
            source_parent_fd,
            source.name,
            destination_parent_fd,
            destination.name,
        )
        moved = True
        publication = {
            "source_parent_fd": source_parent_fd,
            "destination_parent_fd": destination_parent_fd,
            "descriptor": descriptor,
            "source_name": source.name,
            "destination_name": destination.name,
            "kind": kind,
            "expected": expected,
        }
        verify_published_object(publication)
        return publication
    except Exception:
        if moved and publication is not None:
            rollback_publication(publication)
        if descriptor >= 0:
            os.close(descriptor)
        os.close(destination_parent_fd)
        os.close(source_parent_fd)
        raise


def close_publication(publication: dict[str, object]) -> None:
    os.close(int(publication["descriptor"]))
    os.close(int(publication["destination_parent_fd"]))
    os.close(int(publication["source_parent_fd"]))


def publish_file(source: Path, destination: Path, expected_sha: str, expected_bytes: int) -> None:
    expected = (require_hex(expected_sha, "publication SHA-256", 64), expected_bytes)
    if not isinstance(expected_bytes, int) or expected_bytes <= 0:
        fail("publication byte count is invalid")
    publication = publish_object(source, destination, "file", expected)
    close_publication(publication)


def publish_directory(source: Path, destination: Path, expected_tree: str) -> None:
    expected_content = require_hex(expected_tree, "publication tree SHA-256", 64)
    publication = publish_object(
        source, destination, "directory", expected_content
    )
    close_publication(publication)


def publish_pair(
    directory_source: Path,
    directory_destination: Path,
    expected_tree: str,
    record_source: Path,
    record_destination: Path,
    expected_record_sha: str,
    expected_record_bytes: int,
) -> None:
    expected_content = require_hex(expected_tree, "publication tree SHA-256", 64)
    directory_publication = publish_object(
        directory_source,
        directory_destination,
        "directory",
        expected_content,
    )
    try:
        record_expected = (
            require_hex(expected_record_sha, "publication record SHA-256", 64),
            expected_record_bytes,
        )
        if expected_record_bytes <= 0:
            fail("publication record byte count is invalid")
        record_publication = publish_object(
            record_source, record_destination, "file", record_expected
        )
    except Exception:
        rolled_back = rollback_publication(directory_publication)
        close_publication(directory_publication)
        if not rolled_back:
            fail("candidate publication rollback could not prove ownership")
        raise
    close_publication(record_publication)
    close_publication(directory_publication)


def verify(root_path: Path) -> None:
    root, root_fd = physical_root(root_path)
    try:
        initial_tree_projection = tree_projection_descriptor(root_fd)
        top_level = directory_names(root_fd)
        if top_level != [
            "ArkTraceCLI.app",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "distribution-manifest.json",
            "notarization-receipt.json",
        ]:
            fail("distribution top-level closure is invalid")

        manifest_value, _, _ = read_json_identity(
            root_fd, PurePosixPath("distribution-manifest.json")
        )
        manifest = require_keys(
            manifest_value,
            {
                "formatVersion", "source", "product", "layout", "tool",
                "traceStreamer", "signing", "notarization", "integrity",
                "attribution", "upgradePolicy",
            },
            "distribution manifest",
        )
        if manifest["formatVersion"] != 1:
            fail("distribution manifest version is unsupported")

        source = require_keys(manifest["source"], {"revision", "treeSHA256"}, "source")
        require_hex(source["revision"], "source revision", 40)
        require_hex(source["treeSHA256"], "source tree SHA-256", 64)

        product = require_keys(
            manifest["product"],
            {"name", "version", "build", "architecture", "bundleIdentifier", "jsonContract"},
            "product",
        )
        if product["name"] != "arktrace" or product["architecture"] != "arm64":
            fail("product identity is unsupported")
        if product["version"] != "0.1.0" or product["build"] != "1":
            fail("product version/build is unsupported")
        if product["bundleIdentifier"] != "com.arktrace.ArkTrace.CLI":
            fail("CLI bundle identifier is unsupported")
        contract = require_keys(product["jsonContract"], {"major", "minor"}, "JSON contract")
        if contract != {"major": 1, "minor": 0}:
            fail("JSON contract is unsupported")

        layout = require_keys(
            manifest["layout"],
            {
                "bundle", "executable", "parserExecutable", "parserManifest",
                "parserSigningRecord", "resourceBundle",
            },
            "layout",
        )
        expected_layout = {
            "bundle": "ArkTraceCLI.app",
            "executable": "ArkTraceCLI.app/Contents/MacOS/arktrace",
            "parserExecutable": "ArkTraceCLI.app/Contents/Helpers/trace_streamer",
            "parserManifest": "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json",
            "parserSigningRecord": "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json",
            "resourceBundle": "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources",
        }
        if layout != expected_layout:
            fail("install layout is unsupported")

        tool = require_keys(
            manifest["tool"], {"binarySHA256", "byteCount", "codeDirectoryHash"}, "tool"
        )
        parser = require_keys(
            manifest["traceStreamer"],
            {
                "unsignedBinarySHA256", "binarySHA256", "byteCount", "codeDirectoryHash", "manifestSHA256",
                "manifestByteCount", "signingRecordSHA256", "signingRecordByteCount",
                "reportedVersion", "upstreamRevision", "buildRecipeVersion",
            },
            "TraceStreamer",
        )
        tool_sha = require_hex(tool["binarySHA256"], "tool SHA-256", 64)
        tool_size = require_positive_int(tool["byteCount"], "tool byte count")
        require_hex(tool["codeDirectoryHash"], "tool CodeDirectory hash", 40)
        parser_sha = require_hex(parser["binarySHA256"], "parser SHA-256", 64)
        unsigned_parser_sha = require_hex(
            parser["unsignedBinarySHA256"], "unsigned parser SHA-256", 64
        )
        parser_size = require_positive_int(parser["byteCount"], "parser byte count")
        require_hex(parser["codeDirectoryHash"], "parser CodeDirectory hash", 40)
        parser_manifest_sha = require_hex(parser["manifestSHA256"], "parser manifest SHA-256", 64)
        parser_manifest_size = require_positive_int(
            parser["manifestByteCount"], "parser manifest byte count"
        )
        parser_signing_sha = require_hex(
            parser["signingRecordSHA256"], "parser signing-record SHA-256", 64
        )
        parser_signing_size = require_positive_int(
            parser["signingRecordByteCount"], "parser signing-record byte count"
        )
        require_text(parser["reportedVersion"], "parser version", 64)
        require_hex(parser["upstreamRevision"], "parser upstream revision", 40)
        require_hex(parser["buildRecipeVersion"], "parser recipe version", 64)

        for key in (
            "executable", "parserExecutable", "parserManifest", "parserSigningRecord",
            "resourceBundle",
        ):
            relative_path(layout[key], f"layout {key}")
        actual_tool_sha, actual_tool_size, tool_mode = hash_relative(
            root_fd, relative_path(layout["executable"], "tool path")
        )
        actual_parser_sha, actual_parser_size, parser_mode = hash_relative(
            root_fd, relative_path(layout["parserExecutable"], "parser path")
        )
        parser_manifest_path = relative_path(layout["parserManifest"], "parser manifest path")
        parser_manifest_value, actual_manifest_sha, actual_manifest_size = read_json_identity(
            root_fd, parser_manifest_path
        )
        parser_signing_path = relative_path(
            layout["parserSigningRecord"], "parser signing-record path"
        )
        parser_signing_value, actual_signing_sha, actual_signing_size = read_json_identity(
            root_fd, parser_signing_path
        )
        if (actual_tool_sha, actual_tool_size) != (tool_sha, tool_size) or tool_mode != 0o755:
            fail("tool identity drifted")
        if (actual_parser_sha, actual_parser_size) != (parser_sha, parser_size) or parser_mode != 0o755:
            fail("parser identity drifted")
        if (actual_manifest_sha, actual_manifest_size) != (
            parser_manifest_sha,
            parser_manifest_size,
        ):
            fail("parser manifest identity drifted")
        if (actual_signing_sha, actual_signing_size) != (
            parser_signing_sha,
            parser_signing_size,
        ):
            fail("parser signing-record identity drifted")
        parser_manifest = require_keys(
            parser_manifest_value,
            {
                "name", "upstreamRepository", "upstreamRevision", "reportedVersion",
                "binarySHA256", "architecture", "adapterVersion", "buildRecipeVersion",
                "plugins", "localPatches", "thirdPartySources", "thirdPartyRevisions",
                "hostToolchain", "builtAt",
            },
            "parser manifest",
        )
        if (
            parser_manifest["binarySHA256"] != parser_sha
            or parser_manifest["reportedVersion"] != parser["reportedVersion"]
            or parser_manifest["upstreamRevision"] != parser["upstreamRevision"]
            or parser_manifest["buildRecipeVersion"] != parser["buildRecipeVersion"]
            or parser_manifest["architecture"] != "arm64"
        ):
            fail("parser provenance drifted")

        signing = require_keys(
            manifest["signing"],
            {"teamIdentifier", "identity", "certificateSHA1", "policy"},
            "signing",
        )
        require_text(signing["teamIdentifier"], "team identifier", 32)
        require_text(signing["identity"], "signing identity", 256)
        certificate = require_text(signing["certificateSHA1"], "certificate SHA-1", 40)
        if len(certificate) != 40 or any(character not in "0123456789ABCDEF" for character in certificate):
            fail("certificate SHA-1 is invalid")
        if signing["policy"] != "developer-id-runtime-timestamp":
            fail("signing policy is unsupported")
        parser_signing_record = require_keys(
            parser_signing_value,
            {
                "formatVersion", "unsignedBinarySHA256", "signedBinarySHA256",
                "buildRecipeVersion", "teamIdentifier", "signingIdentity",
                "signingCertificateSHA1", "signingPolicy",
            },
            "parser signing record",
        )
        if parser_signing_record != {
            "formatVersion": 1,
            "unsignedBinarySHA256": unsigned_parser_sha,
            "signedBinarySHA256": parser_sha,
            "buildRecipeVersion": parser["buildRecipeVersion"],
            "teamIdentifier": signing["teamIdentifier"],
            "signingIdentity": signing["identity"],
            "signingCertificateSHA1": signing["certificateSHA1"],
            "signingPolicy": signing["policy"],
        }:
            fail("parser signing provenance drifted")

        notarization = require_keys(
            manifest["notarization"],
            {
                "status", "submissionID", "receipt", "receiptSHA256",
                "stapledTicketValidated", "gatekeeperAssessment",
            },
            "notarization",
        )
        if (
            notarization["status"] != "Accepted"
            or notarization["receipt"] != "notarization-receipt.json"
            or notarization["stapledTicketValidated"] is not True
            or notarization["gatekeeperAssessment"] != "accepted"
        ):
            fail("notarization evidence is incomplete")
        require_text(notarization["submissionID"], "notarization submission ID", 64)
        receipt_sha = require_hex(notarization["receiptSHA256"], "notarization receipt SHA-256", 64)
        receipt_value, actual_receipt_sha, _ = read_json_identity(
            root_fd, PurePosixPath("notarization-receipt.json")
        )
        if receipt_sha != actual_receipt_sha:
            fail("notarization receipt identity drifted")
        receipt = require_keys(
            receipt_value,
            {"formatVersion", "id", "status", "message"},
            "notarization receipt",
        )
        if (
            receipt["formatVersion"] != 1
            or receipt["id"] != notarization["submissionID"]
            or receipt["status"] != "Accepted"
        ):
            fail("notarization receipt does not bind the accepted submission")

        integrity = require_keys(
            manifest["integrity"],
            {"appTreeSHA256", "resourceTreeSHA256", "appCodeDirectoryHash"},
            "integrity",
        )
        require_hex(integrity["appCodeDirectoryHash"], "App CodeDirectory hash", 40)
        app_fd = open_directory_relative(root_fd, PurePosixPath("ArkTraceCLI.app"))
        try:
            actual_app_tree = tree_sha_descriptor(app_fd)
        finally:
            os.close(app_fd)
        if actual_app_tree != require_hex(integrity["appTreeSHA256"], "App tree SHA-256", 64):
            fail("App tree identity drifted")
        resource_relative = relative_path(layout["resourceBundle"], "resource bundle path")
        resource_fd = open_directory_relative(root_fd, resource_relative)
        try:
            actual_resource_tree = tree_sha_descriptor(resource_fd)
        finally:
            os.close(resource_fd)
        if actual_resource_tree != require_hex(
            integrity["resourceTreeSHA256"], "resource tree SHA-256", 64
        ):
            fail("resource bundle identity drifted")

        attribution = require_keys(
            manifest["attribution"],
            {
                "license", "licenseSHA256", "licenseByteCount", "notice",
                "noticeSHA256", "noticeByteCount", "inventory", "inventorySHA256",
                "inventoryByteCount", "licenseFileCount", "selfTestFixture",
                "selfTestFixtureSHA256", "selfTestFixtureByteCount",
            },
            "attribution",
        )
        app_prefix = PurePosixPath("ArkTraceCLI.app")
        validate_info_plist(root_fd, product, app_prefix)
        validate_app_layout(root_fd, app_prefix, stapled_required=True)
        validate_resources(root_fd, attribution, app_prefix, distribution_copies=True)
        require_directory_names(
            root_fd,
            PurePosixPath("ArkTraceCLI.app/Contents/Resources/TraceStreamer"),
            ["distribution-signing.json", "manifest.json"],
            "TraceStreamer resources",
        )

        policy = require_keys(
            manifest["upgradePolicy"],
            {"identity", "installMode", "pathSelection", "rollback"},
            "upgrade policy",
        )
        if policy != {
            "identity": "distribution-manifest+tool-parser-hashes",
            "installMode": "versioned-directory",
            "pathSelection": "reviewed-absolute-descriptor-only",
            "rollback": "retain-prior-exact-directory",
        }:
            fail("upgrade and rollback policy is unsupported")
        if tree_projection_descriptor(root_fd) != initial_tree_projection:
            fail("distribution changed during verification")
    finally:
        os.close(root_fd)


def main(arguments: list[str]) -> int:
    try:
        if len(arguments) == 3 and arguments[1] == "tree-sha":
            print(tree_sha(Path(arguments[2])))
            return 0
        if (
            len(arguments) == 4
            and arguments[1] == "verify-app"
            and arguments[2] in ("pre-notary", "post-staple")
        ):
            verify_app(Path(arguments[3]), stapled_required=arguments[2] == "post-staple")
            print(f"Phase 5 CLI {arguments[2]} App verification passed")
            return 0
        if len(arguments) == 4 and arguments[1] == "snapshot-json":
            snapshot_json(Path(arguments[2]), Path(arguments[3]))
            return 0
        if len(arguments) == 4 and arguments[1] == "snapshot-file":
            snapshot_file(Path(arguments[2]), Path(arguments[3]))
            return 0
        if len(arguments) == 4 and arguments[1] == "snapshot-tree":
            snapshot_tree(Path(arguments[2]), Path(arguments[3]))
            return 0
        if len(arguments) == 6 and arguments[1] == "publish-file":
            publish_file(
                Path(arguments[2]), Path(arguments[3]), arguments[4], int(arguments[5])
            )
            return 0
        if len(arguments) == 5 and arguments[1] == "publish-directory":
            publish_directory(Path(arguments[2]), Path(arguments[3]), arguments[4])
            return 0
        if len(arguments) == 9 and arguments[1] == "publish-pair":
            publish_pair(
                Path(arguments[2]),
                Path(arguments[3]),
                arguments[4],
                Path(arguments[5]),
                Path(arguments[6]),
                arguments[7],
                int(arguments[8]),
            )
            return 0
        if len(arguments) == 2:
            verify(Path(arguments[1]))
            print("Phase 5 CLI distribution verification passed")
            return 0
        fail(
            "usage: verify_phase5_cli_distribution.py "
            "[tree-sha <path>|verify-app <pre-notary|post-staple> <App>|"
            "snapshot-json <source> <destination>|snapshot-file <source> <destination>|"
            "snapshot-tree <source> <destination>|"
            "publish-file <source> <destination> "
            "<sha256> <bytes>|publish-directory <source> <destination> <tree-sha256>|"
            "publish-pair <App.partial> <App> <tree-sha256> <record.partial> <record> "
            "<record-sha256> <record-bytes>|<distribution>]"
        )
    except (OSError, VerificationError, UnicodeError, RecursionError, ValueError, AttributeError):
        print("Phase 5 CLI distribution verification failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

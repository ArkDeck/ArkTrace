#!/usr/bin/env python3
"""Validate the conservative OHOSPROF shape accepted by the 0.1 large gate.

OHOSPROF has no byte-level session binding between independently authored
segments. Consequently, a type-0 capture followed by an unrelated type-1 or
type-1000 segment is indistinguishable from a legitimate multi-segment capture.
The 0.1 gate therefore accepts exactly one type-0 protobuf segment. It checks
that segment's declared length and payload SHA-256, fully frames its packets,
and rejects trailing/padding bytes, concatenation, and duplicate packets.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import struct
import sys
import tempfile
from pathlib import Path


HEADER_SIZE = 1024
MAGIC = b"OHOSPROF"
# Multi-segment containers stay unsupported until the format supplies a
# verifiable capture/session chain. This intentionally rejects otherwise valid
# optional symbol/native-hook segments rather than accepting synthetic size.
MAX_SEGMENTS = 1
MAX_PACKET_BYTES = 256 * 1024 * 1024
# OHOSPROF's uint32 `segments` field counts the length and value pieces, so it
# does not define a 100,000-packet protocol limit. Keep duplicate detection
# bounded by an explicit raw-digest index budget instead. The resulting
# fail-closed implementation limit admits the observed DAYU 200 count (110,380)
# without pretending that the resource policy is part of the wire format.
MAX_PACKET_DIGEST_INDEX_BYTES = 8 * 1024 * 1024
MAX_PROTOBUF_PACKETS = MAX_PACKET_DIGEST_INDEX_BYTES // hashlib.sha256().digest_size
MAX_TRACE_BYTES = 2 * 1024 * 1024 * 1024


class IntegrityError(Exception):
    pass


def read_exact(handle, size: int) -> bytes:
    data = handle.read(size)
    if len(data) != size:
        raise IntegrityError("truncated input")
    return data


def digest_payload(handle, size: int) -> str:
    digest = hashlib.sha256()
    remaining = size
    while remaining:
        chunk = read_exact(handle, min(1024 * 1024, remaining))
        digest.update(chunk)
        remaining -= len(chunk)
    return digest.hexdigest()


def inspect(trace: Path, after_open=None) -> dict:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(trace, flags)
    with os.fdopen(descriptor, "rb", closefd=True) as handle:
        initial = os.fstat(handle.fileno())
        if not stat.S_ISREG(initial.st_mode):
            raise IntegrityError("input is not a regular file")
        total_size = initial.st_size
        if total_size < HEADER_SIZE:
            raise IntegrityError("input is shorter than one header")
        if total_size > MAX_TRACE_BYTES:
            raise IntegrityError("input exceeds the supported byte bound")
        if after_open is not None:
            after_open()

        whole_digest = hashlib.sha256()
        remaining = total_size
        while remaining:
            chunk = handle.read(min(1024 * 1024, remaining))
            if not chunk:
                raise IntegrityError("input shrank during hashing")
            whole_digest.update(chunk)
            remaining -= len(chunk)
        if handle.read(1):
            raise IntegrityError("input size changed during hashing")
        handle.seek(0)

        segments: list[dict] = []
        payload_digests: set[str] = set()
        packet_digests: set[bytes] = set()
        segment_types: set[int] = set()
        protobuf_packet_count = 0
        offset = 0
        while offset < total_size:
            if len(segments) >= MAX_SEGMENTS:
                raise IntegrityError("segment count exceeds bound")
            handle.seek(offset)
            header = read_exact(handle, HEADER_SIZE)
            if header[:8] != MAGIC:
                raise IntegrityError("invalid segment magic or trailing bytes")
            declared_size = struct.unpack_from("<Q", header, 8)[0]
            version = struct.unpack_from("<I", header, 16)[0]
            declared_units = struct.unpack_from("<I", header, 20)[0]
            expected_payload_digest = header[24:56].hex()
            data_type = struct.unpack_from("<I", header, 56)[0]
            if declared_size <= HEADER_SIZE or declared_size > total_size - offset:
                raise IntegrityError("segment length is invalid")
            if version == 0:
                raise IntegrityError("segment version is invalid")
            if data_type != 0:
                raise IntegrityError("large evidence must be one protobuf segment")
            if data_type in segment_types:
                raise IntegrityError("duplicate segment type detected")
            segment_types.add(data_type)

            payload_size = declared_size - HEADER_SIZE
            if data_type == 0:
                if declared_units == 0 or declared_units % 2 != 0:
                    raise IntegrityError("declared protobuf segment count is invalid")
                declared_packet_count = declared_units // 2
                if declared_packet_count > MAX_PROTOBUF_PACKETS:
                    raise IntegrityError("protobuf packet digest index exceeds bound")
                # Every accepted packet has a four-byte prefix and at least one
                # payload byte. Reject impossible header counts before growing
                # the duplicate-detection index.
                if declared_packet_count > payload_size // 5:
                    raise IntegrityError("declared protobuf segment count is impossible")
                payload_digest = hashlib.sha256()
                consumed = 0
                packet_count = 0
                while consumed < payload_size:
                    if packet_count >= declared_packet_count:
                        raise IntegrityError("protobuf framing exceeds declared count")
                    length_bytes = read_exact(handle, 4)
                    consumed += 4
                    packet_size = struct.unpack("<I", length_bytes)[0]
                    if packet_size == 0 or packet_size > MAX_PACKET_BYTES:
                        raise IntegrityError("protobuf packet length is invalid")
                    if packet_size > payload_size - consumed:
                        raise IntegrityError("protobuf packet exceeds its segment")
                    packet = read_exact(handle, packet_size)
                    consumed += packet_size
                    payload_digest.update(length_bytes)
                    payload_digest.update(packet)
                    packet_digest = hashlib.sha256(packet).digest()
                    if packet_digest in packet_digests:
                        raise IntegrityError("duplicate protobuf packet detected")
                    packet_digests.add(packet_digest)
                    packet_count += 1
                if packet_count != declared_packet_count:
                    raise IntegrityError("declared protobuf segment count drifted")
                actual_payload_digest = payload_digest.hexdigest()
                protobuf_packet_count += packet_count
            else:
                actual_payload_digest = digest_payload(handle, payload_size)
                packet_count = None

            if actual_payload_digest != expected_payload_digest:
                raise IntegrityError("segment payload SHA-256 drifted")
            if actual_payload_digest in payload_digests:
                raise IntegrityError("duplicate container payload detected")
            payload_digests.add(actual_payload_digest)
            segment = {
                "byteCount": declared_size,
                "dataType": data_type,
                "payloadSHA256": actual_payload_digest,
                "version": version,
            }
            if packet_count is not None:
                segment["protobufPacketCount"] = packet_count
            segments.append(segment)
            offset += declared_size

        final = os.fstat(handle.fileno())
        if (
            initial.st_dev != final.st_dev
            or initial.st_ino != final.st_ino
            or initial.st_size != final.st_size
            or initial.st_mtime_ns != final.st_mtime_ns
            or initial.st_ctime_ns != final.st_ctime_ns
        ):
            raise IntegrityError("input changed during verification")

    if offset != total_size:
        raise IntegrityError("container does not consume the complete file")
    if protobuf_packet_count == 0:
        raise IntegrityError("container has no framed profiler packets")
    return {
        "byteCount": total_size,
        "formatVersion": 1,
        "protobufPacketCount": protobuf_packet_count,
        "segmentCount": len(segments),
        "segments": segments,
        "traceSHA256": whole_digest.hexdigest(),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("htrace integrity verification failed: expected input and output", file=sys.stderr)
        return 2
    trace = Path(sys.argv[1])
    output = Path(sys.argv[2])
    try:
        report = inspect(trace)
        encoded = (json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if len(encoded) > 1024 * 1024:
            raise IntegrityError("integrity report exceeds bound")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{output.name}.", suffix=".partial", dir=output.parent
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, output)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
    except IntegrityError as error:
        print(f"htrace integrity verification failed: {error}", file=sys.stderr)
        return 1
    except (OSError, struct.error):
        print("htrace integrity verification failed: filesystem or framing error", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

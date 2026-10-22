#!/usr/bin/env python3
"""Validate canonical and mutually consistent Phase 3 review timestamps."""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path


class EvidenceTimeError(Exception):
    pass


def load_object(path: str) -> dict[str, object]:
    try:
        value = json.loads(Path(path).read_bytes())
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceTimeError("evidence JSON is unavailable") from error
    if not isinstance(value, dict):
        raise EvidenceTimeError("evidence JSON must be an object")
    return value


def canonical_utc(value: object, field: str) -> datetime:
    if not isinstance(value, str) or len(value) != 20:
        raise EvidenceTimeError(f"{field} is not canonical UTC")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise EvidenceTimeError(f"{field} is not canonical UTC") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise EvidenceTimeError(f"{field} is not canonical UTC")
    return parsed


def validate(acquisition_path: str, grant_path: str, review_path: str) -> None:
    acquisition = load_object(acquisition_path)
    grant = load_object(grant_path)
    review = load_object(review_path)
    started = canonical_utc(acquisition.get("captureStartedAt"), "captureStartedAt")
    ended = canonical_utc(acquisition.get("captureEndedAt"), "captureEndedAt")
    acquisition_reviewed = canonical_utc(acquisition.get("reviewedAt"), "reviewedAt")
    grant_issued = canonical_utc(grant.get("issuedAt"), "issuedAt")
    signed_reviewed = canonical_utc(review.get("reviewedAt"), "signed reviewedAt")
    if not started <= ended < acquisition_reviewed:
        raise EvidenceTimeError("capture and review timestamps are out of order")
    if signed_reviewed != acquisition_reviewed:
        raise EvidenceTimeError("review timestamps disagree")
    if acquisition.get("reviewedBy") != review.get("reviewer"):
        raise EvidenceTimeError("reviewer identities disagree")
    # A redistribution grant may predate capture, but it must exist no later
    # than the signed review that relies on it.
    if grant_issued > signed_reviewed:
        raise EvidenceTimeError("redistribution grant postdates review")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--timestamp":
        try:
            canonical_utc(argv[2], "timestamp")
        except EvidenceTimeError as error:
            print(f"Phase 3 evidence time verification failed: {error}", file=sys.stderr)
            return 1
        return 0
    if len(argv) != 4:
        print("Phase 3 evidence time verification failed: invalid invocation", file=sys.stderr)
        return 2
    try:
        validate(argv[1], argv[2], argv[3])
    except EvidenceTimeError as error:
        print(f"Phase 3 evidence time verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

# Phase 3 external release evidence

This directory is the only accepted home for manually reviewed distribution
evidence. Evidence is intentionally absent until a real Developer ID signed
candidate has been exercised. `scripts/package_phase3.sh` requires one tracked,
bounded JSON manifest whose App tree SHA-256 and Code Directory hash match the
exact candidate and whose six checks each point to a distinct tracked artifact:

- keyboard-only Search → Timeline → Inspector navigation;
- VoiceOver selected event/range and completion/error announcements;
- minimum-window and long-localization layout;
- Reduce Motion behavior;
- minimum/non-overlapping interaction targets;
- focus restoration after sheets/disclosures/pane collapse.

Each check object has the exact shape
`{"status":"pass","artifactPath":"Fixtures/release-evidence/...","artifactSHA256":"..."}`.
The manifest also records the candidate tree SHA-256, Code Directory hash,
version, build, bundle identifier, Team ID, reviewer, and review timestamp.
It records whether the review was performed by an independent Agent or human.
The packaging gate requires the manifest and every artifact to be exact bytes
from `HEAD`, rehashes every artifact, and rejects missing, dirty, untracked,
duplicated, oversized, or candidate-mismatched evidence. Git history and the
independent review result are the audit record; a separate reviewer signing key
is intentionally not required because it would not add meaningful independence
when the reviewer and build run in the same workspace. Generated screenshots or
synthetic accessibility claims are not accepted as substitutes for the real
signed-App walkthrough.

The notarization audit record is
`Fixtures/release-evidence/phase3-notarization.json`. It binds the exact
accessibility manifest, signed candidate tree and Code Directory hash,
certificate and Team identity, final ZIP byte count and SHA-256, Apple
submission ID, and the post-staple signature, ticket, and Gatekeeper checks.
`Fixtures/release-evidence/phase3-notarization-receipt.json` is the bounded,
canonical semantic projection of the live `notarytool log` response. It is
produced with:

```sh
xcrun notarytool log <submission-id> --keychain-profile <profile> --output-format json | jq -S .
```

Every field is compared with a fresh Apple response, while the projection's
stable bytes and SHA-256 are pinned by the audit record. It is not described as
Apple's raw byte stream because JSON key order can change between otherwise
equivalent queries.

The final ZIP is retained outside the repository `.build` tree in an
owner-bound physical system temporary directory so later build gates cannot
silently clean it. A reviewer must independently rehash and extract that
physical ZIP and reverify the nested and outer signatures, stapled ticket, and
Gatekeeper result. The JSON metadata is not a substitute for the retained
artifact.

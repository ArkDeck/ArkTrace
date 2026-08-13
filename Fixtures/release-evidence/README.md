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
The packaging gate rehashes every artifact and rejects missing, untracked,
duplicated, oversized, or candidate-mismatched evidence. Generated screenshots
or synthetic accessibility claims are not accepted as substitutes for the real
signed-App walkthrough.

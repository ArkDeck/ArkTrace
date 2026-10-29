---
id: CHG-2026-001-native-product-consumer
revision: 1
status: proposed
class: integration
owner: fuhanfeng
---

# Native product consumer startup and packaging

ArkDeck's pending native SDK integration cannot consume published ArkTrace:
bundled startup and tool preparation currently assume the standalone ArkTrace
product, and SDK staging treats the resolved dependency checkout as the source
repository. The existing local consumer pin is not available from the remote.

Expose bundled startup for a fixed `TraceProductConfiguration` and publisher
prefix. Preserve the standalone overload, signed in-place parser requirement,
bounded manifest validation, private roots and explicit shutdown ownership.
Allow directory traversal through search-only ancestors without granting read
access or changing existing permissions.

Add the explicit ArkDeck build profile for sandbox-inheriting helper/parser
signatures and its existing parser bundle location. Keep requests unable to
select a profile. Bind SDK staging to the physical consuming repository so a
resolved checkout outside that repository can receive verified artifacts.

This is an implementation of AT-SYS-002/006's shared product composition
boundary. No parser, schema, ABI, CLI distribution or device policy changes.
ArkDeck pins and App wiring remain in its own dependent PR. Compilation and
synthetic packaging checks do not establish signed App or hardware acceptance.

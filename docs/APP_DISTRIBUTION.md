# ArkTrace.app 0.1 distribution decision

Status: reviewed implementation candidate for P3-T01 (2026-08-13).

## Target and signing

- macOS 14 or later, Apple silicon (`arm64`) first release;
- direct Developer ID distribution and notarization; App Store/TestFlight and
  Intel are explicitly deferred until the child-process and performance
  evidence is repeated for those channels;
- Debug uses ad-hoc signing for local launch tests. Developer ID Application +
  hardened-runtime distribution is the reviewed Release candidate; archive,
  notarization and quarantine evidence remain P3-T10 and are not claimed here.

## Sandbox and file grants

ArkTrace 0.1 does **not** enable App Sandbox. The product must execute the
reviewed, pinned TraceStreamer child and support Finder Open With for arbitrary
user-selected traces. This is narrower and more testable than adding broad
temporary sandbox exceptions. P3-T05 will persist security-scoped bookmarks
when URLs arrive with a security scope, but it will not treat a bookmark as
permission to broaden a path or to upload data.

The empty app entitlement file deliberately grants no network client/server,
USB/device, HDC, camera, microphone, location, or automation capability.
ArkTrace 0.1 is an offline local viewer.

## Parser bundle boundary

The Xcode target copies exactly these reviewed inputs into
`Contents/Resources/TraceStreamer/`:

- `ThirdParty/TraceStreamer/macx/trace_streamer`;
- `ThirdParty/TraceStreamer/macx/manifest.json`.

Production resolution checks only that bundle location. It never searches
`PATH`, `DYLD_*`, environment variables, Homebrew, or a user-writable global
location. Every parser child receives a fixed minimal environment rather than
the App/CLI environment. Missing bytes return `TRACE_STREAMER_UNAVAILABLE`; manifest, Mach-O,
hash, version, or provenance drift returns
`TRACE_STREAMER_IDENTITY_MISMATCH`. The separate developer resolver accepts an
explicit URL and is compiled only in Debug builds.

## Storage

Cache data is dedicated to
`~/Library/Caches/com.arktrace.ArkTrace/`; original traces are never copied into
the cache as user documents. Recent-item/bookmark state belongs in the app's
Application Support container and is implemented by P3-T05. Existing Runtime
ownership, lease, quarantine, and path-hardening rules remain the only cache
mutation implementation.

## Shared implementation

The native target consumes local Swift package products. It does not copy
Core, Parser, Store, Runtime, Analysis, or Rendering sources. The canonical App
version/build/bundle identifier live in `Config/ArkTraceProduct.xcconfig`;
`ArkTraceCore.ArkTraceProduct` is the checked SwiftPM/CLI mirror, while Info.plist
expands the same Xcode build settings. Tests and the app gate fail closed on drift.

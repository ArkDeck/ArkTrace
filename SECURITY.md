# Security policy

ArkTrace parses local traces, serves them through a host-only CLI and analysis
engine, and, in the macOS app, can capture from a device the user selects. A
report that describes a parser-identity bypass, machine output that leaks a
local path or trace contents, cache or staging that accepts another user's
data, or a capture aimed at a device the user did not select is in scope.

## Reporting

Please report a vulnerability privately. Do not open a public GitHub issue,
pull request, or discussion for it.

Use GitHub private vulnerability reporting:

<https://github.com/ArkDeck/ArkTrace/security/advisories/new>

If that page is unavailable, contact the maintainer listed in
[`.github/CODEOWNERS`](.github/CODEOWNERS) directly and wait for a private
channel. There is no public security mailing list.

## What to include

- affected component (macOS app, `arktrace` CLI, Windows CLI, capture, parser
  pin, or a contract)
- the full git commit you ran
- the impact you can already demonstrate, at a high level
- whether a device, credential, trace file, or local cache was involved

Do not include device serial numbers, account names, machine names,
home-directory paths, signing keys, or raw trace contents. Redact logs before
you send them.

## What happens next

The maintainer acknowledges a report that reaches the private channel and
agrees on a fix and a disclosure window before any public write-up. This
repository does not publish git tags or GitHub Releases for security fixes;
the fix lands on `main` through a reviewed pull request.

There is no bug bounty.

## Supported versions

| Line | Supported |
| --- | --- |
| `main` | yes |
| older untagged history | no |

Only the `main` branch is supported. The project is in development, and
interfaces can change before a stable release.

## Out of scope

- a missing viewer feature or a product request with no security impact
- a vulnerability in an OpenHarmony image, `hdc`, TraceStreamer, or another
  third-party tool that ArkTrace does not ship, except where ArkTrace fails
  to contain it
- social-engineering attacks against a maintainer account

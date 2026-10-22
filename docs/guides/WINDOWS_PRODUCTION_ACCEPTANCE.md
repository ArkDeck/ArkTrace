# Windows CLI production and installed acceptance

The reviewed Windows producer is `hack/package_windows_cli_distribution.py`.
The manual `Windows production acceptance` workflow builds its actual
`authenticode-publisher` package and then exercises the unchanged ZIP on a
separate clean Windows installation. Development packages and package smoke on
the build host do not satisfy this gate.

The workflow first requires the protected default branch. Configure its
`windows-production` environment to allow only that branch. The signing runner
needs labels `self-hosted`, `Windows`, `X64`, `arktrace-signing`, PowerShell 7.4+,
Python, exact Rust 1.99.0, x64 MSVC tools and the Windows SDK SignTool expected by
the existing producer. Configure these environment variables:

| Variable | Input |
| --- | --- |
| `ARKTRACE_WINDOWS_PUBLISHER` | Exact production publisher, using the existing O=, else CN= identity policy |
| `ARKTRACE_CERT_THUMBPRINT` | Existing CurrentUser/My code-signing certificate with usable private key |
| `ARKTRACE_TIMESTAMP_URL` | HTTPS RFC 3161 timestamp service |
| `ARKTRACE_PARSER_PATH` | Runner-local unsigned parser rebuilt from the committed Windows recipe and matching its manifest SHA-256 |

Keep private keys in their existing certificate/key provider. No key, password
or signing-service credential belongs in a variable, command transcript or
artifact. The workflow refuses a self-issued certificate, dirty/mismatched
source, development signing, missing timestamps or unverified package bytes.
The normal producer and verifier retain their development use cases.

Provision a second runner on a fresh Windows x64 image, labelled `self-hosted`,
`Windows`, `X64`, `arktrace-clean`. It needs the Actions runner and PowerShell
7.4+, with no Rust, MSVC, Windows SDK or globally installed VC++ redistributable.
Do not reuse the signing installation under another runner name. Installed-tool,
SDK-registry and redistributable checks supplement this image requirement;
they are not proof that an arbitrary existing machine is a fresh image. The
acceptance script also rejects a matching Windows MachineGuid fingerprint.
Only the fingerprint, never the MachineGuid or machine name, enters the receipt.

The clean-host job does not checkout source or install Python or build tools.
It verifies this run's harness hash, whole ZIP hash, manifest hash, complete
member inventory and every member hash before running the signed install.
All images must have valid, non-self-issued, timestamped Authenticode
signatures. The manifest's source, publisher and timestamp policy must match
the verified producer. Native CLI launches inherit only Windows system paths;
they use the normal known-folder storage root. An unsafe host root fails the
gate rather than being silently replaced or changing its ACL.

Installed `doctor`, licenses, summary, inspect and CPU analysis run from a new
owner-private directory with no build tree present. A second doctor call after
moving that install proves relocation. The workload uses the shipped pinned
`zlib.htrace` fixture. It proves production package installation and CLI
functionality; it is not a real-device capture, ArkDeck consumer integration,
large-trace or hardware acceptance claim. Production ArkDeck analyzer selection
and its capture/inspect/Job/export acceptance remain a separate consumer run on
the exact distribution.

Run from the protected default branch after the inputs and runners exist:

```powershell
gh workflow run windows-production-acceptance.yml --repo ArkDeck/ArkTrace --ref main
```

Retain both artifacts from the same successful run/attempt:
`arktrace-windows-production-<sha>-<run>-<attempt>` contains the verified ZIP,
harness and delivery hashes; `arktrace-windows-installed-<sha>-<run>-<attempt>`
contains the installed acceptance receipt. The build delivery honestly records
`cleanHostAccepted: false`: only the separate passed receipt closes that gate.
A build artifact alone, queued/skipped job or failed run is not acceptance.
Original command outputs and failed installs stay private on the clean host;
only the path-free receipt is uploaded. No existing install or raw Trace is
overwritten or removed.

Local guard regression (synthetic archive and signature facts, no image execution):

```powershell
pwsh -NoProfile -File hack/Test-WindowsProductionAcceptanceContract.ps1
```

This regression runs in the normal native Windows CI lane. It cannot establish
a production or clean-host pass without the separate actual workflow run.

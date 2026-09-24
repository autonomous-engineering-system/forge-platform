# Forge Platform Installer for macOS

This Swift Package contains the native SwiftUI wizard shell for the Forge
Platform Universal Installer. It is intentionally an orchestration UI, not a
second product installer engine.

The package targets macOS 26 and admits only a native arm64 process on Apple
Silicon hardware. Startup rejects Intel, Rosetta translation, and older macOS
before it adopts installer state or reaches update transport. Release metadata
must name exactly one arm64/macOS-26 asset, and current/staged bundle inspection requires
the actual executable to be a thin arm64 Mach-O file; fat/universal installers
and `x86_64` fallback assets are not supported.

The shell provides these gated screens:

- a mandatory self-update gate that accepts only a verified GitHub Release
  descriptor from a future trusted bootstrap coordinator;
- one verified, immutable composition-session selection that atomically binds
  the public composition/catalog/manifest identities to its provider
  requirements before any downstream gate;
- host-preflight evidence, including installer-owned Git and Python toolchain
  checks for that accepted session without selecting or modifying an unrelated
  global toolchain; the signed outer catalog now carries the one exact approved
  managed-Python identity for subsequent manifest/session verification;
- a dynamic Codex CLI / GitHub CLI provider screen, with independent selection,
  install, authentication, and verification states derived only from that
  session;
- product-owned inventory and qualified composition-diff review;
- product-owned execution/readiness evidence; and
- an installation summary including product-supplied dashboard URLs and a
  `System LaunchDaemon` service scope where applicable.

An older installer cannot advance past the self-update gate. The core includes
`VerifiedInstallerSelfUpdateCoordinator.enforceCurrentInstaller`, which makes
startup update enforcement automatic once the app wires in trusted adapters: it
accepts a signed GitHub Release record, checks the sealed identity of the
running bundle, stages one exact release asset, verifies its SHA-256,
code-signature and notarization independently, and only then delegates an
atomic handoff/relaunch. A release sequence plus source, provenance and code
directory digests rejects rollback, replay and same-version/different-bytes
replacement. After successful current-installer enforcement, the coordinator
retains the exact signed catalog-feed locator and may hand only that sealed
release context to an injected composition-session preparer. It accepts a plan
only when installer sequence, provenance, release-trust-configuration digest,
catalog locator, distinct outer catalog/index identities, selected entry and
provider requirements are bound to that context; concurrent, stale and
mismatched results fail closed. The core now includes an internal, read-only
catalog-admission coordinator: it loads only sealed catalog trust, fetches the
exact sealed locator, requires separately injected independent clock evidence
for those exact bytes, and reads (but cannot write) the durable anti-replay
anchor before applying strict JSON/signature/channel/expiry verification. Its
output is ephemeral verified outer-catalog evidence plus a candidate anchor; it
does not persist, fetch an index/manifest, produce a session or change a
product. A separate pure native selector accepts only exact index bytes pinned
by that verified outer catalog. It retains distinct outer/index identities,
rechecks both outer/index publication and expiry against supplied trusted time,
requires an exact requested component set and explicit upgrade route, and
returns `installerUpdateRequired` for the newest routable entry when its
minimum version or capabilities exceed the current installer; it never falls
back to older bytes. When a future coordinator supplies a matching accepted
index anchor, it rejects replay and same-sequence/different-byte input. The
selector writes no anti-replay anchor and has no
transport, manifest, session, UI, provider or product-operation authority. The
default clock attester is typed unavailable—neither the local
clock nor an HTTP `Date` header is sufficient evidence—and the default session
preparer remains typed unavailable. The core also has a credential-free
exact-locator transport seam, a code-signed catalog-trust resource loader and
an installer-owned durable catalog-anchor store keyed by raw release-trust
digest, channel and exact feed locator. The store accepts only a typed
`COMPLETE` terminal-operation commitment and rejects regression/conflicting
bytes, but it has no product receipt validator or caller yet. This package
still has no manifest verifier or session-plan producer. A future trusted
coordinator must first accept one immutable composition session; every enabled
provider from that session must then be in the `verified` state before the
wizard can continue.

The released app is wired through `ReleasedInstallerStartupBoundary`: it does
not construct a wizard with `UnavailableInstallerWizardCoordinator`, and it
does not offer a manual update bypass. The boundary first requires both sealed
release-trust and release-provenance resources, binds their exact trust-policy
digest, builds a trusted runtime from them, and calls automatic startup
enforcement. Only a `current` result creates the wizard; a relaunch or any
missing/invalid/mismatched resource stays on a fail-closed status screen.
Interrupted installer-only work is recorded in a separate non-secret recovery
journal with typed staged-file identity and handoff-receipt evidence. It is not
a product database or a component installation journal.

Before startup recovery, release qualification, staging, verification, or
handoff, a trusted runtime also obtains one non-blocking host-wide self-update
lease. The supplied file-backed implementation uses a permanent, installer
owned lock inode with restrictive permissions and an advisory kernel lock; a
busy or unsafe lock state blocks rather than racing a second installer. A
successful handoff keeps its lease until the old process exits (or `exec`s),
while the replacement retries that specific short handoff window only a bounded
number of times. Production composition must place this state root under its
privileged, machine-wide installer controller. A per-user directory does not
prove cross-account uniqueness.

The sealed trust descriptor is a public V2 policy resource named
`ForgePlatformInstallerReleaseTrust.json`. It has exact fields for the GitHub
repository, the fixed `github-release-asset-v1` descriptor convention and
asset name, expected bundle/team identity, threshold, and ordered Ed25519 key
IDs plus canonical Base64-encoded public keys. Its SHA-256 covers a
domain-separated, NUL-delimited representation of those accepted semantics.
The package's bundle packager validates that exact V2 form and copies an
explicit, non-symlink resource verbatim; source builds carry no resource and
therefore fail closed. The descriptor never contains a private key, credential,
URL, arbitrary transport setting, product authority, or installed-component
state.

The descriptor is checked inside a strictly validated macOS code-signed bundle
and is bound separately into signed release/current/staged-bundle identity
checks. Its checksum is not a substitute for code signing or the signed
release-feed trust root; those remain required and absent configuration still
fails closed.

The separate public V1 resource
`ForgePlatformInstallerReleaseProvenance.json` binds stable installer version,
channel, positive release sequence, source and policy revisions, sorted
capabilities, and the exact V2 release-trust configuration digest. Its own
digest uses an explicit NUL-delimited canonical representation. The startup
boundary rejects an absent, malformed, unsealed, installer-version-mismatched,
or trust-configuration-mismatched provenance record before it builds a runtime
or shows the wizard.
The model exposes only a pure exact-identity comparison for a future signed
descriptor verifier; it does not fetch a feed, authorize an update, stage
bytes, or grant product authority. Source builds carry no provenance resource
and remain fail-closed.

The default product coordinator fails closed. The native verified session now
retains the complete managed-Python identity and exact per-component venv
bindings after recomputing the runtime commitment and matching it to the signed
outer catalog. A separate platform-neutral source executor durably coordinates
exact managed-Python downloads, archive
inspection, immutable runtime slots, isolated product venvs, activation,
interruption resume and exact-identity rollback through injected interfaces.
It is not wired to the native mutation route. The core ships a native,
credential-free HTTPS transport that accepts only the admitted runtime identity
and a closed asset-kind value, denies redirects and final-URL drift, streams
under fixed size limits, and verifies the exact tagged digest before returning
identity-bound bytes. It ships no archive inspector, staging/receipt bridge or
privileged mutation adapter. The native signed-catalog
verifier requires and returns one exact approved managed-Python identity; the Python
policy kernel verifies the complete version, thin arm64 macOS artifact,
source/build provenance, ABI/tag, minimum macOS and policy-revision material,
requires every product's build/test evidence to name that identity, assigns
each product a distinct opaque venv identity, and freezes target/rollback
identities in the operation journal. This remains source-only capability: the
released package does not stage, inspect or install Python, create a venv, or
claim that a production arm64 runtime artifact has been approved. It ships no real
release URL, signing key, credential, shell invocation, privileged helper or
product adapter. A production composition must inject implementations for the
signed-feed verifier, current-bundle inspector, operation-owned downloader,
SHA-256/code-signature/notarization verifier and atomic handoff. The core never
constructs commands from UI input, stores credentials, changes global
Git/Python tooling, writes a product database, selects a runtime, creates a
venv, or installs/modifies a service. Product-adapter integration remains under
the product-owned contracts in the repository architecture.

The unsigned app-layout helper accepts a V2 release-trust resource and V1
release-provenance resource only as an explicit matched pair through
`--sealed-release-trust-resource PATH` and
`--sealed-release-provenance-resource PATH`. It validates their strict native
forms, rejects symlinks, duplicate/unknown fields and explicit key-material
fields, and copies the captured bytes verbatim into the candidate bundle. It
never finds, generates or defaults a production identity, repository, URL,
public/private key or credential. Omitting either resource leaves the candidate
fail-closed until a protected release packager supplies reviewed non-secret
resources and code-signs the completed bundle.

That helper may additionally accept
`--sealed-composition-catalog-trust-resource PATH`. It permits the separately
scoped V1 catalog-signing policy only beside the matched V2/V1 pair and only
when its `installer_release_trust_configuration_sha256` equals the packaged
V2 trust configuration digest. It copies the exact validated policy to
`Contents/Resources/ForgePlatformInstallerCompositionCatalogTrust.json`; an
absent policy remains explicitly fail-closed. Packaging this resource does not
wire the native loader, fetch a catalog, create a composition session, or
authorize a product operation.

Run the pure state-machine tests on macOS:

```sh
cd macos/ForgePlatformInstaller
swift test
```

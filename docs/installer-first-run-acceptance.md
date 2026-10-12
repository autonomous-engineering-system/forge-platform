# First-run installer acceptance

## Current acceptance snapshot — 12 October 2026

Public installer **0.4.10** contains the released first-run implementation and
its signed helper package/companion. Both descriptors, Developer ID,
notarization/staple/Gatekeeper and payload bindings are artifact-qualified.
Actual clean public GUI/CLI helper setup, one-login fanout and clipboard usability
remain **NOT_RUN** in the recorded acceptance inventory. Artifact or source
qualification does not complete them.

See the [complete LANE_1 matrix](roadmap/INSTALLER_FEATURE_TEST_MATRIX_V1.md)
and [case inventory](roadmap/installer-feature-test-matrix-v1.json).
The dated sections below preserve the development sequence. Their statements
such as "not published" or "signer has not run" describe that earlier stage,
not current 0.4.10 artifact status. The requirement bullets remain normative.

The published build must be qualified against these operator requirements on a clean Mac.

## Helper access

- The installer initiates helper setup within its own installation flow.
- Use a supported macOS administrator authorization and verify the exact signed helper independently before continuing.
- The user must not have to find Login Items or manually arrange helper registration outside the installer.
- Automatically approving security settings, changing TCC data or raw helper process control is not an acceptable implementation.
- Current `SMAppService.register()` for a LaunchDaemon requires administrator approval in System Settings. Automatically opening that panel alone does not meet the requested no-manual-Login-Items route. A supported alternative installation/authorization route must be qualified before this requirement is marked complete.

Apple reference: https://developer.apple.com/documentation/servicemanagement/smappservice/register()

## Provider access

- One human Codex authentication ceremony for the selected installation.
- The installer dispatches the provider bootstrap only inside its bounded, reviewed credential route to the selected EP and Forge instances.
- Keep distinct component runtimes, owners and authentication contexts; independently verify both exact targets after dispatch.
- Do not infer Forge authentication from the EP receipt. Do not hide a second ceremony behind a single UI row.
- EP GitHub has its own one-time provider ceremony. Forge has no GitHub provider.
- No manual credential copying, caller-supplied credentials, credential contents in journals/logs or fixture-backed installation proof.
- The native source now admits the complete selected Codex group before one ceremony, bootstraps only through the user-approved same-host helper route, and independently verifies each target. That development-stage source qualification did not prove publication or live authentication; current release/acceptance status is stated above.

## Device code usability

- The visible one-time code remains selectable.
- Provide a clearly labelled **Kopieer code** action adjacent to the code, writing only that displayed code on an explicit user click.
- Retain the official verification-page link and explicit verification after user authentication.
- The clipboard action is present in source in both GUI authentication screens and the GUI product compiles. Current publication is recorded above; actual published GUI clipboard acceptance is still unqualified.

## Local source qualification (2026-10-10)

The bounded bootstrap implementation passed 1,542 native tests and the strict
per-file production Swift coverage gate. Independent source review passed.
The customer view groups selected EP/Forge Codex into one action while keeping
readiness per target and EP GitHub separate. Synthetic rendering and presentation
contract checks are source assurance only; their native button rasterization is
not accepted as a published GUI usability receipt.

Historical uncertain effects still block new authentication. There is no
implemented general reconciliation route. Keep their journal and uncertainty
intact until a supported recovery is separately qualified.

An unsigned helper-package prototype was generated from the exact public 0.4.9
app. It is not deployable and proves no first-run onboarding. Package trust,
normal administrator authorization, registration/readback and lifecycle
integration remain required before a package route is used.

## Bootstrap app assembly (2026-10-11)

The unsigned app packager can now include the separately linked bootstrap in
`Contents/Library/LaunchServices` and set the fixed mutual Developer ID
requirement. Before producing the bundle it checks bounded thin-arm64 Mach-O
sections against the exact parsed release trust and provenance bytes. It copies
those captured binary bytes, so replacing the input afterward cannot change the
admitted payload. Missing, duplicate, overlapping, truncated or mismatched
metadata is rejected. Existing packaging without this optional input is retained.

The scoped packaging qualification passed 42 checks, the existing strict Python
coverage threshold and a read-only inspection of the retained real local link
prototype. This is unsigned source assembly only. The official offline signing source now prepares the exact metadata, links and
packages the bootstrap, signs it before the app, and verifies its fixed Developer
ID requirement before notarization and after carrier extraction. The signer has
not run for this source. Signing, notarization, administrator handoff,
installed-bootstrap readback and package installation remain unqualified.

The historical effect record cannot be retired from process absence alone: its
schema does not identify a credential effect or establish completed ownership
readback. Its sticky uncertainty remains preserved; no reset, new operation or
authentication retry is authorized by this assembly qualification.


## Package-bearing release producer qualification (2026-10-11)

The local qualifier now has paired optional signed helper-package inputs. It
emits descriptor V2 only after actual Developer ID Installer/team, stapled
notarization and Gatekeeper checks, stable private file readback, and exact
payload binding to the already captured installer archive digest. V1 remains
the default. PackageInfo, the legacy CPIO payload and BOM must agree on the
fixed app, release provenance, every app byte/mode, root ownership and fixed
LaunchDaemon. Extra scripts, files, links and installation selectors fail closed.
Only the existing strictly bounded macOS provenance metadata profile is accepted;
its opaque bytes are never published as evidence.

The package preparer copies public app bytes without local attributes, retains
all real Apple app checks, fixes payload directory modes and requests legacy
compression. Its output remains an unsigned candidate with no production
admission. Twenty-five focused checks passed; changed production files exceed
the existing strict 80.2 percent coverage gate (86.5 to 98.78 percent). A genuine
public-app package preparation supplied the producer coverage evidence. Source
review identified an initial missing release/payload binding; the bounded
payload inspection fixed that finding and the subsequent read-only review passed.

The native package verifier also rejects a FIFO before blocking on its contents.
Eight focused native checks and 96.75 percent verifier coverage qualified this
source fix. Neither group installed a package, changed a helper or retired a
historical uncertain effect record.

Remaining delivery gates include V2 structural publication/readback and actual
signed-package production, root installation/effect journaling and activation,
frontend installed-helper readback, supported historical recovery, protected
publication and real public CLI/GUI qualification. Public 0.4.9 remains unchanged.


## V2 structural handoff and companion publication readback (2026-10-11)

The structural release gate now accepts the native V2 companion shape only with
an explicitly supplied helper package. It reruns the actual fixed platform and
exact archive/payload inspector and compares all helper metadata with the
operation-bound descriptor. V1 rejects an unbound companion input.

The publication recorder requires both original companion bytes and a separate
readback matching the descriptor's fixed filename, digest and size. Stable
regular single-link file identities are captured; identical device/inode pairs,
including ancestor-path aliases, are rejected before journal mutation. The
existing publication receipt binds the complete descriptor digest, which includes
the companion metadata; historical journal schemas are unchanged. Missing or
wrong companion bytes cannot produce a new PUBLISHED record. The CLI evidence
reader now refuses FIFO input without blocking.

Twenty-seven scoped checks passed, including actual private test journals and
actual CLI subprocess tests. The existing coverage measurement additionally ran
those same verifier CLI checks in-process so their child lines could be traced:
package identity/readback 100 percent, publication recorder 92.920354 percent,
structural verifier 80.677966 percent, all strictly above 80.2. The new readback
module and its tests join the unchanged canonical coverage gate. Initial expanded
coverage measurements and the review's same-file-readback finding are retained;
the finding was fixed and scoped read-only re-review passed.

These are source gates only. No GitHub release was uploaded or downloaded by
these tests, no signer ran and no real operation became PUBLISHED. Production
signer/upload/download orchestration still needs the companion package wired in;
root installation, activation, first-run readback and historical recovery remain
open. Public 0.4.9 and its original product pins are unchanged.


## Offline signed companion orchestration (2026-10-11, source only)

The protected offline signer now selects exactly one existing Developer ID
Installer identity of the same team, from private bounded public certificate
metadata. The selection is separate from the app's Developer ID Application
identity; no identity is created, exported or displayed. The required selector
must be configured in the existing bounded signing route before any actual run.
No certificate inventory or signing authority was exercised in this qualification.

A source-only library cannot execute as a standalone signer. Its protected
caller builds the script-free candidate from the actually verified app and
checks the exact previously captured archive digest and full payload before
productsign. It then uses the existing private notary profile, requires an
accepted canonical submission UUID, staples the package, and independently
reruns the existing actual platform/payload verifier before emitting the private
companion receipt. Offline evidence is explicitly V2 and contains the closed
companion metadata; publication remains NOT_PERFORMED.

Nine scoped source checks passed, including execution of the actual shell/Python
argument handoffs, real unsigned candidate format/digest checks, refusal of
standalone execution and inert sourcing. The final handoff's substituted
inspector is only a wire check and proves no Apple trust. The new parser has
100 percent coverage under the unchanged strict gate. Shell syntax and scoped
read-only review passed after an argument-index finding was corrected. No signer
script, Keychain operation, notary submission or installed-helper action ran.

The regular release upload/download/descriptor pipeline still needs the signed
companion wired in. Root install/activation, installed-bootstrap readback,
frontend composition and historical recovery remain separate open gates.


## Protected publisher companion wiring (2026-10-11, source only)

The regular local publisher retains V1 candidates without a bootstrap. For a
bootstrap-bearing candidate it requires the separate Installer selector, signs
and verifies the bootstrap before sealing the app, then verifies the bootstrap
again in the actual stapled archive carrier. Companion signing starts only after
carrier extraction and all existing staple/Gatekeeper/signature/caller checks.
The library now owns its bounded private command runner and does not depend on
an offline-only caller function.

Explicit argument arrays pass the signed companion and its notarization reference
to the V2 qualifier and structural verifier. The companion is uploaded, separately
downloaded and byte-compared before publication-journal admission; its public
readback is downloaded and compared again after the draft becomes public. The
existing recorder enforces independent file identity and descriptor digest/size.
No new operation or historical journal schema is introduced by this wiring.

Twenty-one scoped dependency checks passed, including real early refusal of
unauthorized contexts before checkout/artifact work, shell syntax, actual metadata
handoffs and private companion-journal checks. A source-order regression check
covers carrier trust before package effects and download before publication.
Read-only review found an initially misplaced companion block; it was moved after
carrier checks and the scoped re-review passed. These checks did not run the
publisher, contact GitHub/Apple for delivery, sign an artifact or prove installation.
Actual protected publication, root installation/activation, frontend installed
readback and historical recovery remain open.


## Independent installed-reader blocking/race gate (2026-10-11)

Before adding root installation effects, the existing installed-helper reader
was checked for bounded refusal. Its helper, app metadata and daemon-file opens
now use nonblocking no-follow admission. The daemon data is read from that same
admitted regular file descriptor, with a 16 KiB bound and unchanged owner, mode,
link and ACL constraints; descriptor, named-leaf and parent identities are checked
again afterward. No named-file reopen occurs between admission and contents read.

Seven targeted native checks passed, including three actual no-writer FIFOs
(helper, Info and daemon) and the existing root-tree/identity/mutation contracts.
Delayed test writers bound a regressed blocking open and finish before private
fixture cleanup. Changed-reader coverage is 84.234234 percent, strictly above
80.2; scoped read-only review passed. This is source negative/readback assurance,
not an installed helper, root activation or first-run proof. No production path
was mutated or service started/stopped by these checks.

Root installation still requires its own durable effect evidence and verified
activation/readiness. The product/provider effect journal intentionally cannot
be reused as proof of package state: empty child IDs or installer exit zero do
not prove installed files, namespace ownership, credential quiescence or readiness.
Historical authentication uncertainty remains unchanged.


## Durable root package-effect ledger (2026-10-11, source only)

A separate root-private journal now records package install intent, attempted
installation, actual installer exit code, attempted activation and recorded
readback. It binds one server-generated attempt ID to the selected package digest,
size, release sequence, source, provenance, trust, app CodeDirectory and admitted
client UID. The fixed production root is the bootstrap's private root; root EUID,
0700 directory, 0600 regular single-link files and empty ACL are required. Test
root/owner seams are internal and absent from CLI/IPC/environment configuration.

History is append-only, ordered and canonical, with an exclusive lock and
synchronized file/directory publication. Partial pending files, gaps, unknown
records, unsafe links/modes, foreign attempts and changed bindings close admission.
There is no delete, clear, automatic retry or historical-auth retirement API.
Unknown or nonzero installer exit cannot admit activation; durable readback
rechecks the same exitcode continuity, so a failed exit followed by a success-like
activation record is corrupt rather than a recovered success.

Seven focused native checks passed, including private real filesystem and lock
hazards, restart readback, immutable history and a canonical inconsistent outcome
chain. Coverage of the new file is 99.509804 percent under the unchanged strict
80.2 gate. Read-only review identified the initially missing durable exitcode
continuity; it was fixed and scoped re-review passed. Initial source-test temporary
path resolution failed before ledger checks; physical realpath corrected that
fixture without relaxing the production no-follow rule.

This ledger is not wired to root runtime execution. It grants no installation
permission, does not claim readiness and leaves the product/provider effect
journal untouched. Actual package installation, independent installed-file
verification, initial activation, fresh readiness, frontend/backend integration
and qualified historical recovery remain separate open gates.


## V1 update compatibility and separately signed helper descriptor (2026-10-11)

This supersedes the earlier proposed sole-public-V2 descriptor route. The
immutable public 0.4.9 updater requires the canonical V1 descriptor. The producer
therefore preserves `ForgePlatformInstallerReleaseDescriptor.json` as V1 and
adds `helper-package-companion/v1` to its signed capabilities. The fixed
`ForgePlatformInstallerHelperDescriptor.json` carries the V2 package metadata,
independent threshold signatures under the existing keys, and the digest of the
exact signed V1 bytes. All other release fields must match. Public primary
entrypoints require V1 and refuse a missing or invalid required companion.

The original primary replay anchor remains intact. Native production consumers
and the Python bytes consumer additionally require a separate durable companion
anchor before exposing the joined release. Replay files/directories reject ACLs,
unsafe modes, links and nonregular files; native reads do not block on FIFOs.
The original qualification receipt binds the full companion digest without a
journal schema change. Publication requires independent exact companion and
package readback before writing publication evidence. The finite release set is
five assets: app archive, helper package, V1 descriptor, helper descriptor and
operation receipt. Existing journals, trust keys and release limits are retained.

Source-only qualification: the complete native test suite and every production
Swift file pass the strict >80.2% coverage gate. The Python owning coverage suite
passes the same per-file threshold. Producer qualification uses real temporary
Ed25519 test signatures for both descriptors and tests that a changed helper
package digest invalidates the signature. Independent scoped Quality/Security
review found no remaining compatibility findings; committed-head attestation
and protected CI remain delivery gates. No new signed public artifact or
installed CLI/GUI acceptance is claimed by these source results.


## Provider-page and history increment (2026-10-12)

The customer flow must present one continuous provider page. The first overview
already groups Codex for EP and Forge, with GitHub for EP separately. A direct
provider button performs the existing reviewed staging and currency checks before
starting that selected provider's official authentication. Each target remains
independently verified; one verified Codex target is not complete readiness.

Previous completed steps are available through the visible step list and
**Vorige stap bekijken**. These controls display immutable metadata snapshots;
they never call the mutable wizard's `goBack`, stage providers, restart a login,
or replay installation. **Terug naar huidige stap** restores active controls.
Snapshots contain no authentication challenge, token or password. Their context
includes the session, release, provenance, trust, catalog and deployment, so a
new session with identical manifest bytes invalidates earlier results.

Qualification must cover direct provider actions, one-time action consumption,
independent target readiness, navigation while an action is pending, stale-session
callbacks and session/release changes. Source/AppKit rendering evidence is only
source assurance. The published signed GUI must still be operated through its
actual screens through installation, pairing and readiness before owner handoff.
No source or artifact result substitutes for that installed E2E result.

A clean qualification environment must also exclude stale account ACLs on the
installer's parent directories. Removing product files and a generated account
alone does not establish a clean host. Unknown ACL identities remain a hard
rejection: do not relax the trust guard, silently remove ACLs, or start a new
operation to evade the failure. Preserve journals and obtain scoped authorization
for any necessary metadata recovery, then use the existing operation's supported
recheck. Record archive, identity, unchanged journal hashes and actual outcome.


### Failed checks must be actionable

A failed first-run check names the failed check and distinguishes unavailable
observations from proven hardware/resource failures. Show an explanation, the
supported next action and a stable bounded diagnostic code on the main page.
Do not instruct the operator to "solve the problem" without identifying it.
Installer/controller failures must not be presented as inadequate Mac hardware.
The explicit **Kopieer diagnose** action contains only the installer version and
closed diagnostic codes; arbitrary coordinator text, credentials and authentication
challenges never enter that clipboard payload. Read-only history retains these
safe check results. Unknown causes stay labelled unknown rather than being guessed.

### Helper release acceptance and provider search grants

The production helper's replay floor belongs in its private
`release-acceptance-v1` directory (0700, no extended ACL); its canonical anchor
remains 0600, single-linked and without an extended ACL. Provider accounts receive
only search grants on shared ancestors. The general release-acceptance store's
no-ACL policy, descriptor signatures, trust keys and companion binding are unchanged.

Legacy migration reads the existing anchor through a non-following, nonblocking
file descriptor and preserves its exact bytes in an immutable private receipt.
The highest legacy/private sequence remains authoritative; an equal sequence with
a different digest, changed or missing preserved history, malformed metadata,
foreign ownership, unknown or inherited rights must fail closed. Reads are bounded
and descriptor/namespace metadata is checked again after reading. Neither journal
state nor an uncertainty flag is rewritten.

Account authority comes only from protected helper deployment/worker metadata and
the exact reviewed selection correlated with the active parent journal. Generated
EP identities require the complete disabled OS account/group profile; Forge uses
its peer-attested operator and a fresh native account readback. A pending EP account
that does not exist contributes no UID. This preserves existing valid grants, while
an ACL naming an absent or unknown account remains rejected. No caller credential,
account choice or invented intent supplies migration authority.

Qualification includes actual temporary macOS ACLs, FIFO and oversized-file
rejection, malformed and linked anchors/journals, disappearing/changed history,
selection identity mismatches, pending EP with a valid Forge operator, and rejection
of an unknown search ACE. These are source tests, not a runtime recovery or an
installed E2E result. The existing failed VM operation remains unchanged until a
separately supported and authorized recovery or clean qualification route is ready.

## Customer wizard presentation (12 October 2026)

Use a vertical step column with native glyphs, one highlighted viewed step and
status checks derived from completed evidence. Do not present the steps as a
horizontal row of buttons or a step-selection menu. Provide a plain **Vorige**
action to view the previous completed screen and a return-to-current action;
viewing results must not repeat helper, provider or product actions. An install
or final readiness check is shown as complete only after all execution stages
pass. Presentation changes grant no additional installation authority.

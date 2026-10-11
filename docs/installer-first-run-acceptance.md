# First-run installer acceptance

The next public build must be qualified against these operator requirements on a clean Mac.

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
- The native source now admits the complete selected Codex group before one ceremony, bootstraps only through the user-approved same-host helper route, and independently verifies each target. Local tests and source review pass; this is not yet a published or live authentication qualification.

## Device code usability

- The visible one-time code remains selectable.
- Provide a clearly labelled **Kopieer code** action adjacent to the code, writing only that displayed code on an explicit user click.
- Retain the official verification-page link and explicit verification after user authentication.
- The clipboard action is present in source in both GUI authentication screens and the GUI product compiles. This is not yet a published-build or live GUI qualification claim.

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

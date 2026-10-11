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

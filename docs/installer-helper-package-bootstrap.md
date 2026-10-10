# Package helper bootstrap qualification

Status: local unsigned prototype only. Not a production helper installation,
not a supported replacement of a registered helper, and not a first-run PASS.

## Fixed payload

The candidate producer accepts the exact reviewed signed/notarized/stapled
installer app, checks its sealed provenance, strict arm64 archive structure,
Developer ID app/helper identities, stapling and Gatekeeper, then copies the
entire app into a private package workspace. It rechecks the copied app.

The payload uses these fixed machine paths:

- `/Library/Application Support/ForgePlatformInstallerHelper/ForgePlatformInstaller.app`
- `/Library/LaunchDaemons/com.autonomous-engineering-system.forge-platform-installer.helper.plist`

The daemon references the embedded helper by an absolute path and publishes
only the three existing fixed Mach services. The package is nonrelocatable,
strict on bundle identity, version checked, and uses root ownership. It has no
installation scripts and does not start or replace a job.

## Local publication boundary

The complete bounded package is synchronized in its private workspace before
exclusive same-filesystem hardlink publication. A prior destination or symlink
is never overwritten. Directory synchronization and inode checks are required
before a candidate receipt. Failure after publication retains unacknowledged
output; it never unlinks a shared pathname after an identity check.

Removable local attributes are cleared only on the new private payload copy.
macOS can retain protected `com.apple.provenance`; the receipt explicitly
reports this restricted metadata profile. Neither source app nor system
security settings are modified. Sealed-app, signature, stapler and Gatekeeper
checks must still pass after normalization. This is not a metadata-free public
package qualification.

Eight behavioral checks cover prior output/symlinks, linked/oversize/empty
source, source drift, synchronization failure, competing output replacement,
metadata isolation, payload links and fixed nonrelocatable payload structure.
An actual local candidate was built from public installer 0.4.9; its receipt
remains `UNSIGNED_CANDIDATE_ONLY` and `production_admitted=false`.

## Gates before installation

1. Bind a signed package and its exact digest to the reviewed installer release
   descriptor and sealed provenance; independently verify Developer ID Installer,
   notarization, stapling and package Gatekeeper admission.
2. Initiate normal macOS administrator authorization from the installer.
3. Independently check the installed root-owned app, daemon configuration,
   launchd job and running helper process identity. The current SM parent reader
   intentionally rejects this different backend; do not remove its checks.
4. Integrate initial activation and independent readiness. A script-free payload
   does not demonstrate immediate activation after package installation.
5. Prevent a second backend from occupying the same service namespace. Existing
   SM registrations require a separately qualified, supported transition.
6. Qualify subsequent updates, recovery and removal with preserved operation
   history. Package installation acknowledgment is not helper readiness.
7. Prove the route on a clean VM with no manual Login Items approval.

Apple's installed macOS SDK `SMAppService.h` distinguishes approval for
SMAppService LaunchDaemons from filesystem-protected legacy LaunchDaemons.
This motivates investigation of a package route; it is not live qualification.

Reference: https://developer.apple.com/documentation/servicemanagement/smappservice

## Historical authentication recovery is separate

The current effect journal intentionally preserves abnormal-exit uncertainty.
The CLI has no general authentication-effect reconciliation command. Current
helper-upgrade preparation closes admission but does not prove credential,
worker or system-job quiescence and grants no service transition.

A new installer release also changes the stable-plan release binding. Resuming
the historical operation therefore requires explicit, independently qualified
release migration as well as effect reconciliation. Neither the unsigned
package nor a matching version permits clearing uncertainty, rewriting an old
stable fingerprint, starting a new operation, or replacing the helper blindly.

## Signed package metadata and read-only verifier (local source)

The native and Python consumers now recognize an explicit
`forge-platform.installer-release/v2` descriptor. Every arm64 asset must carry
exact `helper_package` fields: the one fixed package name, tagged SHA-256,
positive bounded byte count and notarization reference. V1 remains strict and
rejects package fields. Both payloads stay under the existing signature threshold;
the native descriptor acceptance anchor still binds the complete descriptor bytes.

A local native artifact verifier checks a private physical package path,
same-owner 0700 parent and 0600 regular single-link file, no extended ACL,
exact descriptor size/digest, Developer ID Installer team, stapler and package
Gatekeeper. It rechecks descriptor/leaf and directory identity after inspection.
Output is bounded and never enters receipts or logs. Inspection deadlines are
confined to the verifier's own children.

This verifier returns read-only artifact evidence, not installation authority.
It is not assembled into a download/admin/registration/XPC path. Release
production and publication qualification still support V1 only; do not publish
V2 until exact package signing/notary/stapling and producer evidence are added.

Local qualification: 1,551 native tests, strict >80.2 per-file production Swift
coverage PASS, 39 Python consumer tests, independent scoped source review PASS.
A real unsigned package is rejected by the production platform checker.
This supplies no signed-package positive, clean-host helper or live GUI PASS.

## Installed-state observation (local source)

A separate native installed-state reader now checks the fixed root-owned shelf,
complete app tree and daemon before and after sealed-app inspection. It matches
the exact release version, bundle/team and full app CodeDirectory identity.
The daemon must expose only the three fixed boolean Mach services and one fixed
absolute helper program; extra environment/argument/configuration fields fail.

The fixed launchd job must be running from that program and daemon, with one
canonical positive PID and no ServiceManagement backend. Its actual process
must be root-owned, have the exact executable path and a stable PID/start time,
pass Developer ID Application requirements, and match independently read static
code signing. Dynamic validity is checked before and after signing-information
translation; Apple's SecCodeCopyStaticCode relationship alone is not a security
proof.

Six targeted source checks and the complete 1,557-test native suite passed.
Every tracked production Swift file passed the strict >80.2 coverage gate;
the installed reader measured 82.926829 percent. Independent source review passed.

This is not connected to registration, replacement, XPC or installation.
The source-positive tests use isolated filesystem and inspector seams; they
are not live installed-helper evidence. A real package bootstrap, normal
administrator authorization and clean-VM positive readback remain required.

## Protected transfer implementation (local source)

The chosen administrator bridge is a separate, narrowly scoped signed
SMJobBless bootstrap service. Apple's installed SDK confirms the required
mutual signing requirements, embedded launchd metadata and normal system
administrator authorization. SMJobBless is deprecated; qualification on the
supported macOS version remains mandatory. Opening a user-owned package in
Installer is insufficient: installed readback could detect substitution only
after that package has already performed privileged effects.

The new root importer implements the transfer portion only. Production requires
root and a protected `/private/var/root` parent. It opens the admitted user's
private package directory and exact package leaf without following links,
requires the expected owner, restrictive modes, no ACL, a regular single-link
file and exact bounded size, and copies from the held descriptor into a freshly
created root-private directory. Copies are bounded, synchronized and checked
for source drift. Exact descriptor digest, Developer ID Installer, stapling and
Gatekeeper are checked again on the protected copy. A failed import removes
only its newly created private staging; the source is preserved.

The UID must come from the authenticated connection and the release record must
be independently verified by the bootstrap service. Neither is a caller claim.
Those IPC and administrator admission steps are not yet assembled. The importer
performs no installation, activation or replacement and grants none of those
authorities. Its source tests do not prove a live signed bootstrap route.

Local transfer qualification: five targeted checks, independent scoped source
review PASS, complete native suite 1,562 tests PASS. Every tracked production
Swift file exceeds 80.2 percent; root importer coverage is 98.076923 percent.
These are source gates, not a live administrator or package-installation PASS.

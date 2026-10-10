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

## Normal administrator authorization (local source)

The new authorization module binds its production request to `Bundle.main`,
requires the exact trusted release version/team/bundle/CodeDirectory, and reads
mutual Developer ID requirements from statically validated app/tool signing
metadata. Both bootstrap and main helper namespaces must be absent, including
filesystem occupants and launchd jobs. Unknown probe errors fail closed.

A required cross-process installer mutation lease spans the checks, human
prompt, fresh checks and blessing. Only the fixed system bless-helper right is
requested with interactionAllowed/extendRights. No password or external
Authorization form is read or transported. Rights are destroyed on every path.
After successful administrator authorization, exact app/helper declarations
and both namespaces are checked again before the fixed SMJobBless submission.
A lease release failure cannot return success. Submission is not readiness.

Twelve targeted source tests cover mismatches, occupied namespaces, cancellation,
mutation during the prompt, the native right/flags/domain/label construction,
lease ownership and failures. A real unprivileged Authorization reference is
created/destroyed without requesting rights; namespace probes are read-only.
Complete native suite: 1,574 tests PASS. All tracked production Swift files
exceed 80.2 percent; this module measures 85.555556 percent. Scoped source review
PASS after fixing the missing post-prompt currency check.

The signed bootstrap executable/embedded metadata, authenticated IPC, root
release verification, correct runtime mutation-lock binding, root package
effect serialization and installed-bootstrap readback remain to be assembled.
No administrator prompt or SMJobBless installation has been invoked by these
checks. Neither CLI nor GUI has this route connected yet; no live first-run
PASS or helper replacement authority follows from the source result.

## Embedded bootstrap link inputs (local source)

`prepare_macos_installer_bootstrap_metadata.py` captures bounded, strict public
release trust/provenance resources, requires this product's fixed bundle/team/
repository and matching canonical policy digest, then emits three closed plists:
embedded tool Info, embedded launchd configuration, and the app's mutual signing
requirements. Exact public resource bytes are base64 encoded inside tool Info;
no paths, providers, credentials or authorization forms are embedded. The daemon
publishes only its fixed bootstrap Mach service. These inputs must be linked as
`__TEXT,__info_plist` and `__TEXT,__launchd_plist` before signing the standalone
tool; adding plists to the app afterwards is not an equivalent sealed boundary.

Private staging is checked by held FD/path identity, UID/mode and absence of
ACL. Files are exclusive, private and synchronized. Native exclusive directory
rename prevents replacement of an existing destination; parent synchronization,
final directory binding and every file identity are checked before acknowledgment.
Failure retains unacknowledged output and never deletes a shared destination.
The shared public resource reader uses O_NONBLOCK so a FIFO substituted before
open cannot hang the regular-file check.

Ten producer checks passed, including an actual Apple arm64 compile/link of a
harmless test executable and exact inspection of both embedded section bytes.
That executable is never executed or signed. The existing app packager's 26
checks passed; scoped source review PASS after fixing directory-publication
identity. Native production source is unchanged since its 1,574-test gate.

An actual input set from public 0.4.9 resources was retained locally with status
`UNSIGNED_LINK_INPUT_ONLY` and `production_admitted=false`. It is not a new
0.4.9 release, signed bootstrap executable, service or installer artifact.
Next assembly remains the standalone runtime, authenticated IPC and independent
root release verification, packaging/signing of the tool, and the admitted
installer/runtime integration. No live administrator or first-run PASS follows.

## Closed import service coordinator (local source)

The import coordinator now accepts only a bounded four-field request: schema,
physical package source, requested sequence and public package digest. Duplicate
or extra keys, caller UID/trust/command fields, noninteger sequence, wrong
package name, relative/control-character/empty/dot paths are rejected. Explicit
segment checks preserve valid macOS `/private/var` paths; Foundation's path
standardization is not filesystem admission. The root importer still performs
all no-follow owner/mode/ACL/size checks.

A required root mutation lease and actor busy guard span the independent signed
release-feed lookup. The returned record must match every sealed anchor identity
and the requested package. Peer and namespace observations are repeated before
copy and acknowledgment. One retained copy stays with one admitted user; retries
reverify that protected copy and never create an additional copy. The protected
pathname never enters the reply, which says `PACKAGE_IMPORTED_ONLY` and
`installation_ready=false`. Lease-release failures never acknowledge success.

Six focused source checks passed, including real isolated private copying,
protected-copy reverification, overlapping requests while the independent feed
awaits, denied/busy/failed leases, hostile wire values and cross-user retry.
Full native suite 1,580 tests PASS; all tracked production Swift files exceed
80.2 percent and this coordinator measures 100 percent. Final scoped review PASS.
Source seams use synthetic public release records and platform inspection only
for isolated tests; they are not signed/live installation evidence.

The runtime must still load its anchor from its own signed embedded metadata,
verify the XPC connection and obtain the UID from it, connect the actual root
mutation lock and independent feed, and expose only the closed interface.
No executable/listener or package installation is assembled by this coordinator.
Historical operation reconciliation, helper transition, activation and readiness
remain separate qualification gates.

## Connection-bound peer and closed XPC interface (local source)

The peer reader observes the connection PID/UID, actual GUI or CLI executable
inside `Contents/MacOS`, dynamic/static Developer ID signing, executable owner,
PID/start time, and the enclosing sealed app's exact release/team/CodeDirectory.
The published CLI uses the same installer signing identifier; its enclosing app
must still match the selected release. Process path and identity are repeated
after the asynchronous app inspection. The reusable process inspector permits
only the three closed installer/mainhelper/bootstrap identifiers; its existing
mainhelper default is unchanged.

One service object is exported per connection. Foundation installs the fixed
Developer ID requirement before delegating admission; UID/PID are captured from
connection metadata. Only the bounded import selector is exported. The peer is
checked before and after the coordinator await; drift blocks the reply. No UID,
trust policy, protected pathname or execution selector is supplied on the wire.

Five focused source checks and complete native suite 1,585 tests passed. Every
tracked production Swift file exceeds 80.2 percent: peer reader 80.769231 percent,
XPC interface 94.915254 percent. Scoped review PASS. Anonymous listener and
injected inspector checks are source-only interface evidence. The named
production constructor was constructed and invalidated without activation;
no registered helper, signing policy or host lifecycle was changed.

This still lacks the standalone executable/root factory: actual root-process
and embedded signed metadata verification, root durable lock/feed assembly and
admitted production activation. Neither installation nor a live trusted
connection to an installed bootstrap helper is proven by these source gates.

## Standalone root entry and production assembly (local source)

A separate `forge-platform-installer-bootstrap` executable target now has no
configuration switches. Its entry prepares the qualified root runtime, retains
it for process lifetime and then activates the import listener. Invalid arguments
exit 64; missing authority/metadata exits 78. A real unqualified compiled child
was launched unprivileged and refused startup; this is negative admission proof.

The production metadata reader accepts only the fixed installed standalone
binary under `/Library/PrivilegedHelperTools`, root EUID/ownership, restrictive
no-follow filesystem/ACL/link/architecture evidence, and actual root process
identity matching statically validated Developer ID code before and after reading
its signed Info. Seven closed fields bind canonical bounded embedded public trust
and provenance, fixed bundle/team/repository, mutual clients and matching versions.

Production preparation holds the root-private cross-process lock across the
independent GitHub signed-feed verification and namespace recheck. Durable
acceptance is outside product stores. Every provenance field and the package-bearing
release must match the helper's own policy. The listener exports the existing
connection-bound coordinator with root importer, package reverifier and actual
administrator readback. The mainhelper namespace and fixed package shelf must be
absent; this import-only assembly grants no existing-helper transition.

Five focused checks and complete native suite 1,590 tests passed. All tracked
production Swift files, including the new executable target, exceed 80.2 percent:
entry 95.652174, metadata 95.402299, runtime 84.375000. Scoped rootassembly source
review PASS. Positive root/factory fixtures are source-only, not installed evidence.
The production constructor/listener was never activated on a host.

An actual standalone Swift link with the retained public 0.4.9 metadata inputs
preserved both embedded sections byte-for-byte. The local receipt explicitly
says `LOCAL_LINK_PROTOTYPE_NOT_DEVELOPER_ID`, `production_admitted=false`, not
installed and not executed as root. Old 0.4.9 input bytes do not authorize the new
source as a 0.4.9 release; protected publication must regenerate current provenance.

Next required assembly: app bootstrap packaging/embedded metadata/signing and
normal administrator handoff/readback, signed package producer/public descriptor
V2, actual package effects and initial mainhelper activation, plus frontend and
mainhelper package-backend integration. Current public V1/0.4.9 cannot qualify
this root runtime's package-bearing release gate. No live CLI/GUI first-run,
package installation, helper readiness or protected-history recovery is claimed.

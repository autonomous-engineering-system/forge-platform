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


## Preactivation installed-file evidence (2026-10-11, source only)

The independent installed-helper reader now exposes a separate files-only
readback. It validates the actual protected app tree, executable, sealed app
identity and exact daemon configuration before activation. It rechecks the tree
and daemon after asynchronous seal inspection. Its returned evidence carries
release sequence and app CodeDirectory only; it cannot claim a registered job,
process or installation readiness. The existing full running-helper reader is
unchanged and remains required after activation.

Nine targeted native reader checks passed, including files present with no job
or process, missing/foreign signing evidence, mutation during inspection and the
existing FIFO/namespace/running-reader checks. Changed-reader coverage is
85.416667 percent under the unchanged strict 80.2 gate. Scoped read-only review
passed. The future root coordinator must hold its mutation lease across these
checks and require fresh full running readback; these source checks did not
install a package or activate a service.


## Serialized first-install coordinator (2026-10-11, source only)

The source-internal first-install coordinator now holds the existing host-wide
mutation lease across protected package verification, durable intent and attempt,
installer exit observation, independent file proof, initial activation and fresh
running-helper readback. Imported digest, byte count and sequence must match the
selected release and admitted client UID. Admission is repeated across async
boundaries. Unknown launch/exit retains attempted history; nonzero installer
exit prevents activation. Neither an installer exit nor a completed ledger can
substitute for fresh running-helper evidence. Lease-release failure cannot return
success. Any existing attempt refuses a new install; no recovery/replacement or
historical uncertainty retirement is introduced.

Thirteen targeted reader/coordinator checks passed, including failure boundaries,
real private append-only history, actual kernel lease contention, suspended-action
overlap and admission revocation before activation. Four coordinator checks were
then scoped to assert the durable attempted record already exists at both action
entry boundaries. Source action seams did not execute installer or launchctl.
Coordinator file coverage is 100 percent under the unchanged strict 80.2 gate;
read-only source review found no concrete findings.

Production action assembly, audited XPC install admission and frontend/backend
selection remain open. Existing root runtime still serves import only. This
coordinator has not performed a root installation, qualified a signed package
or established installed/readiness or public CLI/GUI PASS.


## Fixed production action assembly (2026-10-11, source only)

The new production assembly binds root selfmetadata and administrator admission,
protected package re-verification and independent installed readers to fixed OS
commands: installer with the typed protected package and target /; initial
launchctl bootstrap with the fixed daemon and kickstart with the fixed system
label. No shell, caller-supplied tool/argument/environment, -k, bootout or helper
kill is used. After file installation, activation requires absent legacy SM helper
and the exact absent-job observation; preinstall plist absence is not reused.

Child input/output is discarded, environment fixed and observation bounded. A
timeout leaves the child outcome unconfirmed and attempted journal unchanged;
it does not kill the child, retry, activate or claim ready. Historical recovery
of this outcome remains a separate gate.

Sixteen targeted native reader/coordinator/assembly checks passed. Production
commands were observed through source seams only; the actual child runner was
checked with harmless true/false/missing-tool and a short naturally ending sleep.
No installer or launchctl effect was executed. Changed new file coverage is
83.132530 percent under the strict 80.2 gate; read-only review found no findings.
Runtime/XPC installation admission, same-connection revocation checks and frontend
selection remain open; no installed or public CLI/GUI PASS is claimed.


## Explicit authenticated installation/runtime integration (2026-10-11, source only)

The bootstrap now exports separate import and installation methods. The import
method keeps its PACKAGE_IMPORTED_ONLY receipt and cannot silently install. The
explicit installation method reuses strict import-request decoding, then obtains
a fresh independent signed feed record bound to the sealed app anchor and passes
the protected typed copy to the first-install coordinator. That coordinator holds
the root mutation lease and durable package history across all effect boundaries.
Runtime assembly now supplies fixed production actions and the private journal.
No peer UID, admission callback, root package path or command can be supplied by
the request. Actor busy state is rechecked after asynchronous initial admission.

Every coordinator admission also requires the original authenticated connection's
current PID/start/CD evidence. Per-connection interruption and invalidation hooks
stickily revoke authority; wrapped peer inspection checks this state before and
after its asynchronous work. A client process that survives a closed connection
cannot restore admission. Source review found this missing lifetime boundary; the
fix and regression tests passed scoped re-review.

The explicit helper-install receipt can report HELPER_RUNNING_VERIFIED only after
independent running readback and durable recording. Its installation_ready field
applies to this helper-install protocol, not EP/Forge/product readiness or usable
frontend/backend qualification. The frontend must independently read installed
state and qualify the actual helper protocol before continuing product work.

Thirty-six focused direct-dependency tests passed, covering fresh-feed change,
missing running evidence, immutable recorded attempts, authenticated callback
revocation after installer exit, sticky revocation with unchanged peer identity,
anonymous listener lifetime hooks and runtime assembly without activation.
Changed production file coverage ranges from 83.132530 to 100 percent, all strictly
above 80.2. An initial Swift closure-inference build failure was fixed with an
explicit typed handler. An initial filter omitted the actual BootstrapRootTests
class, producing zero runtime coverage; the corrected dependency group passed.

These are source/isolated interface tests. No signed root installer package was
installed, bootstrap registered, helper started/stopped or historical product/auth
journal changed. Frontend/backend package-route selection, supported historical
recovery, actual package publication/qualification and public CLI/GUI proof remain
open. Current published 0.4.9 V1 cannot supply this package-bearing route.


## Frontend bootstrap client and independent readback (2026-10-11, source only)

A dedicated native client now targets only the fixed privileged bootstrap Mach
service with its closed Developer ID requirement. It sends the explicit install
method, with the existing strict bounded package-import request. The connection
is single-use: malformed local requests fail before admission, and an attempted
request is never reconnected or retried. Error/interruption/invalidation/timeout
resolve the reply once; timeout closes the connection, so root-side sticky peer
revocation prevents a subsequent effect phase. Root effect history is retained.

The client accepts only the closed helper-install receipt schema, exact selected
release sequence/CodeDirectory, actual boolean readiness and positive Int32 PID.
Extra/duplicate fields, import-only claims, invalid numeric values and oversized
bytes are rejected. Even a valid server claim cannot return success without an
independent full installed reader producing exactly the same sequence/CD/PID.
No credential or protected root package path enters this receipt.

Twenty-two focused checks passed, including hostile claims, missing/mismatched
independent readback and actual anonymous local XPC explicit-method/one-request/
missing-reply timeout behavior. Anonymous source qualification installs no trust
policy and is not a released backend option or live signing/installation proof.
New production file coverage is 96.330275 percent, strictly above 80.2. Scoped
read-only review passed. No package installation, authorization prompt, bootstrap
registration or product/helper lifecycle action occurred.

This client is not yet selected by the wizard or CLI. Frontend authorization/
verified package staging, package versus historical SM backend admission and
supported historical recovery remain open; existing published V1 is unchanged.
The GUI/CLI must independently qualify the main helper protocol after installed
readback before product work, and public CLI/GUI MVP proof remains open.


## Package-backed main helper admission (2026-10-11, source only)

The three existing main helper transports (post-tool observation, product
operations and released route) now accept an explicit independently verified
package-bearing release alongside the sealed expected parent version. Selecting
that backend requires a fresh full installed readback before every RPC/resume:
exact expected version, sequence, app CodeDirectory and positive process ID. A
missing package, unsafe/missing files, foreign evidence or changed process closes
admission. It never falls back to a matching historical ServiceManagement version.
Legacy synchronous admission cannot grant the package route; existing legacy
ServiceManagement selection remains independently version-checked. Actor resume
state changes synchronously after the asynchronous admission, preventing duplicate
resume while requests interleave. Existing signing requirements remain unchanged.

New checks prove fresh file mutation refusal, no ServiceManagement fallback, V1/
missing version/foreign sequence or digest/invalid process rejection and blocked
main-helper RPC before anonymous connection activation. Scoped read-only review
passed. Initial 212 direct regression checks passed but did not cover enough of
two large existing XPC files; only tests actually referencing those transports/
services were added to the dependency group. Final 343 focused checks passed in
approximately ten seconds; all five changed production files exceed strict 80.2
coverage (85.850556 to 94.674556 percent for existing files; new policy93.75).
No full unrelated installer matrix or live product/helper action was performed.

Frontend package selection/staging and normal administrator authorization are
still not wired into wizard/CLI production composition. The verified-release
argument is a source API, not an alternate CLI/backend/trust override. These
source tests do not qualify an actual package-backed helper protocol, historical
recovery or public CLI/GUI installation. Published V1 and original journals remain
unchanged; end-to-end first-run/install proof is still required.


## Production frontend preparation (2026-10-11, source qualification)

The trusted runtime now binds helper admission to the exact verified current
release. The wizard prepares installation help after the user begins installation;
the explicit CLI helper-register route uses the same preparation. Read-only
status does not prompt, and non-interactive registration permits existing
independently verified installation only. V1 retains its original registration
route; a selected V2 never falls back to the historical ServiceManagement helper.

The download uses the verified repository/tag and fixed companion asset name,
with exact bounded byte count. A fresh private no-follow stage is fsynced and
verified for hash, Developer ID Installer signature, notarization, staple and
Gatekeeper before ordinary administrator authorization. Existing failed stages
remain evidence and do not become a cache prerequisite. The preparation actor
serializes attempts and latches submission before authorization; an unresolved
attempt permits subsequent independent readback, not another installation.

Currency admission is checked around asynchronous inspection, administrator
consent, bootstrap registration and immediately before package submission.
Rechecking currency invalidates the preparation even when the physical app
identity remains unchanged. Each main-helper RPC independently selects the exact
current V1 or V2 backend and repeats installed admission before connection use.
Two review findings concerning stale currency during staging/inspection were
fixed and covered by paused asynchronous regressions. Final scoped review passed.

The completed cohesive frontend change passed 44 GUI, 1541 Core and 45 CLI
native tests. All sixteen changed production files passed unchanged strict
coverage greater than 80.2 percent (82.475224 to 100 percent). No real package
download, administrator prompt, helper registration, installation, signing,
notarization, publication, product lifecycle or credential action occurred in
these tests. Historical SM-helper migration and public clean CLI/GUI evidence
remain open; the published V1 release and historical journals are unchanged.


## Official candidate route and complete review corrections (2026-10-11)

The protected unsigned-candidate workflow now builds the bootstrap after its
exact release provenance check, using public metadata sections and absolute
link input paths. It passes that executable into app packaging and requires its
fixed embedded path. This closes a concrete gap where the alternative offline
build supported bootstrap linking but the regular release candidate omitted it.
Twenty owning workflow/runner/publisher checks passed; this is source assurance,
not a runner build or public V2 package.

Complete candidate review also found that the bounded Codex cache bootstrap
opened its source before regular-file admission without nonblocking mode.
O_NONBLOCK now rejects an actual no-writer FIFO promptly before cache staging
or publication. Ten owning checks passed, including the new real FIFO negative;
changed-file coverage is 98.239436 percent. No real cache was read or transferred.
The required Python/Foundation/workflow validation passed 1522 checks across
69 suites and its unchanged strict coverage gate. Complete exact-head independent
review, protected delivery, actual signing/publication and live acceptance remain
separate required gates. Original authentication uncertainty is unchanged.

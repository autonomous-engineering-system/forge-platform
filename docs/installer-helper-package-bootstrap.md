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

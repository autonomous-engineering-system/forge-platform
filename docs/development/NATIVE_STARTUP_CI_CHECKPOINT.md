# Native installer startup CI checkpoint

Assignment: `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`; existing PR #75.

## Readback before this follow-up

Commit `9abc8529595e694528542e922d05fbeb5cd6ff84` qualified 30 Python CI-gate
regressions and 255 Swift tests on GitHub-hosted Apple Silicon macOS 26.6.2,
Xcode 26.6 build 17F113, SDK 26.5. Native workflow `35863767602`, job
`107190104171`, failed only at the newly strict coverage gate: the previously
omitted `InstallerApplicationStartup.swift` had 0/269 executable lines covered.
The other six enforced Swift files exceeded 80.2%. Foundation `35863768187`,
CodeQL `35863767669`, versioning `35863767709`, and TDE `35863767523` passed.
The full native job is not represented as PASS at that revision.

## Follow-up implementation

Ten additional native tests exercise `InstallerApplicationStartupModel` through
the real `ReleasedInstallerStartupBoundary` and render the actual SwiftUI root
in checking, required-update, updating, ready, relaunching and blocked states.
The tests cover current release, patch/minor confirmation, close without
handoff, duplicate startup/confirmation, failed currency and handoff, missing
build identity at either read, and late results after the model is deallocated.
A controlled asynchronous runtime permits an assertion that old-process
termination happens only after the handoff result, not on consent or download.

The only production refactor is an internal injected version-reader closure.
Its default remains `InstallerBuild.currentVersion` and the real sealed startup
boundary remains mandatory. There is no environment/CLI override, development
version fallback, direct state setter, alternate production trust path or
coverage exclusion. Resource loaders/runtime effects in tests are explicitly
fixtures; process termination is a test-owned counter, never NSApplication exit.

Syntax was checked locally with the Swift frontend. Type checking, execution
and final >80.2% coverage require the subsequent native hosted run and are not
claimed by this source document in advance. This file is an implementation-time
checkpoint; subsequent measured evidence belongs in PR #75 and forge#141.

This increment does not configure or activate the Mac mini, alter installer
release identity, sign/notarize/publish an installer, qualify provider login or
perform a reboot. Physical runner access and independent protected dispatch /
Environment verification remain external prerequisites. Forge, EP, Workspace,
production deployments, Mission-3, CENTRAL reset and T0 remain untouched.

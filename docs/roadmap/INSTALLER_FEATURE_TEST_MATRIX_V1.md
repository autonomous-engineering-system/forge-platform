# LANE_1 installer feature and test matrix V1

**Increment:** `LANE_1_INSTALLER_FEATURE_TEST_MATRIX_V1_20261012`
**Owner:** Forge Platform / existing LANE_1 writer. **Version effect:** NO_BUMP.
**Recorded:** 12 October 2026; evidence cutoff 11 October 2026.
**Status:** public 0.4.10 artifact qualified; installed public CLI/GUI E2E open.

[Canonical case inventory](installer-feature-test-matrix-v1.json). This is a documentary acceptance increment, not an execution permission, test runner, new release, product upgrade or completion receipt.

## Later source qualification

The [automatic composition-review transition correction](../installer-automatic-review-transition-qualification.md) records the 0.4.28 GUI stall and focused unsigned qualification on 17 October 2026. It does not change the historical cutoff, case results or live-acceptance status of this matrix snapshot.

## Current baseline and evidence

Installer **0.4.10** is published as [five assets](https://github.com/autonomous-engineering-system/forge-platform/releases/tag/forge-platform-installer-v0.4.10). Frozen binary source `5fc612c3926b26b600fae9358bb53e8c597d4ed7` and reviewed producer source `d4b71492c24e000023d1602208e193a5c8bc6e78` are distinct. The producer-only XAR correction did not rebuild/resign the app or package. Exact hashes are in the canonical inventory. Selected installation/pairing product baseline: **Forge 2.8.1 + EP 2.3.113**; this is not a claim these are the latest product releases.

Historical debugCLI installation/pairing and product-update qualification remains a separate private evidence class. No private receipt or host outcome is published by this increment, and that evidence cannot qualify public0.4.10 live cases. No internal host addresses, account names, device codes, credentials or private evidence paths are published here. All applicable public0.4.10 cases currently record **NOT_RUN**, not PASS. This is the last recorded evidence snapshot, not a fresh physical host observation.

## Scope and applicability

- Forge Server and EP Server only. Workspace roles and EP Project Agents remain in the broader architecture roadmap; no LANE_1 scope expansion.
- CLI and GUI have separate concrete case IDs. Same-host and separate-host routes are explicitly distinguished.
- Install one component, both together, or add the second later in either order. Pair only after both selected components exist; no project registration is an installation prerequisite.
- Use the actual selected Mac user; never hardcode a personal operator. EP prepares its admitted instance-specific service account.
- One human Codex ceremony for selected same-installation targets, with independent per-target verification. EP GitHub is separate; Forge has no GitHub provider. Cross-host credential transfer is not implied.
- Target support is distinct from UI presence, parser presence, owning product admission, source tests, artifact proof and installed live PASS. A required unsupported case remains a gap, never NOT_APPLICABLE.

## Complete route inventory

Every variant below has an explicit CLI and GUI case in JSON. GUI-only visual cases have explained CLI NOT_APPLICABLE entries. The JSON records preconditions, procedures, expected outcomes, source references, blockers, checks and separate result evidence.

| Family | Required variants | Current implementation/admission boundary |
| --- | --- | --- |
| `INSTALL` — Clean installation | FORGE, EP, BOTH | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `ADD` — Add the second component | EP_TO_FORGE, FORGE_TO_EP | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `REMOTE` — Pair components on different Macs | FORGE_TO_REMOTE_EP, EP_TO_REMOTE_FORGE | `REQUIRES_REMOTE_ROUTE_QUALIFICATION` |
| `UPGRADE` — Product upgrade | FORGE_ONLY, EP_ONLY, FORGE_IN_PAIR, EP_IN_PAIR, BOTH | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `UPGRADE_NOOP` — Already-current product | FORGE, EP, BOTH | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `REPAIR` — Repair current installation | FORGE_RUNTIME, EP_RUNTIME, FORGE_SERVICE, EP_SERVICE, FORGE_RIGHTS, EP_RIGHTS, PAIRED_DEPLOYMENT | `REQUIRES_INSTALLATION_SCOPE_QUALIFICATION` |
| `REMOVE_KEEP` — Uninstall software while retaining data | FORGE_ONLY, EP_ONLY, FORGE_IN_PAIR, EP_IN_PAIR, BOTH | `BLOCKED_CURRENT_PRODUCT_CONTRACT` |
| `REMOVE_PURGE` — Uninstall software and selected instance data | FORGE_ONLY, EP_ONLY, FORGE_IN_PAIR, EP_IN_PAIR, BOTH | `BLOCKED_CURRENT_PRODUCT_CONTRACT` |
| `RESTORE` — Restore preserved installation | FORGE, EP, BOTH | `BLOCKED_CURRENT_PRODUCT_CONTRACT` |
| `REINSTALL` — Clean install after purge | FORGE, EP, BOTH | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `PROVIDER_AUTH` — Initial provider authentication | CODEX_FORGE, CODEX_EP, CODEX_BOTH, GITHUB_EP | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `PROVIDER_REAUTH` — Expired/revoked provider reauthorization | CODEX_FORGE, CODEX_EP, CODEX_BOTH, GITHUB_EP | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `PROVIDER_REPAIR` — Provider status/configuration repair | CODEX_FORGE, CODEX_EP, CODEX_BOTH, GITHUB_EP | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `PROVIDER_TOOL_UPGRADE` — Upgrade provider tooling | CODEX_FORGE, CODEX_EP, CODEX_BOTH, GITHUB_EP | `DEDICATED_ROUTE_NOT_CONFIRMED` |
| `PROVIDER_STATE` — Provider partial-state and cancellation handling | ALL_VERIFIED, ONE_CODEX_TARGET_MISSING, ALL_TARGETS_MISSING, EXPIRED_TARGET, USER_CANCELLED, DEVICE_CODE_TIMEOUT, UNSUPPORTED_PROVIDER | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `PAIR_CONNECT` — Connect installed peers | LOCAL, REMOTE | `REQUIRES_SCOPE_SPECIFIC_QUALIFICATION` |
| `PAIR_DETACH` — Disconnect installed peers | LOCAL, REMOTE | `REQUIRES_INSTALLATION_SCOPE_QUALIFICATION` |
| `PAIR_REPAIR` — Repair/reconnect installed peers | LOCAL, REMOTE | `REQUIRES_INSTALLATION_SCOPE_QUALIFICATION` |
| `SELF_UPDATE` — Update installer | OLDER_SUPPORTED, ALREADY_CURRENT, INTERRUPTED_HANDOFF | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `HELPER` — Helper onboarding and lifecycle | CLEAN, REPEAT, LEGACY_NAMESPACE, UPDATE, REMOVE | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `BOOT` — Headless service continuity | FORGE, EP, BOTH | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `RECOVERY` — Interrupt and resume | INSTALL, ADD, UPGRADE_ONE, UPGRADE_BOTH, PROVIDER, PAIRING, LIFECYCLE, SELF_UPDATE | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `ISOLATION` — Target and concurrency isolation | SIBLING_FORGE, SIBLING_EP, OTHER_DEPLOYMENT, SHARED_PROVIDER, OTHER_OS_USER, CONCURRENT_OPERATIONS | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `USER` — Operator privilege and ownership | ALTERNATE_ADMIN, NON_ADMIN, ROOT_CALLER | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `CACHE` — Cache and managed-tool resilience | ABSENT, CORRUPT, STALE, OFFLINE, LOW_SPACE | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `NEGATIVE` — Fail-closed evidence and targeting | WRONG_TARGET, STALE_REVIEW, CHANGED_REQUEST, TAMPER, SYMLINK_OR_FIFO, ROLLBACK, UNTRUSTED_SIGNATURE, MISSING_COMPANION, FORGE_GITHUB | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |
| `GUI` — GUI usability and honest progress | DEVICE_CODE, NAVIGATION, BLOCKED_PROGRESS, CONFIRM_PURGE, LOCALE_THEME_SCALE | `SOURCE_PRESENT_REQUIRES_LIVE_QUALIFICATION` |

**Inventory:** 27 families, 228 explicit interface cases; 223 applicable and 5 explained NOT_APPLICABLE.

## Concrete source gaps

1. Current lifecycle admission lists historical Forge2.7.37/38/39 and EP2.3.106. Installation/pairing admission of Forge2.8.1/EP2.3.113 does not admit uninstall, preserve, purge, restore or repair. Consume separately qualified owning contracts before changing this matrix.
2. The current CLI restore execution accepts EP only; Forge restore and a complete two-component restore remain required gaps. Restore planning is not restore execution.
3. Legacy project-scoped detach/revocation/repair cannot authorize installation-scoped pairing teardown. Producer release availability, exact installer integration and actual isolated proof are separate gates.
4. Dedicated provider-tool upgrade is not confirmed in the CLI. Login, reauthorization, token refresh, provider repair and executable/tool upgrade are separate operations. Unsupported provider types must be rejected honestly.
5. Historical debug product updates prove only their exact tested transitions; generic/public updates need their own receipts and preserve/recovery checks.
6. Package artifacts are real qualified artifacts; clean first-start administrator authorization, installed helper identity/IPC and no-manual-Login-Items UX remain live acceptance cases.
7. Remote pairing, cold boot without login, multi-instance isolation, safe historical reconciliation and self-update/session handoff need scope-specific actual evidence.

Source references in JSON bind these observations to reviewed producer baseline d4b7149. Documentation does not broaden production allowlists or add an absent command.

## Observed command surface versus required features

The source CLI exposes `deployment plan/apply` with `forge|ep|forge-ep`,
legacy Forge removal/plan, pairing repair **plan**, lifecycle plan/preserve/purge,
EP-only lifecycle **restore execution**, and installer self-update check/apply.
The canonical JSON lists the observed surfaces and unresolved required ones.
No generic `upgrade providers`, `restore Forge`, or installation-scope detach
command is invented by this document. A parser entry is not execution admission.
Inspect the exact public binary/owning contract before an authorized test;
never use historical debug commands as if they were public CLI routes.

## Cross-cutting acceptance rules

Apply these checks at each meaningful mutation phase, not only once at the end:

- Fresh physical read-only preflight: target/volume identity, journal, credential-free provider status, helper, processes, services/ports, paths and inventory.
- Review exact deployment/components/instances, owning artifacts, request/review fingerprint and deterministic original operation IDs. Negative target/stale/tamper/link/FIFO/replay cases must fail before effects.
- Compare before/after selected and nonselected state. Updates retain data/config; preserve keeps same identity/data but does not imply verified authentication; purge requires fresh exact-target confirmation and terminal absence/tombstone; reinstall cannot resurrect old state.
- Capture product-owned terminal receipts then independent current readback: actual paths, services, process identity, ports, per-target provider state, binding and readiness. A planned state, port alone, UI success or POST acknowledgement is insufficient.
- Interrupt/relaunch/reboot/lost-response tests require separately authorized fault injection. Resume the same request/operation without duplicate effects. Unknown/uncertain records remain intact until supported reconciliation.
- Confirm GUI/CLI parity for selected target, reviewed plan, helper request and terminal semantics. GUI screenshots/clipboard require actual published GUI; no secret values in screenshots, reports or journals.
- Never bypass provider consent, signed-helper trust, product lifecycle ownership, OS permissions, history, explicit purge review or resource budgets.

## Test execution and result recording

1. Select a concrete case ID from JSON and verify all applicable owning/source/host prerequisites. A documentation check does not grant runtime authority.
2. Capture a before-state and approved plan, including exact version/source/hash bindings. Reconfirm operator, host identity and selected roots before every resume.
3. Execute the real public binary only under the already applicable user authorization; the current handoff requests an unopened GUI for the owner’s test. Do not auto-start it.
4. Collect the receipt fields listed in JSON and independently observe actual state. Keep credential material and internal host information in the existing bounded private evidence route.
5. Record NOT_RUN, BLOCKED, FAIL or LIVE_PASS per case/interface. LIVE_PASS requires case-bound public runtime receipt/readback, never source/debug/artifact evidence substitution. Record a reason and retained evidence for any failure/block.
6. Publish only specifically allowed compact non-secret receipts. A full public test report must not silently disclose private operational status.

## Completion and historical reconciliation

The full matrix closes only after all applicable required cases have actual qualifying evidence; unresolved implementation/admission gaps count as open work. MVP closure separately requires real public CLI and GUI evidence plus the authorized compact #141 receipt. The quiet heartbeat is retained until accepted completion. No historical journal/uncertainty is deleted by this increment.

The existing [IUR roadmap](INSTALLER_UX_AND_RELEASE_QUALIFICATION_V1.md) and [IUR DAG](installer-ux-release-v1.json) retain their historical lifecycle pins, node IDs and broader Workspace scope. Their dated baseline is not a current binary feature inventory. This document/JSON is the current LANE_1 overlay; [first-run acceptance](../installer-first-run-acceptance.md), [managed installer](../architecture/MANAGED_INSTALLER_V1.md) and [universal contract](../architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md) link to it.

## Verification boundary

The documentary integrity tests check complete family/variant/interface coverage, resolvable links/source references, preserved historical DAG, explicit applicability, honest status/evidence separation and no execution permission. They do not install products or qualify any runtime case. Existing production coverage/security/protected delivery gates remain unchanged.

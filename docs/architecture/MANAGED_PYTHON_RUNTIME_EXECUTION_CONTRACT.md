# Managed Python runtime execution contract

**Status:** source-level executor kernel, native immutable session projection,
and credential-free native HTTPS asset transport implemented. The native
projection recomputes the complete runtime identity, binds it to the signed
outer-catalog approval, and retains one exact venv identity per selected
component. The transport derives each of the four bounded downloads only from
that admitted identity, denies redirects and verifies the exact SHA-256 before
returning bytes. No production runtime artifact, native archive inspector,
privileged helper, released mutation wiring, or live machine installation is
approved by this increment.

This contract is subordinate to the exact managed-Python identity in the
[Universal macOS Installer contract](UNIVERSAL_MACOS_INSTALLER_CONTRACT.md).
The signed catalog and admitted composition select one immutable runtime before
execution begins. The executor cannot select a Python version or installation
location itself.

## Frozen execution input

One operation binds:

- a lowercase operation identity;
- the complete catalog-approved `forge-platform.managed-python-runtime/v1`
  identity and its recomputed SHA-256;
- the planner action (`INSTALL`, `UPGRADE`, or `NO_CHANGE`);
- the trusted pre-operation installer-owned runtime readback;
- the exact previous runtime identity for an upgrade; and
- one unique opaque venv identity for every selected product component.

Retrying the operation ID with a changed artifact, provenance locator, digest,
ABI/tag, policy revision, action, prior-runtime identity, component, or venv
identity fails closed. The request and durable record contain no caller-chosen
runtime path, interpreter path, command, environment, or credential.

## Exact acquisition and verification

The executor captures four independently digest-pinned HTTPS inputs into its
operation-owned staging area:

1. runtime archive;
2. upstream CPython source;
3. source-provenance evidence; and
4. build-provenance evidence.

The transport receives the exact signed locator and an executor-chosen file.
Redirected final URLs, changed bytes, digest/size disagreement, symlinks,
non-regular files, or post-download modification are rejected. Every resume
re-hashes the captured files before using an earlier journal phase.

The native HTTPS transport implements the read-only network half of this
boundary. Its caller supplies only the already admitted runtime identity and a
closed asset-kind value. It uses an ephemeral credential-free session, permits
no redirect or final-URL drift, applies distinct runtime/source/provenance byte
limits while streaming, rejects empty responses, and validates the tagged
SHA-256 before returning identity-bound bytes. It does not choose a locator,
write a staging file, inspect or extract an archive, persist a receipt, or
authorize mutation.

An independently injected archive inspector must bind the captured inputs to
the complete runtime identity and prove:

- the standard managed-runtime archive layout;
- the fixed archive-relative interpreter `bin/python3`;
- exactly one executable architecture, `arm64`;
- the exact macOS deployment floor;
- CPython version, standard-GIL build, Python/ABI/platform tags and policy
  revision; and
- the exact source, source-provenance and build-provenance digests.

The executor admits no `x86_64`, universal/fat, macOS-25, PATH, system-Python,
Homebrew-Python, or network-latest fallback.

## Immutable slots and product venvs

The runtime slot identity is derived only as
`sha256-<approved-runtime-identity-hex>`. The injected privileged mutation
adapter may install only that exact verified archive into the installer-owned
managed-Python root. Its readback must repeat the runtime identity, archive
digest, fixed interpreter-relative path, thin arm64 architecture and macOS
floor.

Each selected product receives a separate venv bound to that runtime slot.
Component and venv identities come from the admitted composition, but the
adapter—not the UI or manifest—maps those opaque identities to fixed paths.
No two components may share a venv identity.

Activation requires a fresh installer-owned runtime readback. During an
upgrade, the exact prior runtime must remain present as the frozen rollback
identity. Neither successful activation nor terminal receipt permits deleting
that runtime; retention cleanup is a later separately journaled decision.

## Crash, reboot and rollback

The executor persists mode-0600 JSON in a mode-0700 installer-owned operation
directory and serializes host-wide managed-Python mutation with a non-blocking
lock. Its monotonic phases are:

```text
PREPARED → ACQUIRED → VERIFIED → RUNTIME_READY
         → VENVS_READY → ACTIVE → COMPLETE
                                   └→ ROLLED_BACK (upgrade only)
```

After interruption, the same immutable request reloads the record, re-hashes
captured bytes, validates prior receipts and asks the mutation adapter for
readback before repeating an install, venv or activation call. The adapter
contract requires those calls to be idempotent for the exact operation.

Rollback is available only for an upgrade with a frozen prior runtime. It
restores that exact slot, retains the failed target for evidence/recovery, and
requires a fresh readback that proves both facts. An install with no prior
runtime cannot manufacture rollback evidence. A rolled-back operation cannot
silently reactivate its failed target; a new admitted operation is required.

## Receipt boundary

A terminal receipt correlates the request fingerprint, runtime/slot, retained
rollback identity, all four acquisition receipts, archive inspection,
runtime-slot receipt, every component venv receipt, activation and final
readback. It can project the exact Python fields into the parent installer
`MANAGED_TOOLS` journal event only together with a fresh post-tool plan
fingerprint.

The executor does not verify an outer catalog, select a composition, install a
product, modify product data or services, publish artifacts, store credentials,
or authorize cleanup. The native session layer verifies the exact nested
runtime commitment and venv bindings after catalog and manifest admission. The
native transport can acquire the identity-bound bytes but is not wired into a
staging, inspection, execution, or mutation route. Native archive inspection,
privileged mutation wiring and an actual protected arm64 runtime publication
remain required before operational installation can be claimed.

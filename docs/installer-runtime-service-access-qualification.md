# Managed runtime service access and consumed-operation boundary

Date: 2026-10-14. Scope: bounded installer source correction and unsigned qualification.
No release, helper replacement, VM rights mutation, service stop or product retry.

## Actual installed finding

The real 0.4.22 continuation passed execution admission and consumed its single
claim, then failed during component execution. EP was registered but could not
execute its Python interpreter: its service account lacked SEARCH on the central
managed-runtime directory and the selected runtime slot. Forge was not installed.
Original journals, inventory and authority bytes remained unchanged; historical
uncertainty remained true. Empty inventory did not mean an absence of effects.

The runtime directory defect is a proven necessary launch blocker. Correcting it
does not prove that all subsequent EP, Forge, pairing or readiness stages pass.

## Source correction

The authority loader constructs an inert runtime preparer for each selected v7
installation component. EP calls it inside its admitted service-preparation path;
Forge calls it in its explicit mutating bootstrap `ensure`, before product commands.
Route construction and read-only Forge `run` do not grant access.

The preparer derives the exact runtime and accounts from digest-bound composition
and private authority bytes, checks the active host slot and fresh OS identities,
and opens fixed directories without following links. Both runtime directory ACLs
are inspected before any grant. Root-relative opens and held/named identity
readbacks cover both directories before every grant and after the probe. Only the known service cohort receives SEARCH;
root ownership and mode 0700 stay intact. Unknown ACLs, identity changes, other
slots, caller-selected paths and runtime drift fail closed. The selected helper-productvenv is independently bound through its copied
interpreter bytes and bounded configuration (`home` and disabled system packages).
Its held directory, interpreter and configuration bytes/profiles are repeated
before every grant and after the probe. The actual interpreter
must execute under the selected UID/GID with supplementary groups removed, import
SSL and SQLite, and match the declared version. Authority, identity, binary bytes
and held directory identities are rechecked after the probe.

This increment covers the canonical dual-installation v7 route. It does not
qualify legacy project routes, single-component installs, updates or removal.

## Unsigned qualification evidence

| Check | Result | Boundary |
| --- | --- | --- |
| Genuine public Python 3.14.7 and real venv under existing Mini dedicated EP account and non-admin build account | PASS | Isolated root-owned paths; helper record is explicitly source modeled; no service launch |
| Kernel denial before SEARCH, success after SEARCH, no write access and unrelated-user denial | PASS | Real OS enforcement, isolated paths |
| Unknown ACL, inactive slot, identity/authority drift, namespace replacement and foreign copied interpreter/configuration | PASS | Denied before new grants; retained test evidence |
| Repo runtime tests including isolated root/kernel class | 15 PASS | Dedicated EP claim projection in this portable class is explicitly modeled; genuine Mini dedicated-account check is separate |
| Existing full Python validation and coverage gate | PASS | Every gated file remains strictly above 80.2%; source qualification, not installed PASS |

## Post-consumption reconciliation design

The existing execution and continuation records and shared consumption marker are
immutable. Their original one-shot route must continue to reject reuse, including
partial writes or interrupted directory sync. This source increment does not add
an execution endpoint or mint a replacement permit.

A future bounded reconciliation must be a separately admitted action tied to the
same original installation, with a new append-only evidence record. It cannot be
inferred from a missing completion, empty active-worker list, an exit code shown
in Terminal, or mutable operator-owned CLI output.

Before such an action can be admitted, the signed helper must independently hold
and correlate all of the following under its host/helper mutation leases:

1. Exact original request, authority, product artifacts, deployment and instance
   IDs, named operator identity, provider status and retained predecessor hashes.
2. Trusted terminal worker evidence tied to the consumed nonce and reservation:
   final child exit and drain, no worker descendants and no competing reservation.
   A new record may attest only freshly verified facts; it must not claim an old
   unobserved exit. If the historical producer cannot establish this, DENY.
3. Complete component effect readback: official product receipts, actual services,
   accounts and OS identities, paths/data/log/runtime state, registry/inventory,
   pairing/credential references and ports/readiness. Unknown or inconsistent
   effects deny. Credentials are never exported or used as diagnostic content.
4. Current independently verified signed executor and replay anchors. Source
   hashes and historical signatures cannot substitute for current admission.
5. A fixed remediation plan limited to the observed incomplete component. A
   registered service must be officially quiesced before any rights preparation;
   that stop and the new action require separate operational authorization.

Only after those conditions could the helper append a fresh reconciliation
reservation with exact predecessor/effect digests, consume a separate one-shot
claim, and dispatch supported component recovery. Unknown fields, replay, drift,
namespace replacement, incomplete publication and partial effect readback deny.
Old consumption and uncertainty remain unchanged even after future success.

### Current evidence disposition

Current evidence proves consumption and partial EP effects, but the old helper did
not durably publish a trusted terminal-child attestation. Therefore the current
operation remains **DENY for post-consumption execution**. Existing immutable-claim
regressions exercise actual temporary-file reuse and interrupted sync denial;
closed intent/scope tests reject caller-provided authority and unrelated actions.
The source correction and post-consumption design passed scoped independent
Quality/Security review on the final WIP. This is not an implemented
or installed recovery route. No VM attempt is implied by this document.

## Remaining delivery boundary

After source review, a concrete proposal must specify protected delivery, signed
release, helper transition, trusted terminal reconciliation, official EP service
quiescence and one bounded same-installation remediation. None is authorized by
this source-only increment. Public clean CLI/GUI, pairing, readiness and installer
MVP remain OPEN. See the [feature matrix](roadmap/installer-feature-test-matrix-v1.json)
and [customer wizard contract](installer-customer-wizard-contract.md).

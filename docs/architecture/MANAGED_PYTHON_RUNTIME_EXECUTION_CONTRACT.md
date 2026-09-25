# Managed Python runtime execution contract

**Status:** source-level executor kernel, native immutable session projection,
credential-free native HTTPS asset transport, private operation-scoped native
asset staging, read-only native archive inspection, and a closed native
runtime-slot mutation coordinator implemented and composed into one
unprivileged runtime-preparation coordinator. A separate native durable
recovery store now preserves the exact four staged-asset identities in strict,
bounded, private atomic storage and is connected to that coordinator for
save-before-inspection/mutation, cleanup-before-clear and restart cleanup. The
native projection recomputes the complete runtime identity, binds it to the signed
outer-catalog approval, and retains one exact venv identity per selected
component. The transport derives each of the four bounded downloads only from
that admitted identity, denies redirects and verifies the exact SHA-256 before
returning bytes. Staging writes those exact bytes under fixed internal names,
returns no caller path, and re-hashes every no-follow readback. The mutation
coordinator admits only descriptor-derived identities and requires staging and
slot readback around its injected privilege seam. A separate native activation
coordinator now binds exact component venvs, activation, rollback retention and
final runtime readback under the host-wide lock contract. A native client now
uses one fixed privileged Mach service and one fixed NSXPC interface to exchange
only canonical, bounded request and response bytes and authenticates the exact
fixed helper signing identifier and configured Team identity before accepting
remote messages. The helper-side capture coordinator now holds the shared host
mutation lease across exactly one complete low-level observation and binds its
exact tool and gate sets to that request. The helper-owned fixed-file store now
publishes canonical host state atomically and requires exact durable readback.
The closed source coordinator reads only the requested Git, Python and gate set
and rejects an observation when its helper-owned epoch changes across those
reads. A concrete managed-Git source now reads one fixed helper-owned canonical
record through a stable descriptor and fails closed for missing, insecure,
malformed or noncanonical evidence. Only an explicit canonical `ABSENT` record
means absent. A paired atomic publisher refuses to repair insecure prior state,
synchronizes file and directory descriptors and requires exact durable readback
through a closed decorator. A concrete managed-Python source now reads one
fixed helper-owned canonical record through a stable descriptor. It preserves
the exact active runtime and slot, retained identities and evidence reference;
only an explicit nil runtime/slot with no retained identities means absent.
Missing, insecure, malformed, noncanonical or inconsistent evidence fails
closed. Its paired atomic publisher refuses to repair insecure or noncanonical
prior state, synchronizes file and directory descriptors and requires exact
durable readback through a closed decorator. No live managed-Git or
managed-Python OS observer or mutation adapter, production runtime artifact,
concrete gate adapter, signed helper registration, released mutation wiring, or
live machine installation is approved by this increment.

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
SHA-256 before returning identity-bound bytes.

The native stager accepts only that transport seam, one safe opaque operation
identity and the admitted runtime. It creates an effective-user-owned `0700`
operation directory beneath its trusted state root and writes the four roles
under fixed internal names as single-link `0600` regular files. Its public
result carries only the operation/runtime/asset commitments, an opaque
reference and descriptor-derived file identities. Readback reopens every
directory and file without following symlinks, repeats ownership/mode/link and
size checks, enforces the role-specific byte bound, matches the captured file
identity and re-hashes the bytes against the signed download identity. Cleanup
removes only the four fixed files and the exact descriptor-matched operation
directory. The stager does not inspect or extract an archive, persist an
executor journal receipt, choose a runtime slot, or authorize mutation.
Cleanup is retry-safe for the same validated staged identity: an already absent
operation or exact staged file is treated as removed, while changed files,
symlinks, insecure directories and unknown residual entries still fail closed.
This closes the crash window between deletion and durable pending-record
clearance. The separate durable recovery record uses a fixed V1 schema and
persists the exact operation, runtime, opaque staging and per-role
download/file identities in canonical JSON. Its installer-owned root is
effective-user-owned `0700`; its single-link regular record is `0600`, opened
without following symlinks, bounded to 64 KiB, written by file-and-directory
`fsync` plus atomic rename, and revalidated around each operation. A repeated
save/clear of the same complete identity is idempotent, while a different,
malformed, insecure or corrupt pending identity cannot replace or clear it.
The record contains no path, command, environment value or credential. The
integration is fail closed: the coordinator clears an earlier pending record
through exact retry-safe cleanup before starting fresh work, saves the newly
returned staged set before archive inspection or slot mutation, and clears it
only after exact terminal cleanup. A cleanup or clear failure retains the
record and blocks `READY`. Its public restart entry point performs only record
load, exact staged cleanup and identity-matched clear; it cannot inspect an
archive or call the mutation seam. A process interruption inside acquisition,
before the stager can return the complete four-file identity for persistence,
still requires a separate orphan-reconciliation increment. Both fresh
preparation and cleanup-only recovery first acquire one injected host-wide
nonblocking lease and retain it through recovery, acquisition, inspection,
runtime-slot mutation and terminal cleanup. The file-backed lease uses a fixed
installer-owned `0700` root and a single-link `0600` lock file, opens both
without following final symlinks, and reports busy, unavailable and release
failure separately. No state boundary is called when acquisition fails, and a
release failure cannot return `READY`.

The native archive inspector accepts only the exact staged asset set plus the
admitted runtime identity. It re-reads all four assets through the staging
boundary, then streams the runtime archive without extracting or executing any
member. The frozen archive profile is one constrained gzip envelope (deflate,
no optional header fields, zero timestamp) containing a POSIX ustar stream. The
tar stream permits only safe relative regular-file and directory entries,
rejects duplicate paths, links, special files, base-256 sizes, invalid checksums,
nonzero padding and nonzero data after the end marker, and applies entry, path,
expanded-size, manifest-size and interpreter-size bounds.

The archive root contains `forge-platform-runtime.json` with schema
`forge-platform.managed-python-runtime-archive-manifest/v1`, an explicit `bin/`
directory, and executable `bin/python3`. The strict duplicate-key-rejecting
manifest binds every non-self-referential runtime field, the exact artifact
URL, and the source and provenance locators needed to reconstruct the signed
identity. The signed artifact digest supplies the unavoidable outer binding to
the archive bytes themselves; an archive cannot safely embed its own digest.
Inspection proves:

- the standard managed-runtime archive layout;
- the fixed archive-relative interpreter `bin/python3`;
- exactly one executable architecture, `arm64`;
- the exact macOS deployment floor;
- CPython version, standard-GIL build, Python/ABI/platform tags and policy
  revision; and
- the exact source, source-provenance and build-provenance digests.

The interpreter is inspected as bytes in the tar stream. It must be a thin
little-endian arm64 Mach-O executable with exactly one macOS `LC_BUILD_VERSION`
deployment target equal to the admitted semantic version. No member is written
to disk by this inspection step.

The executor admits no `x86_64`, universal/fat, macOS-25, PATH, system-Python,
Homebrew-Python, or network-latest fallback.

## Immutable slots and product venvs

The runtime slot identity is derived only as
`sha256-<approved-runtime-identity-hex>`. The injected privileged mutation
adapter may install only that exact verified archive into the installer-owned
managed-Python root. Its readback must repeat the runtime identity, archive
digest, fixed interpreter-relative path, thin arm64 architecture and macOS
floor.

The native runtime-slot coordinator turns the admitted runtime, exact staged
asset set and successful archive inspection into one closed mutation request.
That request carries the derived slot identity, opaque staging reference,
descriptor-derived file identity and inspected runtime commitments. It carries
no caller-selected path, executable, command, environment value or credential.
The coordinator reopens and verifies the staged archive before crossing the
privilege seam. For a missing slot, the adapter's install response is
insufficient: the coordinator verifies the staged archive again and requires a
separate fresh slot readback that matches every requested identity before it
returns `READY`. An exact existing slot is idempotent; any existing, returned
or read-back drift fails closed. The protocol does not itself provide the
privileged implementation or authorize a live installation.

The native preparation coordinator composes these existing boundaries for one
already verified composition session and one deployment target. It derives a
deterministic operation identity from the session, composition, manifest,
deployment, runtime and sorted per-product venv identities; stages only that
runtime; requires an exact staged identity; runs archive inspection; obtains a
fresh runtime-slot receipt; and discards the private staging set before
returning. Only a receipt that rebinds the exact session, deployment,
operation, runtime, archive, inspection and slot evidence can become `READY`.
Any cleanup failure becomes `cleanupPending` and blocks success. This
coordinator uses a private pending-record store for exact staging cleanup but
does not itself persist the parent installer-operation journal, implement the
privilege seam or expose a released-app route.

After exact slot preparation, the native activation coordinator derives
`INSTALL`, `UPGRADE` or `NO_CHANGE` only from a trusted installed-runtime
readback. Under the same host-wide lock contract it binds every component venv
to the admitted runtime slot, treats an exact existing venv as idempotent,
requires a fresh readback after every venv creation, rechecks the initial active
runtime before activation, preserves every pre-existing retained runtime plus
the exact upgrade rollback runtime, and requires a final active-runtime
readback. The privilege seam receives only operation, component, venv, runtime,
slot and retained-runtime identities. It accepts no path, executable, command,
environment value or credential. Before reporting success, the coordinator
persists the resulting native `READY` receipt as canonical mode-0600 JSON in
the installer-owned mode-0700 recovery root. An exact retry reloads that
receipt and freshly verifies every component venv plus the active runtime
without repeating mutation. A conflicting, malformed or insecure record fails
closed. This durable native receipt binds the preparation, venv,
activation and final-readback evidence. The native terminal coordinator
projects it into the exact platform-neutral executor `COMPLETE` shape,
including the same canonical request fingerprint used by the Python contract,
projects that receipt into the same typed `MANAGED_TOOLS` journal evidence as
the Python contract, and offers it to an injected durable parent-journal bridge. The pending native
receipt is cleared only after the terminal coordinator, under the host-wide
lease, freshly re-reads every venv and the active runtime and the bridge then
accepts the exact terminal receipt. The native file-backed parent-journal store
now admits one canonical private `PLANNED` record, rejects a second identity,
and atomically advances only an exact terminal request/evidence set to
`MANAGED_TOOLS`; identical retries are idempotent. The concrete native fresh
replanner now derives the post-tool decision and fingerprint from fresh managed
Git, managed-Python and five non-tool gate readbacks. The replanner can now
consume one strict context-bound snapshot through a concrete private-file
reader, preventing a decision assembled from different observation epochs. A
helper-facing store durably publishes that exact snapshot with exclusive atomic
rename, descriptor readback and idempotent conflict handling. A producer
coordinator validates one complete host observation, persists it and requires
an identical durable readback before returning it to the replanner. A concrete
host-observation adapter derives one closed request containing only frozen
identities, accepts one canonical serialized helper response and rejects
malformed, noncanonical or context-drifted evidence. Its native NSXPC client
uses one fixed privileged Mach service, one fixed interface and canonical
request bytes. Before resuming the connection it requires the exact fixed
helper signing identifier and configured Team identity on a Developer ID
Application chain. A paired service handler rejects noncanonical requests
before capture and returns only a canonical context-bound snapshot. Its named
listener uses Foundation's reciprocal pre-delegate code-signing gate to admit
only the exact configured installer bundle and Team identities; both Team
bindings can be constructed from sealed release trust. A locked helper-side
capturer then admits one complete atomic host read, verifies the exact tool and
gate sets and attaches the request context only after successful lock release.
A concrete file reader now opens one fixed helper-owned host-state document
without following links, requires private ownership and modes, verifies stable
descriptor identity and size, and accepts only canonical complete bytes whose
tool and gate sets exactly match the closed request. A paired fixed-file store
publishes those canonical bytes with private temporary creation, file and
directory synchronization, atomic replacement and exact durable readback; it
rejects insecure or noncanonical prior state rather than repairing it. The
closed source coordinator that supplies the document now enforces the exact
request set and matching before/after host epochs. The descriptor-safe
managed-Git record reader is implemented; its producer and mutation route,
concrete Python and gate adapters, signed service registration and the released
route are not yet implemented. The
native seeding coordinator now validates the exact session/deployment and
pre-mutation activation plan plus original managed-tool action set, derives reconciliation itself,
persists `PLANNED`, and accepts success only after an identical durable
readback. Runtime preparation can then produce the `READY` receipt that the
activation request must bind back to that same plan.

The native parent-journal admission adapter now requires a fresh post-tool
qualification with the original stable-plan fingerprint, the exact runtime,
rollback and ordered venv identities, no remaining managed-tool or Python
action, and explicit product-dispatch readiness. Only then does it construct
the typed `TOOLS_VERIFIED` evidence and call the atomic journal-advance seam.
The concrete source-level fresh replanner, its read-only snapshot adapter,
durable helper-facing snapshot store and capture/persist/readback producer
coordinator plus the strict host-observation request/response adapter, fixed
native NSXPC client transport and fail-closed helper service handler are
implemented together with mutual exact signed-peer authentication and a locked
single-read helper capture coordinator plus the descriptor-safe fixed-file
host-state reader, atomic publisher, source/publish/durable-readback coordinator,
epoch-bracketed exact source collector and descriptor-safe managed-Git record
reader plus its atomic publisher and exact durable-readback decorator, and the
descriptor-safe managed-Python record reader plus its atomic publisher and
exact durable-readback decorator; the live managed-Git and managed-Python OS
observer/mutation routes, concrete gate adapters, signed service registration
and released route wiring are not yet implemented.

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

The platform-neutral bridge now makes that projection atomic in the durable
installer journal. It reconstructs the original `PLANNED` record from the
original plan, binds the terminal receipt to the exact executor request and
component-venv set, admits only the frozen runtime and rollback identities,
and recomputes the fresh post-tool plan fingerprint. The fresh plan must keep
all installer, catalog, composition, provider and product inputs stable and
must report every generic managed tool plus the exact Python runtime as
`NO_CHANGE` before `MANAGED_TOOLS` can be persisted. The generic journal
advance API rejects that state, and a durable journal cannot be started from
an already advanced record.

The executor does not verify an outer catalog, select a composition, install a
product, modify product data or services, publish artifacts, store credentials,
or authorize cleanup. The native session layer verifies the exact nested
runtime commitment and venv bindings after catalog and manifest admission. The
native transport and private stager can acquire, durably capture and re-read
the identity-bound bytes, and the native inspector can validate the frozen
archive envelope, layout, manifest and interpreter identity. The native
runtime-slot coordinator also binds those exact results to a closed injected
privilege seam and requires fresh post-mutation readback. The native
preparation coordinator now assembles those pieces into one fail-closed,
cleanup-enforcing source-level transaction and emits an exact `READY` receipt.
While holding the host-wide operation lease, it also reconciles unrecorded
staging directories left by an interrupted acquisition. That reconciliation
accepts only the fixed operation-name shape and fixed asset names, revalidates
every directory and file by descriptor, and fails closed on ownership, mode,
link, type, size or name drift. The platform-neutral terminal-receipt bridge is
implemented. The native activation coordinator now continues from that exact
preparation receipt through idempotent component-venv readiness, activation,
rollback retention and final readback. It atomically preserves its canonical
`READY` receipt in the same private recovery root and, on an exact retry,
revalidates every venv and the active runtime before returning the stored
evidence. The native terminal coordinator then assembles the same ordered
asset, inspection, slot, venv, activation and final-readback references used by
the platform-neutral `COMPLETE` receipt. Its request fingerprint is tested
against the Python implementation. It also exposes the exact `TOOLS_VERIFIED`
evidence projection, including the platform-neutral default that uses the
Python runtime receipt when no generic tool receipts are present. An injected bridge must durably and
idempotently admit that exact receipt before native pending state is cleared;
the coordinator first repeats all venv and active-runtime readbacks under its
host-wide lease. The native admission adapter additionally rejects stable-plan,
runtime, rollback, venv or terminal-action drift before calling its atomic
parent-journal seam. Its durable native store uses one fixed active-record name,
canonical bounded JSON, a private exclusive lock, no-follow reads, ownership,
mode and link-count checks, durable atomic replacement and exact idempotent
retry comparison. The concrete fresh replanner now owns the native canonical
post-tool fingerprint. The source-level parent-journal seeder validates and
durably reads back the exact `PLANNED` record before runtime preparation or
tool mutation may proceed. That seeder and the fresh replanner now consume one
typed native stable plan whose canonical fingerprint is derived from the
reviewed release, immutable session/catalogs, exact Forge+EP inventory,
provider requirements, component diff, managed Git actions and complete
pre-mutation Python/rollback/venv intent. No caller may inject an unrelated
stable-plan digest. The concrete read-only snapshot adapter, durable
single-assignment store, producer coordinator, closed canonical-response host
adapter, fixed privileged NSXPC client transport, canonical helper service
handler, mutual exact Developer ID peer authentication and the locked
single-read helper capture coordinator are implemented. The fixed-file reader
also admits one canonical complete helper-owned host-state document with
descriptor, ownership, mode, link-count and request-set checks. Its atomic
publisher requires a private root and exact durable readback after publication.
The exact source collector also requires matching helper-owned epochs around
all requested tool, Python and gate reads. The concrete managed-Git source
admits one fixed canonical helper-owned record with stable no-follow readback;
only an explicitly recorded `ABSENT` or `UNKNOWN` is preserved. Its paired
atomic publisher and exact durable-readback decorator are implemented. The
managed-Python source admits one fixed canonical record through the same stable
no-follow checks and accepts absence only when runtime, slot and retained set
are explicitly empty. Its atomic publisher and exact durable-readback decorator
are implemented. The live Git and Python OS observers and mutation routes,
concrete gate adapters, signed service registration and these coordinators are
not wired into the released runtime. A
concrete reviewed authorized helper
process, released mutation wiring and an actual
protected arm64 runtime publication remain required before operational
installation can be claimed.

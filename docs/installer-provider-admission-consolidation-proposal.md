# Proposed read-only provider ceremony admission consolidation

Status: **SOURCE_IMPLEMENTED / UNSIGNED_QUALIFIED — signed runtime timing OPEN**.
After the specific permission request and the user's instruction to continue,
the bounded replacement was admitted. The previous automatic-review rejections
remain historical evidence; they were not bypassed.

## Concrete change under review

The current first-ceremony path recursively admits a source, each unverified
Codex destination and the source again. Each nested read includes full material,
current-release and physical-provider checks. Existing production target
preparation is read-only: it inspects account identity, fixed executable evidence
and provider-home metadata without creating accounts, starting login or copying
an authentication cache.

Implemented replacement applies only before a new ceremony starts:

1. Decode canonical intent and load the exact immutable reviewed plan twice;
   require equality before physical resolution and a third equal load afterward.
2. Require a new deployment, selected supported component owners, exact runtime
   and credential scope. Multi-target Codex remains exactly version 0.157.1.
3. Read fresh provider status through the existing full reader, including its
   unchanged material/currency/physical before-and-after checks.
4. Resolve source and unverified targets once, requiring exact provider/evidence
   and the existing physical account/executable/home checks for every target.
5. Repeat the full reader, independently resolve every physical target again
   and compare its full account/executable/home/evidence, then reload the exact
   plan. Reject any state/evidence/target/account/runtime/plan drift. Only then
   start the existing single ceremony.
6. Keep separate fresh admission at renewal, completion and bootstrap-copy
   boundaries. Do not reuse results across a mutation, helper request or plan.

No cache, skipped signature, weaker currentness policy, new credential transfer,
new account rights or parallel login ceremony is proposed.

## Qualification

The existing complete material/currentness/physical reader is unchanged. A source
integration regression exercises it twice and independently rejects each of its
four material and four currentness failure positions. Separate tests reject
changed account identity, executable, home and missing physical target even when
status evidence remains identical. Plan/state/target/runtime/canonical-intent
checks and exclusion of an already verified peer are covered.

A comparison through the old and new source paths returns identical admitted
contexts. Full group reads decrease from **7 to 2** for the dual-Codex initial
ceremony. A later standalone admission adds two fresh reads: the first result is
not reused across credential publication, renewal, completion or bootstrap copy.
This is a deterministic source-call count, not measured signed-runtime speedup.

A concurrent begin while the first physical read is suspended launches zero
extra children; the existing actor reservation is retained. One official ceremony
and separate per-target verification remain required. No historical uncertainty
or active effect is cleared by this change.

**96 focused Swift security tests PASS**, zero failures/skips. Combined with the
rootcause, ordered GUI progress, private progress parsing, signature and timing
tests: **143 Swift tests PASS** (135 core + 8 presentation), zero failures/skips.
The prior **102 Python rootcause/progress/pairing tests PASS** remains applicable;
this follow-up changes no Python source. App and CLI compile unsigned.

## Runtime and delivery limits

The current public version is still 0.4.23. These are unsigned source results;
installed pairing, readiness and performance acceptance remain open. Operational
machine diagnostics are retained privately and are not a public source receipt.

No new product operation, helper transition, cleanup, publication or release
claim was performed by this source increment. The previous release budget is
still 1/1 consumed. A new bounded delivery/runtime authorization remains required.

Native screen control is still unavailable because its runtime rejects the
symlinked CODEX_HOME writable root. No trust opt-out was enabled. Supported
Parallels capture/keyboard control may be used for actual VM interaction;
a source preview or helper-only visual check is not an end-to-end GUI PASS.

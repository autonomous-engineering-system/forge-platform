# Historical trust-contract correction and one-shot continuation

Date: 2026-10-14. Scope: installer only, original dual CREATE and installation
pairing. No project registration, product source/lifecycle change, trustkey
change, credential transfer, extra EP stop or new product operation.

## Proven incompatibility

`ManagedInstallerHistoricalExecutorIdentityCodec` emits the release trustconfig
SHA256 as lowercase **bare64**, matching signed release/provenance identity.
Python `HistoricalExecutionExpectedBinding` incorrectly required **tagged71**.
Real public 0.4.20 record/worker evidence proved rejection. All other request,
record, descriptor, CodeDirectory and effect digests remain strictly tagged.
An unchanged effect journal does not imply that no attempt was reserved.

## Admission boundary

The ordinary v1 execution-record publisher still refuses existing records.
Continuation uses one separate immutable `historical-continuation-<opHash>.json`
with a new current executor, nonce/reservation and exact predecessor/denial hashes.
Both modes share the same immutable consumption claim; no second successor is
allowed. Old bytes and historical uncertainty are never reset or edited.

Only the known 0.4.20 / protected source `07d3b8d` trust-format defect is recognized.
The full signed old app must be preserved under the fixed root-private namespace
`state/historical-denied-executors/<previousRecordSHA>/ForgePlatformInstaller.app`.
The source route independently checks Apple signatures, public signed descriptor,
CodeDirectory/provenance/source, sealed full-worker digest and exact reviewed
pre-admission code hashes. Those hashes recognize a denial; they confer no trust
or execution authority. No caller can select an archive, loader, root or permit.

Held archive/app/resource/leaf identities are rechecked through the whole proof.
An unknown living process is a denial. The bounded PID/path scan checks the known
recovery interpreter and helper paths, and permits only the actual current
parent daemon. The source-order proof excludes product-adapter construction and
mutating descendants before rejection; the scan does not claim generic global
process quiescence. Original physical EP/service-account quiescence is repeated.
Consumption/completion absence alone never proves no admitted execution.

Fresh authenticated named operator, OS identity, original signed recipe/evidence,
current signed executor, exclusive host lease, original effects and one-shot
publication/consumption remain mandatory. If any terminal-denial, archived-source,
process, original-evidence or currentness check is unavailable: DENY. No replay of
an old permit and no hand-written denial authority is accepted.

## Qualification and diagnostics

- Native encoder → Python expected-binding regression uses actual encoder output.
- Strict digest, unknown-field and v1/continuation rejection tests.
- Actual root-private IO and immutable preservation tests; external signing and
  physical-original observations in unit tests are explicitly source models.
- Real public 0.4.20 signatures/provenance are retained only for source correlation;
  they are not current authority or installed E2E evidence.
- Native stage errors carry only a closed functional code/label. No exception text,
  credential data, provider identity, nonce, request body or private path is exposed.
- The existing coverage boundary stays strictly >80.2% per required file.

Current result: source qualification in progress; new signed release and actual
VM continuation NOT_RUN. Clean public CLI/GUI E2E and MVP closure remain OPEN.

## 2026-10-14 actual 0.4.21 inspection finding

Public 0.4.21 signed app/package and actual VM helper activation passed. The
authenticated read-only historical inspection denied before product reservation.
The actual sealed worker failed archived-app codesign verification: split argv
`-R`, inline-policy makes codesign interpret the policy as a filename. The same
signed archive, policy and environment succeeds with `-R=inline-policy`.

The separately authorized correction changes exactly four argument construction
sites in the historical archive and current-executor readers. All policies,
fixed tools, team/identifiers, root ownership/ACL/FD checks, process guards,
descriptor/legacy-source checks and one-shot continuation remain unchanged.

Genuine frozen public 0.4.20/0.4.21 carriers qualify real Apple app/helper
verification and exact argv, with wrong identifier/team/CodeDirectory denial.
Only native current-proof capture in the source test is modeled, so the test
cannot invoke installed helper authority or acceptance-store mutation. No
source qualification is an installed PASS. Historical original records and the
signed 0.4.20 denied-executor archive remain unchanged; the original product
continuation allowance is still 0/1. The successor release and VM continuation
remain NOT_RUN until protected delivery and fresh authenticated inspection.

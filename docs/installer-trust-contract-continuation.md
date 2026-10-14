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

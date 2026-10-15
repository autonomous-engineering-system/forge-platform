# Pairing and component progress: qualification boundary

Status: source correction and targeted unsigned qualification. Installed CLI/GUI acceptance remains open.
Baseline: protected installer 0.4.24 source `2f48f5e37858f2eaf716e6f7064f9ca675d1168b`.

## Proven installer defect

The dispatcher decorated both product adapters with `ProgressProductAdapter`.
The product saga legitimately accepts those observational views, but the concrete
installation pairing executor requires `ForgeServerProductAdapter` and
`EngineeringPlatformSystemProvisionerAdapter`. Passing the decorators to that
boundary therefore rejects the call before either product configures its peer.
This explains the observed combination of completed component receipts,
`pairing-failed`, and a product-owned `NOT_CONFIGURED` readback.

## Correction

For the two-component route, the dispatcher passes the original admitted products
to the coordinator. The coordinator creates progress views only for component
execution and final readback. Pairing retains the original concrete adapters.
The currency guard still wraps every component execution; product type, artifact,
instance, account and final-readiness checks are unchanged. The single-component
progress route is unchanged. No generic proxy unwrapping or type-check relaxation
is introduced.

Fixed pairing failure codes distinguish route admission, initial EP readiness,
Forge configuration, configuration validation, durable configuration readback,
authenticated connectivity, and final EP readiness. Only this closed code is
recorded in the existing operation/release-bound progress document. Raw exceptions,
product streams, account paths and credential values do not become user messages.
Native decoding binds these codes to a failed pairing row and provides a concrete
next step. Existing progress history remains preserved; failure information cannot
authorize retry or replace terminal product receipts.

## Evidence

- A complete source-saga regression with the real protected progress writer fails
  on the frozen original dispatcher/coordinator source because pairing receives
  different adapter objects. The corrected source passes, records final readiness,
  and executes each component once.
- A negative source test confirms that passing a decorator directly still fails
  the concrete pairing type guard before any product readback/configuration.
- Targeted dispatcher, saga, worker, authority, pairing and protected-progress
  tests: **112 PASS**, including root-only temporary-file IO.
- Native closed-code/operation-binding regressions: **4 PASS**.
- The exact public Forge 2.8.1 wheel (source
  `c8833ffa4754800de451cce94b109ef1ad07123f`, SHA256
  `7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0`)
  independently configures and reads back its installation peer in an isolated
  temporary runtime. The released first-bind API uses the actual OS identity.
  The real installer account runner also returns `CONFIGURED` and identical
  durable readback. No provider credential, network backend, service or port is
  used by this configuration-contract qualification.

The source-model regression and isolated public-product contract tests are not
live authenticated pairing or installed E2E PASS. Private runtime records remain
unchanged, including their unresolved effect history. No new release, helper
replacement, service action, VM attempt or recovery authority follows from this
source correction. Full protected release gates and fresh public CLI/GUI runtime
qualification remain separate requirements.

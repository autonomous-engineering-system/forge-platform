# Composition catalog release boundary

Assignment: `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`.

The installer descriptor for 0.2.4 fixes the stable feed locator to:

`https://github.com/autonomous-engineering-system/forge-platform/releases/download/forge-platform-composition-catalog-stable/ForgePlatformInstallerCompositionCatalog.json`

The catalog release framework prepares this feed without putting its private
Ed25519 key on a GitHub Actions runner. It does not make the feed live merely
by existing in source.

The organization runner group now admits this workflow only through the exact
`autonomous-engineering-system/forge-platform/.github/workflows/forge-platform-composition-catalog-release.yml@refs/heads/main`
reference. The group remains limited to the one public Forge Platform
repository, and the credential-bearing signer account remains outside GitHub
Actions.

## Protected candidate build

`.github/workflows/forge-platform-composition-catalog-release.yml` accepts only
an exact protected `main` commit and two already reviewed, committed inputs:

1. one immutable `forge-platform.composition/v3` manifest;
2. one immutable `forge-platform.component-combination-catalog/v1` index.

The candidate preparer, protected build workflow and offline finalizer also
support a separate multi-composition/v2 candidate containing two to eight
exact v3 manifests. That candidate is not publishable until the local public-byte
readback binds every manifest asset. The single-manifest release route remains
the current publication boundary.

The credentialless Apple Silicon runner runs the repository gates, proves that
the catalog Keychain key is absent, validates both documents with the runtime
parsers, and binds their exact bytes, URLs, SHA-256 digests, freshness window,
sequence, installer requirements, component set, upgrade routes and approved
managed-Python identity into a canonical unsigned outer catalog. The protected
`forge-platform-installer-signing` Environment emits only a non-secret
authorization for those exact bytes.

## Local signing and publication

`scripts/run_local_composition_catalog_release.sh RUN_ID SOURCE_SHA` runs only
under the dedicated local signer account. It independently reads the successful
workflow and protected job conclusions, rechecks exact current `main`, takes the
same exclusive offline-signing lock as the installer release, builds and
Developer-ID-signs the catalog Keychain helper, and signs the canonical payload
with the separate catalog key. The finalizer verifies the signature against the
committed catalog trust resource before publication.

Each sequence publishes immutable manifest, index, signed catalog and operation
evidence on `forge-platform-composition-catalog-v<sequence>`. Only after public
readback succeeds may the local publisher replace the stable locator asset. It
rejects sequence rollback and same-sequence different bytes, then downloads the
stable asset again and records the exact public digest as `PUBLISHED` evidence.
The scripts never export a private key or weaken a Keychain ACL.

## Deliberately unresolved producer input

`.github/workflows/forge-platform-composition-producer-observer.yml` polls the
public Forge, Engineering Platform and Workspace release surfaces hourly and on
manual dispatch from a GitHub-hosted runner. It has read-only repository
permission and uploads one canonical observation report. The observer verifies
exact release tags and source revisions, terminal release receipts, GitHub
asset digests, registry readback and exact PyPI wheel/sdist identities. It does
not create a branch, PR, manifest, signing authorization or release.

`composition-producer-sources.json` is the reviewed binding from product roles
to their public producer repositories and release contracts. Forge 2.7.39 and
Engineering Platform 2.3.106 are the required qualified producer baselines for
the first functional installer release. The separately corrected external Forge
2.7.39 update controller is bound by its own protected source and digest.
Forge 2.7.36 and Engineering Platform 2.3.103 remain historical ownership-gap
artifacts; Engineering Platform 2.3.104 and 2.3.105 are historical preservation
or release evidence, not the active clean-install baseline. Workspace is an optional observation: it has no public
production release and its current release contract would publish only a source
bundle, so its absence or `OBSERVED_NOT_INSTALLABLE` status does not block a
Forge plus Engineering Platform composition. Managed Git, managed Python and
the pinned Codex/GitHub CLI provider runtime archives have public,
digest-bound distribution evidence. Their external-input observations may
report `READY` after a fresh direct public-byte readback.

The managed Python 3.14.7 archive and build provenance also require a separate
native Apple Silicon test record. The protected
`forge-platform-managed-python-test-evidence.yml` workflow reads the exact
already published bytes, checks the archive layout and interpreter digest,
starts the interpreter with isolated standard-library probes, creates a new
venv with bundled pip, and publishes a canonical report on a new immutable
`forge-platform-managed-python-test-evidence-v1` release. The earlier
`forge-platform-managed-tools-v1` release remains untouched. This test record
is only runtime evidence; the reviewed production composition still needs
product-specific build/test, compatibility, provider and service evidence.
No manifest may reference the test record until its public asset digest and
exact source have been independently read back.

A Forge or Engineering Platform release is not automatically a safe
composition. Promotion still needs an explicitly reviewed immutable composition
with product build/test evidence, compatibility approval, service contracts,
exact provider runtime and target identities, and an explicit upgrade route.
The current Forge and EP release receipts prove their wheel and source
identities; a public platform artifact alone does not prove its component-owned
installation, authentication or readiness. A future Workspace release remains
outside this composition until it has an installable, explicitly reviewed
contract.

Therefore no sequence-1 production manifest is committed and no stable catalog
asset is claimed live. A later producer increment may poll peer releases and
prepare a reviewable manifest change, but it must fail closed until every field
above has immutable evidence. A peer release must never silently rewrite or
auto-promote a compatible-composition decision.

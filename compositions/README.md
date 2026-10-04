# Reviewed sequence-1 installer compositions

Assignment: `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923` / forge#141.

The three canonical `composition/v3` manifests represent Forge-only, EP-only,
and Forge+EP deployment choices for the first functional installer. The
component-combination index binds their exact canonical bytes and immutable
sequence-1 release asset names. `upgrade_from` is deliberately empty: a
separate reviewed route is required before an older composition is upgraded.

| Component | Frozen source | Exact released wheel | Product release receipt |
| --- | --- | --- | --- |
| Forge 2.7.39 | `ebc43dc12da27353f85c991a26da9852aa790f05` | `sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1` | `sha256:078a9f09f048cbd1fd36c4d5f83a5739dfeb3c3a546ba94bb1148596135ba15f` |
| EP 2.3.106 | `7b99b578153ae5d72372a09db194306b49ec9f9c` | `sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694` | `sha256:8ac24fcc41fbf41d8e30efbba1578a95599f50f1cd665d72fc96fe402d260d05` |

The release receipts establish product-owned build/test and publication
outcomes. The separate [native managed-Python product report](https://github.com/autonomous-engineering-system/forge-platform/releases/download/forge-platform-product-managed-python-evidence-v1/product-managed-python-evidence.json)
(`sha256:2d472b5f3a4e270d99cacb91e9fda2287dbc45f8c17f560ac5d1a240ca31bd6d`)
records exact public wheel installation, metadata readback and product CLI
help in separate fresh venvs on managed Python 3.14.7. The managed runtime
identity is `sha256:519d7975f16e78f808403188b3a8417bab10af000208ef1ec82c42bccfa94ceb`.
Managed Git 2.56.0, Codex CLI 0.157.1 and GitHub CLI 2.101.0 are pinned to
their reviewed public archive and executable digests in each manifest.

The Forge service reference names its frozen server deployment contract. The
EP reference names its product-owned system provisioner. Both require system
LaunchDaemons; the selected deployment template is bound to the exact
deployment and owning instance by the shared installer admission route. Both
component provider contexts require independent human authentication and
readback before readiness. A composed Forge+EP selection still requires the
product-owned pairing route and joint readiness gates.

These inputs authorize only preparation of an unsigned candidate until the
protected catalog release, offline Keychain signature, public byte readback,
and stable locator advancement succeed. Product wheel tests, source receipts
and this review are not live service, provider or fresh-Mac acceptance.
Forge, EP, Workspace and forge#142 remain read-only producer dependencies.

## Sequence 2: Forge GitHub scope correction

The sequence-1 manifests and index remain untouched as immutable historical
release inputs. Sequence 2 publishes the same EP 2.3.106 and Forge 2.7.39
product artifacts with a corrected provider set: EP owns Codex and GitHub CLI;
Forge owns Codex only. The Forge product contract has no direct GitHub provider
consumer for this runtime, so a Forge-local GitHub login must not gate clean
installation or readiness. This matches the instance-owned provider example in
ADR-0007 and Forge's `FORGE_CONSOLE_EP_PARITY_AND_PAIRING_V1` contract.

The new `*-v2.json` Forge manifests and
`component-combination-catalog-v2.json` bind immutable sequence-2 asset URLs,
byte digests and freshness. EP's unchanged manifest is republished under the
sequence-2 asset name so the three topology choices remain an exact set.
The active sequence-1 PLANNED host operation must be independently recovered
under the existing fail-closed root guards before a new catalog selection; no
provider credential may be copied or treated as readiness evidence.

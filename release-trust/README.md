# Installer release trust activation

The public trust resources
`ForgePlatformInstallerReleaseTrust.json` and
`ForgePlatformInstallerCompositionCatalogTrust.json` are intentionally absent while
`../installer-release-identity.json` is `UNCONFIGURED`.

Add it only after live local-signer readiness proves the real Developer ID Team,
bundle identity, and descriptor-signing public keys. The committed release resource must parse as
`forge-platform.installer-release-trust/v2`; its canonical configuration
digest, repository, Team, bundle, key IDs and threshold must exactly match the
reviewed `READY` identity. The catalog resource must bind that same release
trust digest. Private keys never belong here.

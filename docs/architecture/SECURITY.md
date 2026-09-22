# Installer security boundary

The intended installer architecture follows these invariants:

- acquire only trusted, published artifacts;
- verify artifact digests and supported signature/provenance evidence;
- use least privilege and explicit instance-specific service registration;
- keep secrets out of repository configuration and deployment receipts;
- isolate every Forge/EP server instance's data, provider installations,
  provider homes and durable credential state from every other instance;
- permit one interactive provider authentication to fan out only through a
  provider-supported mechanism into independently verified owning
  component-instance contexts;
- require Forge/EP server provider credentials to work from their system-service
  context after cold reboot without an interactive user login;
- keep EP Project Agent credentials user-owned per Host/OS-user context;
- never bypass localhost trust; and
- use real consumer credentials for local components.

Security qualification and signing/notarization testing are future Forge Platform-specific validation concerns. This repository contains neither privileged installer code nor production credentials.


The installer must never treat a successful human provider login as proof that
all target instances are authenticated. Each instance must independently prove
provider readiness. Provider secret material may not be copied by format
assumption: fan-out requires an explicitly supported provider bootstrap or
transfer contract. See
[ADR-0007](adr/ADR-0007-multi-instance-deployments-and-provider-fanout.md).

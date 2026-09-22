# Instance discovery and pairing contract v1

**Status:** Canonical target contract. Product implementation and qualification are separately governed.

This contract is shared by Forge Server, Engineering Platform (EP) Server and Workspace Server. It gives the installer and product-owned clients one safe way to find a candidate, prove which instance it is, and create an explicit binding. It does not create a shared runtime, database, authorization domain, or service registry authority.

## Descriptor and discovery

Every installed server owns a random, stable, opaque `instance_id`. The ID is created with its installation identity, survives ordinary restart/update and is included in product-owned backup/restore semantics. It is never derived from a hostname, IP address, checkout, project or mDNS name. A replacement or a deliberately reissued identity is a different instance.

A host may expose multiple instances of the same server product. Discovery,
service naming and configured endpoints must therefore enumerate and
disambiguate by stable instance identity rather than collapsing by hostname or
product type. Same-host Forge and EP instances are valid peers when their exact
instance IDs, fingerprints, endpoints and product-owned bindings are verified.
A human-readable instance or managed-deployment label is display metadata only
and never substitutes for `instance_id`.

`forge-platform.instance-descriptor/v1` is the public candidate document:

```json
{
  "schema": "forge-platform.instance-descriptor/v1",
  "product": "forge-server | ep-server | workspace-server",
  "instance_id": "opaque-stable-id",
  "api": [{"version": "v1", "endpoint": "https://host.example/api/v1"}],
  "capabilities": ["health", "pairing", "..."],
  "identity_fingerprint": "public-key-or-certificate-fingerprint",
  "expires_at": "RFC3339 timestamp"
}
```

Implementations may add non-sensitive display metadata, but descriptors and discovery records contain **no** bearer credential, pairing secret, project or repository data, account data, queue/run state, path, log, or private topology. Unknown required fields and unsupported schema/API versions fail closed.

LAN discovery may advertise a short-lived descriptor through DNS-SD/mDNS (for example `_forge-platform._tcp`, with product, descriptor version, instance ID, API versions and a descriptor endpoint/fingerprint in TXT data). It is only a candidate locator. A configured HTTPS/unicast endpoint, private-overlay or tailnet endpoint is an equal bootstrap route and is required where multicast is unavailable. Discovery never implies reachability, authenticity, authorization or permission to bind.

## Authenticated pairing and durable binding

An operator or an already authorized product principal starts a pairing flow. The initiating side verifies the endpoint's authenticated identity fingerprint, product, stable ID, supported API/capabilities and requested scope. The target performs its own authentication/authorization and creates a short-lived, single-use pairing ceremony. On completion each owning product persists its own binding through its application service/API: peer product, `instance_id`, verified fingerprint, endpoint set, negotiated versions/capabilities, scope, creation/rotation evidence and revocation state.

Discovery is deliberately not a pairing API. Neither the Forge Platform installer nor a peer writes directly to another product database. An existing binding is pinned to its recorded instance ID and fingerprint: rediscovery of a different candidate, changed fingerprint or changed endpoint identity fails closed and requires an explicit inspect/re-pair/rebind operation. Endpoint rotation for the same identity follows the product's authenticated binding update protocol; it is never an automatic switch to a newly found instance.

Trust domains remain separate:

| Relationship | Trust owner | It must not become |
| --- | --- | --- |
| Workspace Client ↔ Workspace Server | Workspace user/session | server-peer or EP Agent trust |
| EP Project Agent ↔ EP Server | EP host/agent | Workspace Client or Forge peer trust |
| Forge/EP/Workspace Server peers | respective product peer bindings | a user session or Agent credential |

Co-location and loopback do not remove authentication, pairing or authorization.

## Server-operational invariants

Each server **instance** is a headless, independently restartable installed
service with a product-owned runtime storage root outside source/Git checkouts.
Its versioned HTTP API is a transport adapter over interface-neutral application
services; direct cross-product SQL and shared databases are prohibited. On
macOS the product publishes an instance-safe launchd service contract; multiple
same-product instances must have non-colliding service identities, endpoints
and storage roots. Forge Platform coordinates only product-owned lifecycle
requests and correlated readbacks, never service registration or runtime
authority. Product storage contains its own SQL database and product-owned
files, provider contexts, artifacts, logs, backups and cache, with permissions,
retention, migration and recovery defined by the product owner.

## Delivery sequencing

The first Forge → EP → Forge autonomy canary needs only the minimum seams: installed Forge/EP service storage and stable identity, their versioned authenticated HTTP contract, an explicitly configured/pinned EP binding, and restart-safe recovery. It does **not** require Workspace UI, LAN discovery or the universal installer to be complete. Network discovery, full pairing UX, all topology combinations, Workspace Client distribution and installer productization are post-canary capabilities; they must preserve these seams.

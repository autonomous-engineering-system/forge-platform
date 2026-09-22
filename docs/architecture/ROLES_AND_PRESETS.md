# Installable roles and presets

Roles are independently installable; one machine may host any compatible combination.

| Class | Components |
| --- | --- |
| Server | Forge Runtime; Workspace Server; Engineering Platform Server |
| Local | Engineering Platform Project Agent; Workspace Client |

## Conceptual presets

| Preset | Components |
| --- | --- |
| Complete Forge Platform | Forge Runtime, Workspace Server, EP Server, EP Project Agent, Workspace Client |
| Server | Forge Runtime, Workspace Server, EP Server |
| Developer Workstation | EP Project Agent, Workspace Client |
| Custom | Any compatible component combination |

The native Universal Installer source shell presents these profiles through a
signed composition rather than hard-coding versions. Presets select component
**types**; the installer then creates or manages exact component **instances**
inside one selected managed deployment. A host may contain multiple independent
Forge Server and EP Server instances and multiple managed deployments.

A selected composition may require managed Git, the exact catalog-approved
Python runtime and provider validation before it can proceed. Each Forge/EP
Server instance uses a product-owned system-domain `LaunchDaemon` and owns its
own provider CLI installations, provider homes and durable provider
authentication state. That state must remain usable after cold reboot without
an interactive macOS user login.

The provider page may ask the operator to authenticate once to a provider and
fan that supported authorization bootstrap out to multiple selected
component-instance contexts. Each target context is still installed and
verified independently; no Forge instance borrows EP's CLI, configuration or
credentials, and vice versa.

An EP Project Agent remains user-owned and scoped to one Host/OS-user context.
Multiple users on the same machine may each install their own Agent, with
separate user-scoped Agent state and credentials. The shell does not itself
install or mutate a product until a qualified product provisioner adapter
exists. See
[ADR-0007](adr/ADR-0007-multi-instance-deployments-and-provider-fanout.md).

The platform-neutral managed-Python executor is distinct from product
provisioning. It prepares the exact approved runtime and one isolated venv per
selected product through a fixed privileged-adapter protocol; it never installs
the Forge, Workspace or EP artifact into that venv and never assumes ownership
of a product's service, data or migration lifecycle.

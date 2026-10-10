# Clean VM helper 0.4.5 recovery

This qualification recovery is limited to the operator-approved clean VM whose
verified installer 0.4.8 self-update started its staged app while ServiceManagement
retained the running signed 0.4.5 helper. It is not the installed-host upgrade route.

Before invocation, independently verify the VM identity, signed parent 0.4.5,
empty deployment inventory, absent active-installer-operation.json and
product-worker-effects.json, no product instances/services/listeners or running
worker, and provider status without reading credential contents. Preserve the
read-only evidence and all existing installer state. Do not invoke on the Mini
with its historical operation/effect journals or existing debug products.

Only the current verified signed installer 0.4.9 may invoke:

```text
forge-platform-installer helper replace-clean-vm-045 --yes --non-interactive --json
```

The command requires explicit confirmation and a fresh verified-current-release
check. Under the existing cross-process registration lease it checks the exact
signed ServiceManagement parent twice, unregisters through SMAppService, proves
the fixed system job absent, registers the bundled helper and independently reads
its version and enabled/approval status. It accepts no label, username, path,
version or deployment selector. It does not inspect credential contents, rewrite
product journals, kill a helper, boot out a job or reboot the host.

The clean-host evidence is an operator prerequisite, not an automatically
enforced clean-host predicate in this CLI command. A version match by itself
does not authorize using the recovery on a host with products or operations.

After invocation, reread the helper parent/version and CLI inventory. Continue
installation only on actual success. On registration failure, preserve the
observed job state and investigate the ordinary supported registration recovery;
do not retry blindly. Approval required is a pending operator action, not PASS.

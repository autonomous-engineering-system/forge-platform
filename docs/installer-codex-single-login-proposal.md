# Codex single-login bootstrap proposal

Status updated 2026-10-12: the user-approved same-installation bounded exception
is implemented in published installer 0.4.10. Actual clean public authentication
fanout remains unqualified; source/artifact evidence is not a live dispatch
receipt. Existing credentials from another machine remain excluded.
See the [current acceptance matrix](roadmap/INSTALLER_FEATURE_TEST_MATRIX_V1.md).
The SDK discussion below is the pinned design baseline, not a current/latest
SDK claim and not new credential-transfer permission.

## Current supported interface

Pinned Codex 0.157.1 completes a device ceremony into exactly one selected
`CODEX_HOME`. Its file and keyring storage backends are internal implementation
interfaces, not an opaque multi-target bootstrap API. The current installer
launches that CLI for one reviewed owner and independently checks that target.
The generic Python fanout handle does not add a production transfer capability.

OpenAI documents cache reuse on headless systems, including copying the cache
created by an official Codex login. That is a provider-documented fallback,
not permission to copy an operator's existing credentials. The current user
instruction prohibits credential injection and manual credential copying.
The user approved exactly this new installer-owned bootstrap boundary before implementation.

References:

- https://learn.chatgpt.com/docs/auth#fallback-authenticate-locally-and-copy-your-auth-cache
- https://github.com/openai/codex/blob/rust-v0.157.1/codex-rs/login/src/device_code_auth.rs
- https://github.com/openai/codex/blob/rust-v0.157.1/codex-rs/login/src/auth/storage.rs

## Exact proposed boundary

1. Admit the complete selected provider group from the same current helper-owned
   stable plan. Only its selected EP and/or Forge Codex targets are eligible.
   Both executable digests and runtime versions must match the reviewed catalog.
2. Start one official Codex device ceremony in a selected, already provisioned
   component-owned context. Use Codex's documented file storage for this ceremony.
   No caller-supplied token, arbitrary source path or personal Codex home is admitted.
3. Require the real CLI to exit successfully, then independently verify its
   authentication under that exact context's account.
4. Inside the signed root helper only, bootstrap a remaining selected context
   from the cache created by that ceremony. Admit only fixed `auth.json` leaves
   in the already reviewed component homes. Stage only inside a helper-owned private directory in the same bounded
   helper root, then use descriptor-relative, no-follow access; validate owner, group, private modes, regular file, single link,
   bounded bytes and unchanged source identity. Never overwrite an existing
   destination. Publish atomically with the destination's exact account ownership, then verify
   exact bytes and stable descriptor/leaf metadata before acknowledgment.
5. Require independent actual Codex status/readback for every selected target.
   One target's success is never the other target's success. Keep the ceremony
   unresolved if any target fails or changes authority.
6. Keep cache bytes entirely inside that helper-owned route. No cache content,
   token, secret digest or one-time code in journals, stdout, diagnostics,
   tickets or release receipts. The explicitly user-requested code copy action
   remains UI-only.

This is a same-host, reviewed-installation bootstrap. It does not copy the
Mini's existing credentials to a VM, extract Keychain secrets, share component
homes, change the EP/Forge service owner, or add a Forge GitHub provider.
Standalone installation keeps one target; the later second-component route
needs independently admitted authority before any reuse.

## Required evidence before publication or use

- Explicit user approval obtained for this bounded cache-bootstrap exception; no broader credential handling is admitted.
- Protected source review and required installer tests, including hostile path,
  hardlink, ownership, partial write, duplicate ceremony and authority drift cases.
- Real selected-account Codex verification for both EP and Forge.
- Qualification of cache refresh/reuse for the isolated contexts; an initial
  login-status check alone does not prove longer-lived simultaneous use.
- Supported handling of pre-existing uncertain child effects. Do not clear or
  retire their evidence merely because this proposal adds a bootstrap route.
- No product installation or MVP PASS inferred from source tests.

# First-run installer acceptance

The next public build must be qualified against these operator requirements on a clean Mac.

## Helper access

- The installer initiates helper setup within its own installation flow.
- Use a supported macOS administrator authorization and verify the exact signed helper independently before continuing.
- The user must not have to find Login Items or manually arrange helper registration outside the installer.
- Automatically approving security settings, changing TCC data or raw helper process control is not an acceptable implementation.
- Current `SMAppService.register()` for a LaunchDaemon requires administrator approval in System Settings. Automatically opening that panel alone does not meet the requested no-manual-Login-Items route. A supported alternative installation/authorization route must be qualified before this requirement is marked complete.

Apple reference: https://developer.apple.com/documentation/servicemanagement/smappservice/register()

## Provider access

- One human Codex authentication ceremony for the selected installation.
- The installer dispatches the provider bootstrap only inside its bounded, reviewed credential route to the selected EP and Forge instances.
- Keep distinct component runtimes, owners and authentication contexts; independently verify both exact targets after dispatch.
- Do not infer Forge authentication from the EP receipt. Do not hide a second ceremony behind a single UI row.
- EP GitHub has its own one-time provider ceremony. Forge has no GitHub provider.
- No manual credential copying, caller-supplied credentials, credential contents in journals/logs or fixture-backed installation proof.
- The existing Python fanout coordinator is not evidence of released native fanout: current native authentication is keyed by operation and provider target and launches separate sessions.

## Device code usability

- The visible one-time code remains selectable.
- Provide a clearly labelled **Kopieer code** action adjacent to the code, writing only that displayed code on an explicit user click.
- Retain the official verification-page link and explicit verification after user authentication.
- The clipboard action is present in source in both GUI authentication screens and the GUI product compiles. This is not yet a published-build or live GUI qualification claim.

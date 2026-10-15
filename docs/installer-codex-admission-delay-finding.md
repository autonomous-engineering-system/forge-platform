# Open finding: slow admission before the Codex device code

ID: `L1-CODEX-ADMISSION-DELAY-20261015`  
Status: **PARTIAL_SOURCE_IMPLEMENTATION — signed click-to-code acceptance OPEN**
Scope: installer performance and truthful GUI progress; no implementation or
additional release/VM action is authorized by recording this finding.

## Actual observation

During the real GUI provider step, the screen displayed only a spinner and
“Codex verbinden…”. The user reported a long wait. A contemporaneous process
inspection showed no Codex authentication child yet. The deployment parent was
PLANNED and inventory was empty. These are observations of that instant, not a
terminal result or a claim the installation succeeded or failed.

A one-second sample of the running privileged helper showed this active path:

```text
beginReviewedProviderAuthentication
  ManagedInstallerReviewedProviderAuthenticationStart.begin
    ManagedInstallerReviewedProviderAuthenticationAdmission.admitFanoutTargets
      admitLaunchTarget -> admit
        ManagedInstallerHelperVerifiedMaterialAdmission.admit
          ManagedInstallerHelperCurrentReleaseAdmission.admitWhileLocked
            SecStaticCodeCheckValidityWithErrors
```

Repeated material/release admission along the selected EP/Forge target checks
performs full Apple code-signature validation before starting the actual provider
login. This identifies a concrete installer-side contributor to the wait; it
is not evidence of a slow OpenAI login request. The exact total duration and
per-check timings were not measured in this GUI observation.

## Required correction and acceptance evidence

- Show the real current phase, such as “Herkomst en handtekeningen controleren”,
  followed by “Codex-aanmelding voorbereiden” and “Aanmeldcode ophalen” only when
  those actions actually occur. A generic connection spinner must not conceal
  minutes of local admission work.
- Measure end-to-end click-to-code time and full-validation call count for an
  actual installed, signed CLI and GUI on the same selected product composition.
- Investigate redundant full checks within demonstrably unchanged verification
  context. Preserve required trust, signature, current-release, account and
  target checks at every security-sensitive boundary; do not bypass them or
  introduce a broadly reusable stale trust result.
- If completion cannot proceed, end the spinner with an actionable explanation;
  do not claim a new challenge exists when the helper returned none.
- Keep the same reviewed operation and single human Codex ceremony. No second
  attempt is started just because progress is slow.
- Retain before/after runtime timing and independent current-process evidence.
  Source tests or synthetic prompts alone do not close this finding.

Private evidence: real GUI screenshot and sanitized helper-stack excerpt are
retained under the LANE_1 diagnostics finding ID. No device code, credential
cache or authentication material belongs in this document or its public receipt.

Related qualification: [provider code renewal](installer-provider-code-renewal-qualification.md).
That source change does not fix or close this performance finding.

## Additional installed observation: before product execution

The same public 0.4.23 GUI installation subsequently displayed the installation
screen with 4:24 elapsed, component rows still pending and the aggregate row
running. A fresh journal read still showed PLANNED, empty inventory, no active
product worker and `uncertain=false`. The fixed ports probed at that time were
closed; those port checks cannot establish availability of dynamically allocated
product endpoints.

A contemporaneous one-second helper sample showed:

```text
FileManagedInstallerReleasedRouteXPCService.executeReviewedIntent
  ManagedInstallerHelperVerifiedMaterialAdmission.admit
    ManagedInstallerHelperCurrentReleaseAdmission.admitWhileLocked
      SecStaticCodeCheckValidityWithErrors
```

Thus the observed admission delay also occurs after the user confirms installation,
before product execution. The finding is broader than the Codex button. The
elapsed label is screen evidence of time since installation confirmation, not a
measurement that every second was spent in this one signature function. No
terminal installation result follows from this snapshot.

Acceptance must cover both provider admission and pre-product execution. Show
this phase explicitly, and measure/reduce redundant validation without removing
required security checks. The runtime path, account, binding and readiness
verification requirements remain unchanged.

## Performance investigation

Track measurement, redundant-validation analysis, bounded parallelization
candidates and dependency constraints in the
[installer performance investigation](installer-performance-investigation.md).
Status: OPEN; no optimization or concurrency change is implemented.

## 2026-10-15 source update

The GUI now describes local admission/preparation before a code exists; fixed-name
monotonic phase timings and overlapping independent sealed-resource reads are
implemented and unsigned qualified. All full signature checks remain. The separately
authorized provider-admission consolidation is now implemented and unsigned
qualified: identical initial targets, seven versus two full group reads, with
all material/currentness and physical-target drift boundaries retained. Actual signed click-to-code
latency and the complete GUI route still require new runtime evidence. See the
[qualification](installer-forge-prepairing-startup-qualification.md).

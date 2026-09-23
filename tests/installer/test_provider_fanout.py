#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.provider_fanout import (
    ProviderBootstrapHandle,
    ProviderFanoutCoordinator,
    ProviderFanoutError,
)
from forge_platform.universal_installer import (
    ProviderReadback,
    ProviderRequirement,
    SemanticVersion,
)


def req(provider: str, owner: str, target: str) -> ProviderRequirement:
    return ProviderRequirement(
        provider, True, SemanticVersion.parse("1.0.0"), "component", owner, target
    )


class Authenticator:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[str, ...]]] = []

    def authenticate(self, provider, requirements):
        self.calls.append((provider, tuple(item.key for item in requirements)))
        return ProviderBootstrapHandle(
            provider, f"ceremony-{provider}", "provider-supported-device-flow", object()
        )


class Target:
    def __init__(self, *, verified: bool = True, wrong_target: bool = False) -> None:
        self.calls = 0
        self.verified = verified
        self.wrong_target = wrong_target

    def provision_and_verify(self, requirement, bootstrap):
        self.calls += 1
        target = "wrong-target" if self.wrong_target else requirement.target_identity
        return ProviderReadback(
            requirement.identity,
            "VERIFIED" if self.verified else "AUTHENTICATION_REQUIRED",
            SemanticVersion.parse("1.1.0") if self.verified else None,
            f"executable:{requirement.key}" if self.verified else None,
            f"evidence:{requirement.key}",
            requirement.owner_component,
            target,
        )


class ProviderFanoutTests(unittest.TestCase):
    def test_one_human_codex_ceremony_fans_out_to_forge_and_ep_targets(self) -> None:
        forge = req("codex", "forge-runtime", "forge-prod")
        ep = req("codex", "engineering-platform-server", "ep-prod")
        auth = Authenticator()
        forge_target, ep_target = Target(), Target()
        receipts = ProviderFanoutCoordinator(
            authenticators={"codex": auth},
            targets={forge.key: forge_target, ep.key: ep_target},
        ).execute((forge, ep))

        self.assertEqual(len(auth.calls), 1)
        self.assertEqual(set(auth.calls[0][1]), {forge.key, ep.key})
        self.assertEqual(forge_target.calls, 1)
        self.assertEqual(ep_target.calls, 1)
        self.assertEqual(len(receipts), 1)
        self.assertEqual({item.target_key for item in receipts[0].targets}, {forge.key, ep.key})
        self.assertEqual(receipts[0].ceremony_id, "ceremony-codex")

    def test_human_ceremonies_are_grouped_by_provider_not_target(self) -> None:
        codex = req("codex", "engineering-platform-server", "ep-prod")
        github = req("github-cli", "engineering-platform-server", "ep-prod")
        codex_auth, github_auth = Authenticator(), Authenticator()
        coordinator = ProviderFanoutCoordinator(
            authenticators={"codex": codex_auth, "github-cli": github_auth},
            targets={codex.key: Target(), github.key: Target()},
        )
        receipts = coordinator.execute((codex, github))
        self.assertEqual(len(codex_auth.calls), 1)
        self.assertEqual(len(github_auth.calls), 1)
        self.assertEqual({item.provider for item in receipts}, {"codex", "github-cli"})

    def test_one_target_not_ready_blocks_whole_fanout_without_fabricating_success(self) -> None:
        forge = req("codex", "forge-runtime", "forge-prod")
        ep = req("codex", "engineering-platform-server", "ep-prod")
        with self.assertRaisesRegex(ProviderFanoutError, "did not independently verify"):
            ProviderFanoutCoordinator(
                authenticators={"codex": Authenticator()},
                targets={forge.key: Target(), ep.key: Target(verified=False)},
            ).execute((forge, ep))

    def test_mismatched_target_readback_and_missing_strategy_fail_closed(self) -> None:
        ep = req("codex", "engineering-platform-server", "ep-prod")
        with self.assertRaisesRegex(ProviderFanoutError, "mismatched"):
            ProviderFanoutCoordinator(
                authenticators={"codex": Authenticator()},
                targets={ep.key: Target(wrong_target=True)},
            ).execute((ep,))
        with self.assertRaisesRegex(ProviderFanoutError, "no supported"):
            ProviderFanoutCoordinator(authenticators={}, targets={ep.key: Target()}).execute((ep,))

    def test_targetless_legacy_requirement_cannot_enter_fanout(self) -> None:
        legacy = ProviderRequirement("codex", True, None)
        with self.assertRaisesRegex(ProviderFanoutError, "exact owning"):
            ProviderFanoutCoordinator(
                authenticators={"codex": Authenticator()},
                targets={"codex": Target()},
            ).execute((legacy,))


if __name__ == "__main__":
    unittest.main()

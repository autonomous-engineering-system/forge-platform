from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget, EngineeringPlatformSystemProvisionerAdapter,
    ProductCommandResult,
)
from forge_platform.ep_consumer_revocation import (
    EPConsumerRevocationAdapter, EPConsumerRevocationError, EPConsumerScope,
    SubprocessEPConsumerCommandRunner,
)


INSTANCE = "ep-prod01"
SOURCE = "cfce69892278ee2b6c14412c171f5f33596acb0e"
ARTIFACT = QualifiedArtifact(
    "2.3.104", SOURCE, "https://example.invalid/ep-2.3.104.whl",
    "sha256:3f7822fd081598f81d5c666200787a3b2182d7004c078cc36ec20455269909cb", "https://example.invalid/ep-release",
)


class ProvisionerRunner:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.ready = True
        self.source = SOURCE
        self.data_root = str(root / "instances" / INSTANCE / "data")
        self.inventory: list[dict[str, object]] = [self._descriptor() | {"status": "READY"}]

    def _descriptor(self):
        return {
            "instance_id": INSTANCE,
            "data_root": self.data_root,
            "service_account": "_ep_test",
            "selected_runtime": {
                "version": "2.3.104", "source_revision": self.source,
                "artifact_digest": ARTIFACT.digest,
                "interpreter": str(self.root / "runtimes" / "slot" / "bin" / "python"),
            },
        }

    def run(self, argv):
        if argv[1] == "inventory":
            if self.inventory:
                self.inventory = [self._descriptor() | {"status": "READY"}]
            return ProductCommandResult(0, json.dumps({"state": "READY", "instances": self.inventory}), "")
        self.assert_status_target(argv)
        return ProductCommandResult(0, json.dumps({
            "contract": "engineering-platform.system-provisioner/v1",
            "instance_id": INSTANCE,
            "state": "READY" if self.ready else "NOT_READY",
            "ready": self.ready,
            "descriptor": self._descriptor(),
        }), "")

    @staticmethod
    def assert_status_target(argv):
        assert argv[1] == "status"
        assert argv[-2:] == ("--instance-id", INSTANCE)


class ConsumerRunner:
    def __init__(self) -> None:
        self.status = "ACTIVE"
        self.calls: list[tuple[tuple[str, ...], Path, int, int]] = []
        self.output: object | None = None
        self.revoke_output: object | None = None
        self.returncode = 0

    def run(self, argv, *, database, uid, gid):
        self.calls.append((tuple(argv), database, uid, gid))
        if self.returncode:
            return ProductCommandResult(self.returncode, "", "secret diagnostic")
        if argv[4] == "consumer-revoke":
            if self.status != "ACTIVE":
                raise AssertionError("duplicate mutation")
            self.status = "REVOKED"
            result: object = True if self.revoke_output is None else self.revoke_output
        else:
            result = {
                "consumer_id": "consumer-A", "project_id": "project-A",
                "status": self.status, "revoked_at": "2026-09-27T00:00:00Z" if self.status == "REVOKED" else None,
                "active_production_credentials": 1,
            }
        return ProductCommandResult(0, json.dumps(self.output if self.output is not None else result), "")


class EPConsumerRevocationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "product"
        self.data = self.root / "instances" / INSTANCE / "data"
        self.data.mkdir(parents=True)
        (self.data / "epdata.sqlite").write_bytes(b"fixture-existing-database")
        self.provisioner_runner = ProvisionerRunner(self.root)
        self.provisioner = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=self.root / "bin" / "engineering-platform-system-provisioner",
            product_root=self.root,
            target=EPSystemInstanceTarget(INSTANCE, "Test", "_ep_test", 8765),
            staged_artifacts={"sha256:" + "a" * 64: self.root / "staged.whl"},
            runner=self.provisioner_runner,
        )
        self.consumer_runner = ConsumerRunner()
        account = patch(
            "forge_platform.ep_consumer_revocation.pwd.getpwnam",
            return_value=SimpleNamespace(pw_uid=max(1, os.getuid()), pw_gid=os.getgid()),
        )
        account.start()
        self.addCleanup(account.stop)
        self.adapter = EPConsumerRevocationAdapter(
            provisioner=self.provisioner,
            scope=EPConsumerScope("consumer-A", "project-A"),
            expected_artifact=ARTIFACT,
            runner=self.consumer_runner,
            expected_owner_uid=os.getuid(),
        )

    def test_exact_revoke_and_idempotent_repeat(self) -> None:
        first = self.adapter.revoke()
        self.assertRegex(first, r"^ep-consumer-revoke:sha256:[0-9a-f]{64}$")
        self.assertEqual(first, self.adapter.revoke())
        self.assertEqual(sum("consumer-revoke" in call[0] for call in self.consumer_runner.calls), 1)
        for argv, database, uid, gid in self.consumer_runner.calls:
            self.assertEqual(argv[:4], (
                str(self.root / "runtimes/slot/bin/python"), "-I", "-m",
                "engineering_platform.ep_consumer_credentials",
            ))
            self.assertEqual(argv[-4:], ("--consumer-id", "consumer-A", "--project-id", "project-A"))
            self.assertEqual(database, self.data / "epdata.sqlite")
            self.assertGreater(uid, 0)
            self.assertEqual(gid, os.getgid())

    def test_wrong_product_root_and_runtime_fail_before_mutation(self) -> None:
        for change in (
            lambda: setattr(self.provisioner_runner, "data_root", "/other/data"),
            lambda: setattr(self.provisioner_runner, "source", "a" * 40),
            lambda: setattr(self.provisioner_runner, "ready", False),
            lambda: setattr(self.provisioner_runner, "inventory", []),
        ):
            with self.subTest(change=change):
                old = (self.provisioner_runner.data_root, self.provisioner_runner.source,
                       self.provisioner_runner.ready, self.provisioner_runner.inventory)
                change()
                with self.assertRaises(EPConsumerRevocationError):
                    self.adapter.revoke()
                (self.provisioner_runner.data_root, self.provisioner_runner.source,
                 self.provisioner_runner.ready, self.provisioner_runner.inventory) = old
        self.assertEqual(self.consumer_runner.calls, [])

    def test_missing_or_unsafe_database_fails_before_mutation(self) -> None:
        database = self.data / "epdata.sqlite"
        database.unlink()
        with self.assertRaises(EPConsumerRevocationError):
            self.adapter.revoke()
        database.symlink_to(self.root / "other.sqlite")
        with self.assertRaises(EPConsumerRevocationError):
            self.adapter.revoke()
        self.assertEqual(self.consumer_runner.calls, [])

    def test_writable_product_topology_fails_before_mutation(self) -> None:
        instances = self.root / "instances"
        instances.chmod(0o777)
        self.addCleanup(instances.chmod, 0o755)
        with self.assertRaises(EPConsumerRevocationError):
            self.adapter.revoke()
        self.assertEqual(self.consumer_runner.calls, [])

    def test_scope_mismatch_error_or_false_receipt_fails_closed(self) -> None:
        self.consumer_runner.output = {
            "consumer_id": "consumer-B", "project_id": "project-A",
            "status": "ACTIVE", "active_production_credentials": 0,
        }
        with self.assertRaises(EPConsumerRevocationError):
            self.adapter.revoke()
        self.consumer_runner.output = None
        self.consumer_runner.returncode = 2
        with self.assertRaisesRegex(EPConsumerRevocationError, "failed") as failure:
            self.adapter.revoke()
        self.assertNotIn("secret diagnostic", str(failure.exception))
        self.consumer_runner.returncode = 0
        self.consumer_runner.revoke_output = False
        with self.assertRaises(EPConsumerRevocationError):
            self.adapter.revoke()

    def test_terminal_readback_must_remain_revoked(self) -> None:
        self.consumer_runner.revoke_output = True
        original = self.consumer_runner.run

        def stale(argv, **kwargs):
            result = original(argv, **kwargs)
            if argv[4] == "consumer-revoke":
                self.consumer_runner.status = "ACTIVE"
            return result

        self.consumer_runner.run = stale
        with self.assertRaisesRegex(EPConsumerRevocationError, "terminal"):
            self.adapter.revoke()

    def test_wrong_artifact_and_missing_service_account_fail_closed(self) -> None:
        for artifact in (
            QualifiedArtifact(
                "2.3.101", SOURCE, ARTIFACT.source, ARTIFACT.digest,
                ARTIFACT.qualification,
            ),
            QualifiedArtifact(
                "2.3.103", SOURCE, ARTIFACT.source, ARTIFACT.digest,
                ARTIFACT.qualification,
            ),
            QualifiedArtifact(
                ARTIFACT.version, SOURCE, ARTIFACT.source, "sha256:" + "0" * 64,
                ARTIFACT.qualification,
            ),
        ):
            with self.subTest(artifact=artifact), self.assertRaises(ValueError):
                EPConsumerRevocationAdapter(
                    provisioner=self.provisioner,
                    scope=EPConsumerScope("consumer-A", "project-A"),
                    expected_artifact=artifact,
                )
        with patch("forge_platform.ep_consumer_revocation.pwd.getpwnam", side_effect=KeyError):
            with self.assertRaises(EPConsumerRevocationError):
                self.adapter.revoke()

    def test_runner_pins_environment_and_drops_root(self) -> None:
        with patch("forge_platform.ep_consumer_revocation.subprocess.run") as run:
            run.return_value = SimpleNamespace(returncode=0, stdout="{}", stderr="")
            result = SubprocessEPConsumerCommandRunner().run(
                ("/ep/bin/python", "-I"), database=self.data / "epdata.sqlite",
                uid=501, gid=20,
            )
        self.assertEqual(result.returncode, 0)
        arguments = run.call_args.kwargs
        self.assertEqual(arguments["user"], 501)
        self.assertEqual(arguments["group"], 20)
        self.assertEqual(arguments["extra_groups"], ())
        self.assertEqual(arguments["env"]["EP_CENTRAL_OPERATIONAL_DATABASE"], str(self.data / "epdata.sqlite"))
        self.assertNotIn("HOME", arguments["env"])

    def test_invalid_scope_and_root_service_identity_fail(self) -> None:
        with self.assertRaises(ValueError):
            EPConsumerScope("", "project-A")
        with patch("forge_platform.ep_consumer_revocation.pwd.getpwnam", return_value=SimpleNamespace(pw_uid=0, pw_gid=0)):
            with self.assertRaises(EPConsumerRevocationError):
                self.adapter.revoke()


if __name__ == "__main__":
    unittest.main()

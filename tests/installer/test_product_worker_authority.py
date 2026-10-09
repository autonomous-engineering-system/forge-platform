#!/usr/bin/env python3
from __future__ import annotations

from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService,
)
from forge_platform.product_worker_authority import (
    PRODUCT_WORKER_AUTHORITY_FILE,
    PRODUCT_WORKER_AUTHORITY_SCHEMA,
    PRODUCT_WORKER_SINGLE_AUTHORITY_SCHEMA,
    PRODUCT_WORKER_SLOT_AUTHORITY_SCHEMA,
    ProductWorkerAuthorityError,
    ProductWorkerAuthorityLoader,
)
from tests.installer.test_managed_product_operation_admission import installer_release
from tests.installer.test_universal_installer import manifest_payload


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _manifest_payload() -> dict:
    payload = manifest_payload(composition_id="forge-ep-current")
    ep = payload["components"][0]
    ep["artifact"]["version"] = "2.3.106"
    ep["artifact"]["source_revision"] = "7b99b578153ae5d72372a09db194306b49ec9f9c"
    ep["artifact"]["digest"] = "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694"
    ep["artifact"]["source"] = "https://registry.example.invalid/engineering-platform-2.3.106.whl"
    ep["artifact"]["qualification"] = "https://evidence.example.invalid/ep-2.3.106"
    forge = json.loads(json.dumps(ep))
    forge["identity"] = "forge-runtime"
    forge["artifact"] = {
        "version": "2.7.37",
        "source_revision": "a78523603d6ea081d07875ea6b557e73b5d4fe63",
        "source": "https://registry.example.invalid/forge-runtime.whl",
        "digest": "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
        "qualification": "https://evidence.example.invalid/forge-runtime",
    }
    forge["service"]["product_service_reference"] = "forge-server-service-v1"
    payload["components"].append(forge)
    payload["product_venvs"].append({
        "component_identity": "forge-runtime",
        "venv_identity": "forge-runtime-primary",
        "python_runtime_identity": payload["python_runtime"]["identity_digest"],
    })
    return payload


def _authority() -> dict:
    manifest = _manifest_payload()
    release = installer_release()
    return {
        "schema": PRODUCT_WORKER_AUTHORITY_SCHEMA,
        "installer_release": {
            "version": release.version,
            "release_page": release.release_page,
            "asset_name": release.asset_name,
            "sha256": release.sha256,
            "signing_key_id": release.signing_key_id,
        },
        "candidate_manifests": [{
            "digest": "sha256:" + sha256(_canonical(manifest)).hexdigest(),
            "payload": manifest,
        }],
        "installed_manifests": [],
        "routes": [{
            "deployment_id": "production",
            "forge_instance_id": "forge-prod",
            "forge_installation_id": "forge-installation-prod",
            "forge_service_account": "_forge_prod",
            "forge_bind_port": 8875,
            "forge_artifact_sha256": "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
            "ep_artifact_sha256": "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694",
            "ep_instance_id": "ep-prod",
            "ep_display_label": "Production",
            "ep_service_account": "_ep_prod",
            "ep_bind_port": 8876,
            "pairing": {
                "binding_id": "ep-primary",
                "consumer_id": "forge-consumer",
                "host_id": "engineering-platform",
                "project_id": "forge-project",
                "repository_id": "forge-repository",
                "repository_identity": "pcvantol:forge",
                "credential_reference": "keychain://forge.ep/consumer",
                "operator_id": "installer",
            },
        }],
    }


def _single_authority(component: str) -> dict:
    payload = _authority()
    payload["schema"] = PRODUCT_WORKER_SINGLE_AUTHORITY_SCHEMA
    manifest = payload["candidate_manifests"][0]["payload"]
    manifest["composition_id"] = (
        "forge-only-current" if component == "forge-runtime" else "ep-only-current"
    )
    manifest["components"] = [
        item for item in manifest["components"] if item["identity"] == component
    ]
    manifest["product_venvs"] = [
        item for item in manifest["product_venvs"]
        if item["component_identity"] == component
    ]
    payload["candidate_manifests"][0]["digest"] = (
        "sha256:" + sha256(_canonical(manifest)).hexdigest()
    )
    payload["routes"] = []
    forge = component == "forge-runtime"
    payload["single_routes"] = [{
        "deployment_id": "production",
        "component_identity": component,
        "instance_id": "forge-prod" if forge else "ep-prod",
        "service_account": "_forge_prod" if forge else "_ep_prod",
        "bind_port": 8875 if forge else 8876,
        "artifact_sha256": (
            "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938"
            if forge else
            "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694"
        ),
        "forge_installation_id": "forge-installation-prod" if forge else None,
        "ep_display_label": None if forge else "Production",
    }]
    return payload


class ProductWorkerAuthorityLoaderTests(unittest.TestCase):
    def installation_authority(self):
        value=_authority(); value['schema']='forge-platform.product-worker-authority/v7'
        manifest=value['candidate_manifests'][0]['payload']
        for c in manifest['components']:
            if c['identity']=='forge-runtime':
                c['artifact'].update(version='2.8.1',source_revision='c8833ffa4754800de451cce94b109ef1ad07123f',
                    digest='sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0')
            else:
                c['artifact'].update(version='2.3.113',source_revision='9318636060706534635954e9131e42e2f63928ef',
                    digest='sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e')
        value['candidate_manifests'][0]['digest']='sha256:'+sha256(_canonical(manifest)).hexdigest()
        route=value['routes'][0];route.pop('pairing')
        route.update(forge_service_account='operator-admin',forge_service_user_identity_sha256='sha256:'+'1'*64,
            forge_artifact_sha256='sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0',
            ep_artifact_sha256='sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e',
            forge_venv_slot='venv-'+'2'*64,ep_venv_slot='venv-'+'3'*64,
            installation_pairing=dict(operation_id='installation-op',binding_id='installation-binding',
                consumer_id='installation-consumer',credential_reference='keychain://installation/new'))
        value['installation_routes']=[route];value['routes']=[];value['single_routes']=[]
        return value

    def installation_loader(self):
        return ProductWorkerAuthorityLoader(root=self.root,expected_owner_uid=os.getuid(),
            worker_path=Path('/Applications/ForgePlatformInstallerDebug.app/Contents/Resources/forge-platform-product-worker.pyz'))

    def test_v7_constructs_concrete_installation_service_without_project_revoker(self):
        self.write(self.installation_authority())
        with patch('forge_platform.product_worker_authority.resolve_identity_sha256',return_value='sha256:'+'1'*64):
            service=self.installation_loader().load()
        self.assertIsInstance(service,ManagedProductOperationHelperService)
        self.assertIsNone(service.preserved_dispatcher)
        self.assertEqual(dict(service.repair_route_configurations),{})

    def test_v7_denies_legacy_fields_unqualified_release_and_identity_drift(self):
        for key,value in (('pairing',{}),('project_id','forbidden'),
                          ('forge_artifact_sha256','sha256:'+'0'*64)):
            payload=self.installation_authority();payload['installation_routes'][0][key]=value;self.write(payload)
            with patch('forge_platform.product_worker_authority.resolve_identity_sha256',return_value='sha256:'+'1'*64):
                with self.assertRaises((ProductWorkerAuthorityError,ValueError)):self.installation_loader().load()
        self.write(self.installation_authority())
        with patch('forge_platform.product_worker_authority.resolve_identity_sha256',return_value='sha256:'+'f'*64):
            with self.assertRaises(ProductWorkerAuthorityError):self.installation_loader().load()

    def test_v7_denies_mixed_routes_shared_claims_or_missing_native_store(self):
        payload=self.installation_authority();payload['routes']=_authority()['routes'];self.write(payload)
        with self.assertRaises(ProductWorkerAuthorityError):self.installation_loader().load()
        payload=self.installation_authority();payload['installation_routes']*=2;self.write(payload)
        with self.assertRaises(ProductWorkerAuthorityError):self.installation_loader().load()
        self.write(self.installation_authority())
        with patch('forge_platform.product_worker_authority.resolve_identity_sha256',return_value='sha256:'+'1'*64):
            with self.assertRaises(TypeError):self.loader().load()

    def test_exact_238_to_239_route_gets_request_bound_helper_provider(self) -> None:
        old = _manifest_payload()
        new = json.loads(json.dumps(old))
        new["composition_id"] = "forge-ep-next"
        old_forge = next(item for item in old["components"] if item["identity"] == "forge-runtime")
        new_forge = next(item for item in new["components"] if item["identity"] == "forge-runtime")
        old_forge["artifact"].update({
            "version": "2.7.38",
            "source_revision": "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
            "digest": "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
        })
        new_forge["artifact"].update({
            "version": "2.7.39",
            "source_revision": "ebc43dc12da27353f85c991a26da9852aa790f05",
            "digest": "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
        })
        payload = _authority()
        payload["candidate_manifests"] = [{
            "digest": "sha256:" + sha256(_canonical(new)).hexdigest(), "payload": new,
        }]
        payload["installed_manifests"] = [{
            "digest": "sha256:" + sha256(_canonical(old)).hexdigest(), "payload": old,
        }]
        payload["routes"][0]["forge_artifact_sha256"] = old_forge["artifact"]["digest"]
        self.write(payload)
        worker = self.root / "Signed.app/Contents/Resources/forge-platform-product-worker.pyz"
        python = self.root / "managed-python-runtime-slots/slot/bin/python3"
        loader = ProductWorkerAuthorityLoader(
            root=self.root, expected_owner_uid=self.owner,
            launch_daemons_directory=self.launchd,
            worker_path=worker, base_python=python,
        )
        service = loader.load()
        from forge_platform.managed_system_keychain_store import ManagedSystemKeychainCredentialStore
        self.assertIsInstance(
            service.dispatcher.coordinator.secure_store,
            ManagedSystemKeychainCredentialStore,
        )
        forge = service.dispatcher.resolver._routes["production"].adapters["forge-runtime"]
        provider = forge.update_binding_provider
        self.assertIsNotNone(provider)
        self.assertEqual(provider.target.instance_id, "forge-prod")
        self.assertEqual(provider.installation_id, "forge-installation-prod")
        self.assertEqual(provider.expected_pairing_binding_id, "ep-primary")
        self.assertEqual(provider.expected_ep_consumer_id, "forge-consumer")
        self.assertEqual(provider.worker, worker)
        self.assertIsNone(self.loader().load().dispatcher.resolver._routes[
            "production"
        ].adapters["forge-runtime"].update_binding_provider)

    def test_single_forge_update_provider_has_no_pairing_authority(self) -> None:
        payload = _single_authority("forge-runtime")
        old = payload["candidate_manifests"][0]["payload"]
        old_forge = old["components"][0]["artifact"]
        old_forge.update({
            "version": "2.7.38",
            "source_revision": "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
            "digest": "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
        })
        new = json.loads(json.dumps(old))
        new["composition_id"] = "forge-only-next"
        new["components"][0]["artifact"].update({
            "version": "2.7.39",
            "source_revision": "ebc43dc12da27353f85c991a26da9852aa790f05",
            "digest": "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
        })
        payload["installed_manifests"] = [{
            "digest": "sha256:" + sha256(_canonical(old)).hexdigest(), "payload": old,
        }]
        payload["candidate_manifests"] = [{
            "digest": "sha256:" + sha256(_canonical(new)).hexdigest(), "payload": new,
        }]
        payload["single_routes"][0]["artifact_sha256"] = old_forge["digest"]
        self.write(payload)
        forge = ProductWorkerAuthorityLoader(
            root=self.root, expected_owner_uid=self.owner,
            launch_daemons_directory=self.launchd,
            worker_path=self.root / "Signed.app/Contents/Resources/forge-platform-product-worker.pyz",
            base_python=self.root / "managed-python-runtime-slots/slot/bin/python3",
        ).load().dispatcher.resolver._routes["production"].adapters["forge-runtime"]
        self.assertIsNotNone(forge.update_binding_provider)
        self.assertIsNone(forge.update_binding_provider.expected_pairing_binding_id)
        self.assertIsNone(forge.update_binding_provider.expected_ep_consumer_id)

    def test_v5_uses_helper_owned_product_venv_slots_for_pair_and_single(self) -> None:
        paired = _authority()
        paired["schema"] = PRODUCT_WORKER_SLOT_AUTHORITY_SCHEMA
        paired["single_routes"] = []
        paired["routes"][0]["forge_venv_slot"] = "venv-" + "a" * 64
        paired["routes"][0]["ep_venv_slot"] = "venv-" + "b" * 64
        self.write(paired)
        routes = self.loader().load().dispatcher.resolver._routes
        forge = routes["production"].adapters["forge-runtime"]
        ep = routes["production"].adapters["engineering-platform-server"]
        self.assertEqual(
            forge.lifecycle_executable,
            self.root / ("managed-python-product-venvs/venv-" + "a" * 64 + "/bin/forge"),
        )
        self.assertEqual(
            ep.provisioner_executable,
            self.root / ("managed-python-product-venvs/venv-" + "b" * 64
                         + "/bin/engineering-platform-system-provisioner"),
        )
        single = _single_authority("forge-runtime")
        single["schema"] = PRODUCT_WORKER_SLOT_AUTHORITY_SCHEMA
        single["single_routes"][0]["venv_slot"] = "venv-" + "c" * 64
        self.write(single)
        forge = self.loader().load().dispatcher.resolver._routes["production"].adapters[
            "forge-runtime"
        ]
        self.assertEqual(
            forge.lifecycle_executable,
            self.root / ("managed-python-product-venvs/venv-" + "c" * 64 + "/bin/forge"),
        )

    def test_v5_rejects_missing_malformed_or_shared_slot_authority(self) -> None:
        paired = _authority()
        paired["schema"] = PRODUCT_WORKER_SLOT_AUTHORITY_SCHEMA
        paired["single_routes"] = []
        paired["routes"][0]["forge_venv_slot"] = "venv-" + "a" * 64
        paired["routes"][0]["ep_venv_slot"] = "venv-" + "b" * 64
        for field, value in (
            ("forge_venv_slot", None),
            ("forge_venv_slot", "venv-" + "A" * 64),
            ("forge_venv_slot", "../product-venvs/foreign"),
            ("ep_venv_slot", "venv-" + "a" * 64),
        ):
            payload = json.loads(json.dumps(paired))
            if value is None:
                del payload["routes"][0][field]
            else:
                payload["routes"][0][field] = value
            self.write(payload)
            with self.subTest(field=field, value=value), self.assertRaises(
                ProductWorkerAuthorityError
            ):
                self.loader().load()
        other = _single_authority("forge-runtime")
        route = other["single_routes"][0]
        route.update({
            "deployment_id": "other-deployment",
            "instance_id": "other-forge",
            "forge_installation_id": "other-installation",
            "service_account": "_other_forge",
            "bind_port": 9875,
            "venv_slot": "venv-" + "a" * 64,
        })
        paired["single_routes"] = [route]
        self.write(paired)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "reuse a managed venv slot"):
            self.loader().load()

    def test_native_v4_fixture_has_exact_python_canonical_bytes(self) -> None:
        fixture = (
            Path(__file__).resolve().parents[2]
            / "macos/ForgePlatformInstaller/Fixtures/product-worker-authority-v4.json"
        )
        raw = fixture.read_bytes()
        self.assertEqual(raw, _canonical(_single_authority("forge-runtime")))
        self.path.write_bytes(raw)
        self.path.chmod(0o600)
        service = self.loader().load()
        self.assertEqual(
            set(service.dispatcher.resolver._routes["production"].adapters),
            {"forge-runtime"},
        )

    def test_v4_loads_exact_forge_only_and_ep_only_routes(self) -> None:
        for component in ("forge-runtime", "engineering-platform-server"):
            with self.subTest(component=component):
                self.write(_single_authority(component))
                service = self.loader().load()
                route = service.dispatcher.resolver._routes["production"]
                self.assertEqual(set(route.adapters), {component})
                self.assertIsNone(route.pairing_executor)
                self.assertIsNone(route.ep_consumer_revoker)
                if component == "forge-runtime":
                    forge = route.adapters[component]
                    self.assertEqual(forge.removal_support(), "SUPPORTED")
                    self.assertEqual(
                        forge.uninstall_binding.installation_id,
                        "forge-installation-prod",
                    )
                    self.assertEqual(
                        forge.target.data_root,
                        self.root / "instances/forge/forge-prod",
                    )
                else:
                    self.assertEqual(
                        route.adapters[component].product_root,
                        self.root / "products/engineering-platform",
                    )

    def test_v4_rejects_cross_product_authority_and_unqualified_artifacts(self) -> None:
        for component, field, value in (
            ("forge-runtime", "ep_display_label", "injected"),
            ("engineering-platform-server", "forge_installation_id", "foreign"),
            ("forge-runtime", "artifact_sha256", "sha256:" + "9" * 64),
            ("forge-runtime", "service_account", "root"),
            ("forge-runtime", "bind_port", 0),
        ):
            payload = _single_authority(component)
            payload["single_routes"][0][field] = value
            self.write(payload)
            with self.subTest(component=component, field=field), self.assertRaises(
                ProductWorkerAuthorityError
            ):
                self.loader().load()
        payload = _single_authority("forge-runtime")
        payload["single_routes"][0]["executable"] = "/tmp/injected"
        self.write(payload)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "shape"):
            self.loader().load()

    def test_v4_can_bind_distinct_pair_and_single_deployments_without_shared_claims(self) -> None:
        payload = _single_authority("forge-runtime")
        paired = _authority()
        pair_route = paired["routes"][0]
        pair_route.update({
            "deployment_id": "paired",
            "forge_instance_id": "forge-paired",
            "forge_installation_id": "forge-installation-paired",
            "forge_service_account": "_forge_paired",
            "forge_bind_port": 8975,
            "ep_instance_id": "ep-paired",
            "ep_service_account": "_ep_paired",
            "ep_bind_port": 8976,
        })
        payload["candidate_manifests"].extend(paired["candidate_manifests"])
        payload["routes"] = paired["routes"]
        self.write(payload)
        service = self.loader().load()
        self.assertEqual(
            set(service.dispatcher.resolver._routes), {"production", "paired"}
        )
        pair_route["forge_service_account"] = "_forge_prod"
        self.write(payload)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "service account"):
            self.loader().load()

    def test_native_publisher_fixture_is_accepted_by_python_worker(self) -> None:
        fixture = (
            Path(__file__).resolve().parents[2]
            / "macos/ForgePlatformInstaller/Fixtures/product-worker-authority-v3.json"
        )
        raw = fixture.read_bytes()
        self.assertEqual(raw, _canonical(json.loads(raw)))
        self.path.write_bytes(raw)
        self.path.chmod(0o600)
        service = self.loader().load()
        self.assertIsInstance(service, ManagedProductOperationHelperService)
        self.assertIn("production", service.dispatcher.resolver._routes)
        forge = service.dispatcher.resolver._routes["production"].adapters[
            "forge-runtime"
        ]
        self.assertEqual(forge.removal_support(), "SUPPORTED")
        self.assertEqual(forge.uninstall_binding.installation_id, "forge-installation-prod")
        self.assertEqual(
            forge.lifecycle_executable,
            self.root / "product-venvs/production/forge/bin/forge",
        )

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve() / "helper"
        self.root.mkdir(mode=0o700)
        self.path = self.root / PRODUCT_WORKER_AUTHORITY_FILE
        self.owner = os.geteuid()
        self.launchd = self.root / "LaunchDaemons"
        self.write(_authority())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, payload: object, *, canonical: bool = True) -> None:
        raw = _canonical(payload) if canonical else json.dumps(payload, indent=2).encode()
        self.path.write_bytes(raw)
        self.path.chmod(0o600)

    def loader(self) -> ProductWorkerAuthorityLoader:
        return ProductWorkerAuthorityLoader(
            root=self.root,
            expected_owner_uid=self.owner,
            launch_daemons_directory=self.launchd,
        )

    def test_loads_closed_service_and_derives_every_path_from_fixed_root(self) -> None:
        service = self.loader().load()

        self.assertIsInstance(service, ManagedProductOperationHelperService)
        route = service.dispatcher.resolver._routes["production"]
        forge = route.adapters["forge-runtime"]
        ep = route.adapters["engineering-platform-server"]
        self.assertEqual(
            forge.forge_executable,
            self.root / "product-venvs/production/forge/bin/forge",
        )
        self.assertEqual(
            forge.target.data_root,
            self.root / "instances/forge/forge-prod",
        )
        self.assertEqual(
            forge.target.api_credential_file,
            self.root / "credentials/forge/forge-prod.token",
        )
        self.assertEqual(
            ep.provisioner_executable,
            self.root
            / "product-venvs/production/engineering-platform/bin/engineering-platform-system-provisioner",
        )
        self.assertEqual(ep.product_root, self.root / "products/engineering-platform")
        self.assertEqual(
            service.dispatcher.resolver._routes["production"].adapters[
                "engineering-platform-server"
            ].target.instance_id,
            "ep-prod",
        )
        self.assertEqual(service.dispatcher.coordinator.registry.root, self.root / "state/deployments")
        self.assertEqual(route.pairing_executor.binding.endpoint, "http://127.0.0.1:8876")
        self.assertEqual(
            set(forge.staged_artifacts),
            {
                "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
                "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694",
            },
        )

    def test_currency_guard_rechecks_exact_file_before_each_mutation(self) -> None:
        service = self.loader().load()
        guard = service.dispatcher.coordinator.currency_guard
        reference = guard.require_current(
            deployment_id="production",
            mutation="product-install",
            component="forge-runtime",
            instance_id="forge-prod",
            operation_id="operation-1",
        )
        self.assertRegex(reference, r"^currency:[0-9a-f]{64}$")

        changed = _authority()
        changed["routes"][0]["ep_display_label"] = "Changed"
        self.write(changed)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "changed before mutation"):
            guard.require_current(
                deployment_id="production",
                mutation="product-install",
                component="forge-runtime",
                instance_id="forge-prod",
                operation_id="operation-1",
            )

    def test_rejects_noncanonical_duplicate_wrong_digest_and_shape(self) -> None:
        cases = []
        legacy = _authority()
        legacy["schema"] = "forge-platform.product-worker-authority/v2"
        cases.append((_canonical(legacy), "unsupported"))
        cases.append((json.dumps(_authority(), indent=2).encode(), "canonical"))
        cases.append((b'{"schema":"x","schema":"y"}', "strict JSON"))
        wrong_digest = _authority()
        wrong_digest["candidate_manifests"][0]["digest"] = "sha256:" + "0" * 64
        cases.append((_canonical(wrong_digest), "manifest authority"))
        extra_path = _authority()
        extra_path["routes"][0]["forge_executable"] = "/tmp/forge"
        cases.append((_canonical(extra_path), "shape"))
        for raw, message in cases:
            with self.subTest(message=message):
                self.path.write_bytes(raw)
                self.path.chmod(0o600)
                with self.assertRaisesRegex(ProductWorkerAuthorityError, message):
                    self.loader().load()

    def test_rejects_unsafe_accounts_ports_artifacts_and_empty_routes(self) -> None:
        for mutate, message in (
            (lambda value: value["routes"][0].__setitem__("forge_service_account", "root"), "account"),
            (lambda value: value["routes"][0].__setitem__("ep_bind_port", 8875), "ambiguous"),
            (lambda value: value["routes"][0].__setitem__("forge_artifact_sha256", "sha256:" + "9" * 64), "manifest"),
            (lambda value: value["routes"][0].__setitem__("ep_artifact_sha256", "sha256:" + "9" * 64), "EP artifact"),
            (lambda value: value["routes"][0].__setitem__("forge_installation_id", "../other"), "installation id"),
            (lambda value: value.__setitem__("routes", []), "unavailable"),
        ):
            payload = _authority()
            mutate(payload)
            self.write(payload)
            with self.subTest(message=message), self.assertRaisesRegex(
                ProductWorkerAuthorityError, message
            ):
                self.loader().load()

    def test_rejects_cross_route_account_and_port_reuse(self) -> None:
        for field, value, message in (
            ("forge_service_account", "_forge_prod", "service account"),
            ("forge_bind_port", 8875, "bind port"),
            ("forge_installation_id", "forge-installation-prod", "installation id"),
            ("pairing.consumer_id", "forge-consumer", "consumer scope"),
            ("pairing.credential_reference", "keychain://forge.ep/consumer", "credential reference"),
        ):
            payload = _authority()
            second = json.loads(json.dumps(payload["routes"][0]))
            second.update({
                "deployment_id": "staging",
                "forge_instance_id": "forge-staging",
                "forge_installation_id": "forge-installation-staging",
                "forge_service_account": "_forge_staging",
                "forge_bind_port": 8975,
                "ep_instance_id": "ep-staging",
                "ep_service_account": "_ep_staging",
                "ep_bind_port": 8976,
            })
            second["pairing"]["binding_id"] = "ep-staging"
            second["pairing"]["consumer_id"] = "staging-consumer"
            second["pairing"]["credential_reference"] = "keychain://forge.ep/staging"
            if field.startswith("pairing."):
                second["pairing"][field.removeprefix("pairing.")] = value
            else:
                second[field] = value
            payload["routes"].append(second)
            self.write(payload)
            with self.subTest(field=field), self.assertRaisesRegex(
                ProductWorkerAuthorityError, message
            ):
                self.loader().load()

    def test_legacy_authority_cannot_authorize_forge_removal(self) -> None:
        payload = _authority()
        payload["schema"] = "forge-platform.product-worker-authority/v1"
        del payload["routes"][0]["forge_installation_id"]
        self.write(payload)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "schema is unsupported"):
            self.loader().load()

    def test_rejects_unsafe_root_file_mode_and_symlink(self) -> None:
        self.root.chmod(0o755)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "root is unsafe"):
            self.loader().load()
        self.root.chmod(0o700)
        self.path.chmod(0o644)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "file is unsafe"):
            self.loader().load()
        self.path.unlink()
        target = self.root / "target.json"
        target.write_bytes(_canonical(_authority()))
        target.chmod(0o600)
        self.path.symlink_to(target)
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "unreadable"):
            self.loader().load()

    def test_rejects_invalid_loader_configuration_and_missing_authority(self) -> None:
        for kwargs in (
            {"root": Path("relative")},
            {"root": self.root, "expected_owner_uid": -1},
            {"root": self.root, "launch_daemons_directory": Path("relative")},
        ):
            with self.assertRaises(ValueError):
                ProductWorkerAuthorityLoader(**kwargs)
        self.path.unlink()
        with self.assertRaisesRegex(ProductWorkerAuthorityError, "unreadable"):
            self.loader().load()


if __name__ == "__main__":
    unittest.main()

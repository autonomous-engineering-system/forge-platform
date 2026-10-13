"""Real protected evidence IO on isolated temporary paths; no product effects."""
import os
import json
from hashlib import sha256
from types import SimpleNamespace
from pathlib import Path
import subprocess
import tempfile
import unittest

from forge_platform.managed_ep_partial_create import _json, EPPartialCreateError, BoundEPCreateOperation


@unittest.skipUnless(os.geteuid() == 0, "isolated root-owned evidence qualification")
class ProtectedPartialCreateEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="l1-partial-evidence-", dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.path = self.root / "evidence.json"

    def tearDown(self):
        self.temp.cleanup()

    def write(self, data=b'{"state":"MANAGED_TOOLS"}'):
        self.path.write_bytes(data)
        self.path.chmod(0o600)

    def test_valid_private_evidence_is_read_without_change(self):
        self.write()
        before = self.path.stat()
        value, digest = _json(self.path)
        after = self.path.stat()
        self.assertEqual(value, {"state": "MANAGED_TOOLS"})
        self.assertEqual(len(digest), 71)
        self.assertEqual((before.st_ino, before.st_mtime_ns, before.st_ctime_ns),
                         (after.st_ino, after.st_mtime_ns, after.st_ctime_ns))

    def test_duplicate_keys_and_nonfinite_constants_are_rejected(self):
        for data in (b'{"state":1,"state":2}', b'{"state":NaN}',
                     b'{"state":Infinity}', b'{"state":-Infinity}', b'[]'):
            with self.subTest(data=data):
                self.write(data)
                with self.assertRaises(EPPartialCreateError):
                    _json(self.path)
                self.assertEqual(self.path.read_bytes(), data)

    def test_broad_permissions_and_hardlinks_are_rejected(self):
        self.write()
        self.path.chmod(0o644)
        with self.assertRaises(EPPartialCreateError):
            _json(self.path)
        self.path.chmod(0o600)
        os.link(self.path, self.root / "alias.json")
        with self.assertRaises(EPPartialCreateError):
            _json(self.path)
        self.assertEqual(self.path.stat().st_nlink, 2)

    def test_leaf_and_ancestor_symlinks_are_rejected(self):
        self.write()
        link = self.root / "link.json"
        link.symlink_to(self.path)
        with self.assertRaises(OSError):
            _json(link)
        directory = self.root / "directory-link"
        directory.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            _json(directory / self.path.name)

    def test_unknown_acl_is_rejected_and_preserved(self):
        self.write()
        subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(self.path)],
                       check=True, capture_output=True)
        before = subprocess.check_output(["/bin/ls", "-le", str(self.path)])
        with self.assertRaises(EPPartialCreateError):
            _json(self.path)
        self.assertEqual(subprocess.check_output(["/bin/ls", "-le", str(self.path)]), before)

    def test_empty_oversized_and_fifo_are_rejected_without_blocking(self):
        for data in (b'', b'{"state":"MANAGED_TOOLS"}'):
            self.write(data)
            with self.assertRaises(EPPartialCreateError):
                _json(self.path, maximum=8)
        self.path.unlink()
        os.mkfifo(self.path, 0o600)
        with self.assertRaises(EPPartialCreateError):
            _json(self.path)

    def bound_fixture(self):
        from forge_platform.managed_deployments import ManagedDeploymentRegistry
        from forge_platform.managed_product_operation_admission import admit_native_product_operation
        from tests.installer.test_managed_product_operation_dispatch import manifests
        from tests.installer.test_managed_product_operation_admission import decoded, request_payload, installer_release
        _, manifest = manifests()
        admitted = admit_native_product_operation(
            decoded(request_payload(manifest, installed=None, exists=False)),
            manifest=manifest, registry=ManagedDeploymentRegistry(self.root / "registry"),
            current_installer_release=installer_release())
        request = admitted.request
        self.assertIsNone(request.engineering_platform_instance_id)
        def identity(domain, *fields):
            return sha256(b''.join(len(s.encode()).to_bytes(8, 'big') + s.encode()
                                  for s in (domain, *fields))).hexdigest()
        instance = 'fpi-' + identity('forge-platform-product-instance/v1',
                                    request.deployment_id, 'engineering-platform-server')[:40]
        account = '_fpi_' + identity('forge-platform-service-account/v1',
                                     request.deployment_id, 'engineering-platform-server', instance)[:20]
        target = SimpleNamespace(instance_id=instance, service_account=account, display_label='Source EP', bind_port=33174)
        artifact = next(c.artifact for c in manifest.components if c.identity == 'engineering-platform-server')
        state = self.root / 'state'
        state.mkdir(mode=0o700)
        parent = state / 'active-installer-operation.json'
        parent.write_text(json.dumps({'schema': 'forge-platform.managed-python-parent-journal/v1',
            'operation_id': request.operation_id, 'session_id': request.session_id,
            'deployment_id': request.deployment_id, 'stable_plan_fingerprint': request.stable_plan_fingerprint,
            'composition_identity': request.composition_identity, 'manifest_sha256': request.manifest_sha256,
            'state': 'MANAGED_TOOLS'}))
        parent.chmod(0o600)
        before = parent.read_bytes()
        bound = BoundEPCreateOperation(helper_root=self.root, target=target, artifact=artifact, admitted=admitted)
        return bound, target, artifact, before, admitted

    def test_fresh_native_request_uses_exact_route_identity_without_installed_ids(self):
        bound, target, artifact, before, admitted = self.bound_fixture()
        instance, account = target.instance_id, target.service_account
        self.assertTrue(bound.component_operation_id.startswith('product-'))
        with self.assertRaises(EPPartialCreateError):
            BoundEPCreateOperation(helper_root=self.root,
                target=SimpleNamespace(instance_id=instance, service_account='_fpi_' + 'f' * 20),
                artifact=artifact, admitted=admitted)
        self.assertEqual(bound.parent_path.read_bytes(), before)


    def write_private(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text(json.dumps(value)); path.chmod(0o600)

    def test_pending_create_and_fresh_bootstrap_publish_exact_admission_preserving_uncertainty(self):
        from unittest.mock import patch, Mock
        import uuid
        bound, target, artifact, before, _ = self.bound_fixture()
        request = SimpleNamespace(kind='install', component='engineering-platform-server',
            operation_id=bound.component_operation_id, installation_identity=target.instance_id, artifact=artifact)
        instance = self.root/'products/engineering-platform/instances'/target.instance_id
        release = dict(version=artifact.version, artifact_digest=artifact.digest, source_revision=artifact.source_revision)
        product = dict(contract='engineering-platform.system-provisioner/v1', operation='INSTALL',
            operation_id=request.operation_id, instance_id=target.instance_id, display_label=target.display_label,
            service_account=target.service_account, bind_port=target.bind_port, release=release)
        product_path = instance/'operations'/request.operation_id/'request.json'
        self.write_private(product_path, product)
        selected = dict(release, interpreter=str(self.root/'products/engineering-platform/runtimes/slots'/artifact.digest.replace('sha256:','sha256-')/'venv/bin/python'))
        label = 'com.engineeringplatform.server.instance-'+sha256(target.instance_id.encode()).hexdigest()[:32]
        descriptor = dict(instance_id=target.instance_id, display_label=target.display_label,
            service_account=target.service_account, selected_runtime=selected, data_root=str(instance/'data'),
            endpoint=f'http://127.0.0.1:{target.bind_port}', service_label=label, desired_state='ACTIVE')
        self.write_private(instance/'instance.json', descriptor)
        worker = str(uuid.uuid4()); effects = self.root/'state/product-worker-effects.json'
        self.write_private(effects, dict(schema='forge-platform.product-worker-effects/v1', activeIDs=[worker], uncertain=True))
        frozen = effects.read_bytes(), product_path.read_bytes(), (instance/'instance.json').read_bytes()
        preparation = SimpleNamespace(_account=Mock(), uid=501, gid=20,
            account_identity=(501,20,str(uuid.uuid4())), authority_sha256='sha256:'+'a'*64)
        # OS quiescence is explicitly modeled; all bound protected IO/publication is genuine.
        with patch.object(bound, 'assert_quiescent') as quiet, patch.dict(os.environ, FORGE_PLATFORM_PRODUCT_WORKER_EFFECT_ID=worker):
            readback = bound.pending_readback(request, dict(state='OBSERVED', instances=[descriptor]))
            self.assertEqual(readback.state, 'UNHEALTHY')
            bound.before_preparation(request, preparation)
            record = self.root/'state/ep-create-recovery'/(request.operation_id+'-'+worker+'.json')
            value, _ = _json(record); self.assertEqual(value['identity_kind'], 'SELECTED_RUNTIME')
            initial = record.read_bytes(); bound.before_preparation(request, preparation)
            self.assertEqual(record.read_bytes(), initial)
            self.assertGreaterEqual(quiet.call_count, 5)
            self.write_private(instance/'instance.json', dict(descriptor, desired_state='OTHER'))
            with self.assertRaises(EPPartialCreateError): bound.before_preparation(request, preparation)
            self.write_private(instance/'instance.json', descriptor)
            # Fresh provider bootstrap binds its own immutable preparation proof.
            product_path.unlink(); bound.pending_proof = None
            bootstrap = dict(schema_version=1, instance_id=target.instance_id, display_label=target.display_label,
                service_account=target.service_account, service_label=label, state='PROVIDER_BOOTSTRAP_PENDING')
            self.write_private(instance/'provider-bootstrap.json', bootstrap)
            worker2 = str(uuid.uuid4()); self.write_private(effects, dict(schema='forge-platform.product-worker-effects/v1', activeIDs=[worker2], uncertain=True))
            with patch.dict(os.environ, FORGE_PLATFORM_PRODUCT_WORKER_EFFECT_ID=worker2):
                bound.before_preparation(request, preparation)
                v, _ = _json(record.with_name(request.operation_id+'-'+worker2+'.json'))
                self.assertEqual(v['schema'], 'forge-platform.ep-create-preparation-admission/v1')
                self.assertIsNone(v['product_request_sha256'])
            self.assertTrue(_json(effects)[0]['uncertain'])
        self.assertEqual(bound.parent_path.read_bytes(), before)
        self.assertEqual((instance/'instance.json').read_bytes(), frozen[2])


if __name__ == "__main__": unittest.main()

"""Source security checks only; no installed pairing or credential evidence."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from forge_platform.forge_ep_pairing_executor import ForgeEPInstallationPairingBinding
from forge_platform.forge_server_adapter import (
    ForgeCommandResult, ForgeServerAdapterError, ForgeServerProductAdapter,
    SubprocessForgeServiceAccountCommandRunner,
)


class InstallationPairingServiceAccountRouteTests(unittest.TestCase):
    def binding(self):
        return ForgeEPInstallationPairingBinding(
            'install-op', 'installation-binding', 'http://127.0.0.1:26685',
            'ep-instance', 'forge-consumer', 'keychain://installation/example', True)

    def test_command_contains_no_project_or_repository_authority(self):
        command = self.binding().command
        self.assertTrue(SubprocessForgeServiceAccountCommandRunner._allowed_command(command))
        for forbidden in ('--project-id', '--repository-id', '--repository-identity', '--operator-id'):
            self.assertNotIn(forbidden, command)
        self.assertFalse(hasattr(self.binding(), 'project_id'))

    def test_extra_flags_reordered_flags_and_changed_transport_are_denied(self):
        good = self.binding().command
        for bad in (good + ('--project-id', 'project'), good[:-1],
                    good + ('--allow-loopback-http',), ('server', 'start'),
                    good[:2] + ('--binding-id',) + good[3:],
                    good[:7] + ('http://attacker.invalid',) + good[8:]):
            with self.subTest(command=bad):
                self.assertFalse(SubprocessForgeServiceAccountCommandRunner._allowed_command(bad))
        self.assertTrue(SubprocessForgeServiceAccountCommandRunner._allowed_command(('execution-host', 'preflight')))

    def test_operator_route_resolves_actual_named_account_without_root_or_fixed_uid(self):
        with tempfile.TemporaryDirectory() as directory:
            target = SimpleNamespace(data_root=Path(directory), service_account='selected-admin')
            executable = Path('/qualified/forge')
            runner = SubprocessForgeServiceAccountCommandRunner(target, executable)
            account = SimpleNamespace(pw_uid=1847, pw_gid=83, pw_dir='/Users/selected-admin')
            command = (str(executable), '--data-root', directory, *self.binding().command)
            with patch('forge_platform.forge_server_adapter.os.geteuid', return_value=0), \
                 patch('forge_platform.forge_server_adapter.pwd.getpwnam', return_value=account) as lookup, \
                 patch('forge_platform.forge_server_adapter.subprocess.run',
                       return_value=SimpleNamespace(returncode=0, stdout='{}')) as process:
                runner.run(command)
                lookup.assert_called_once_with('selected-admin')
                self.assertEqual(process.call_args.kwargs['user'], 1847)
                self.assertEqual(process.call_args.kwargs['group'], 83)
                self.assertEqual(process.call_args.kwargs['extra_groups'], ())
                self.assertEqual(process.call_args.kwargs['env']['HOME'], '/Users/selected-admin')

    def test_root_account_and_wrong_data_root_fail_before_process(self):
        target = SimpleNamespace(data_root=Path('/selected'), service_account='selected-admin')
        runner = SubprocessForgeServiceAccountCommandRunner(target, Path('/qualified/forge'))
        with patch('forge_platform.forge_server_adapter.os.geteuid', return_value=0), \
             patch('forge_platform.forge_server_adapter.pwd.getpwnam',
                   return_value=SimpleNamespace(pw_uid=0, pw_gid=0, pw_dir='/var/root')), \
             patch('forge_platform.forge_server_adapter.subprocess.run') as process:
            for root in ('/selected', '/different'):
                with self.assertRaises(ForgeServerAdapterError):
                    runner.run(('/qualified/forge', '--data-root', root, 'installation-peer', 'show'))
            process.assert_not_called()

    def test_adapter_configuration_uses_operator_runner_and_rejects_unqualified_artifact(self):
        adapter = object.__new__(ForgeServerProductAdapter)
        adapter.forge_executable = Path('/qualified/forge')
        adapter.target = SimpleNamespace(data_root=Path('/selected'))
        adapter.installed_artifact = object()
        operator = SimpleNamespace(run=lambda argv: ForgeCommandResult(0, json.dumps({'status':'CONFIGURED'}), ''))
        adapter.service_account_runner = operator
        with patch('forge_platform.forge_server_adapter.qualified_forge_installation_pairing_artifact', return_value=False), \
             patch.object(operator, 'run') as command:
            with self.assertRaises(ForgeServerAdapterError):adapter.configure_installation_peer(self.binding())
            command.assert_not_called()
        with patch('forge_platform.forge_server_adapter.qualified_forge_installation_pairing_artifact', return_value=True), \
             patch.object(operator, 'run', return_value=ForgeCommandResult(0, '{"status":"CONFIGURED"}', '')) as command:
            self.assertEqual(adapter.configure_installation_peer(self.binding())['status'], 'CONFIGURED')
            self.assertEqual(command.call_args.args[0], ('/qualified/forge', '--data-root', '/selected', *self.binding().command))


class InstallationPairingExecutorTests(unittest.TestCase):
    """Source authority checks; these mocks are never installed evidence."""

    def setUp(self):
        from hashlib import sha256
        from unittest.mock import Mock
        from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
        from forge_platform.engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
        from forge_platform.managed_deployments import ManagedComponentBinding, ManagedDeployment
        from forge_platform.forge_ep_pairing_executor import ForgeEPInstallationPairingExecutor
        self.binding = ForgeEPInstallationPairingBinding(
            'install-op', 'installation-binding', 'http://127.0.0.1:26685',
            'ep-instance', 'forge-consumer', 'keychain://installation/example', True)
        self.artifact = QualifiedArtifact(
            '2.8.1', 'c8833ffa4754800de451cce94b109ef1ad07123f', 'released-wheel',
            'sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0',
            'release-complete')
        self.forge = object.__new__(ForgeServerProductAdapter)
        self.forge.target = SimpleNamespace(instance_id='forge-selector', product_runtime_id='forge-runtime-uuid')
        self.forge.installed_artifact = self.artifact
        self.ep = object.__new__(EngineeringPlatformSystemProvisionerAdapter)
        self.ep.target = SimpleNamespace(instance_id='ep-instance')
        self.ep_request = ComponentOperationRequest('ep-read', 'engineering-platform-server', 'repair',
                                                    self.artifact, 'ep-instance', 'server', {})
        self.forge_request = ComponentOperationRequest('forge-read', 'forge-runtime', 'repair',
                                                       self.artifact, 'forge-selector', 'server', {})
        self.ep_status = SimpleNamespace(state='ACTIVE', health_state='HEALTHY',
                                        selected_instance_identity='ep-instance', artifact=self.artifact.correlation,
                                        health_evidence_reference='receipt:ep-health', evidence_reference='receipt:ep')
        self.ep.readback = Mock(return_value=self.ep_status)
        document = dict(binding_id=self.binding.binding_id, endpoint=self.binding.endpoint,
                        ep_instance_id='ep-instance', forge_instance_id='forge-runtime-uuid',
                        consumer_id=self.binding.consumer_id, credential_reference=self.binding.credential_reference,
                        allow_loopback_http=True, timeout_seconds=10.0, operation_id='install-op',
                        installation_id='installation-uuid', operator_binding_version=1)
        digest = 'sha256:' + sha256(json.dumps(document,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        self.configured = dict(status='CONFIGURED', configuration=document, configuration_digest=digest, execution_ready=False)
        self.preflight = dict(status='CONNECTED', binding_id=self.binding.binding_id, ep_instance_id='ep-instance',
                              forge_instance_id='forge-runtime-uuid', consumer_id=self.binding.consumer_id,
                              contract_version='1.0', purpose='INSTALLATION_READBACK', project_authorized=False,
                              execution_ready=False, configuration_digest=digest)
        self.forge.configure_installation_peer = Mock(return_value=self.configured)
        self.forge.read_installation_peer = Mock(return_value=self.configured)
        self.forge.preflight_installation_peer = Mock(return_value=self.preflight)
        self.deployment = ManagedDeployment('deployment',1,None,(
            ManagedComponentBinding('forge-runtime','forge-selector','receipt:forge'),
            ManagedComponentBinding('engineering-platform-server','ep-instance','receipt:ep')))
        self.executor = ForgeEPInstallationPairingExecutor(self.binding)

    def pair(self, **changes):
        values=dict(operation_id='install-op',deployment=self.deployment,
                    forge_request=self.forge_request,ep_request=self.ep_request,
                    forge_adapter=self.forge,ep_adapter=self.ep)
        values.update(changes)
        return self.executor.pair(**values)

    def test_exact_runtime_binding_and_independent_readback_produce_installation_receipt(self):
        result = self.pair()
        self.assertEqual(result.forge_instance_id,'forge-selector')
        self.assertEqual(result.ep_instance_id,'ep-instance')
        self.assertIn('forge-installation-preflight:sha256:',result.forge_preflight_reference)
        self.assertEqual(self.ep.readback.call_count,2)
        self.forge.read_installation_peer.assert_called_once_with()

    def test_changed_operation_or_unhealthy_ep_prevents_configuration(self):
        from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingError
        with self.assertRaises(ForgeEPProductPairingError):self.pair(operation_id='other-operation')
        self.forge.configure_installation_peer.assert_not_called()
        self.ep_status.health_state='UNHEALTHY'
        with self.assertRaises(ForgeEPProductPairingError):self.pair()
        self.forge.configure_installation_peer.assert_not_called()

    def test_project_authority_wrong_runtime_or_changed_digest_prevents_receipt(self):
        from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingError
        for changed in (dict(project_authorized=True), dict(execution_ready=True),
                        dict(project_authorized=0), dict(forge_instance_id='forge-selector'),
                        dict(configuration_digest='sha256:'+'0'*64), dict(purpose='SUBMISSION')):
            with self.subTest(changed=changed):
                self.forge.preflight_installation_peer.return_value=dict(self.preflight,**changed)
                with self.assertRaises(ForgeEPProductPairingError):self.pair()

    def test_non_durable_configuration_cannot_produce_receipt(self):
        from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingError
        self.forge.read_installation_peer.return_value=dict(self.configured,status='NOT_CONFIGURED')
        with self.assertRaises(ForgeEPProductPairingError):self.pair()
        self.forge.preflight_installation_peer.assert_not_called()


class InstallationReadinessProfileTests(unittest.TestCase):
    def setUp(self):
        from forge_platform.component_operations import QualifiedArtifact
        self.artifact=QualifiedArtifact('2.8.1','c8833ffa4754800de451cce94b109ef1ad07123f','published-wheel',
            'sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0','release-complete')
        self.target=SimpleNamespace(product_runtime_id='actual-forge-runtime')
        self.ready=dict(contract_version='forge-server-installation-readiness/v1',instance_id='actual-forge-runtime',
            ready=True,service_ready=True,component_connected=True,project_authorized=False,execution_ready=False,
            provider={'ready':True},scheduler={'state':'IDLE'},installation_peer=dict(status='CONNECTED',
                forge_instance_id='actual-forge-runtime',purpose='INSTALLATION_READBACK',project_authorized=False,execution_ready=False))

    def test_connected_installation_is_ready_without_project_or_execution_authority(self):
        from forge_platform.forge_server_adapter import ForgeHTTPReadinessProbe
        ForgeHTTPReadinessProbe.validate_installation_readiness(self.ready,self.target)

    def test_contradictory_readiness_or_extra_authority_is_rejected(self):
        from forge_platform.forge_server_adapter import ForgeHTTPReadinessProbe
        for change in (dict(ready=1),dict(service_ready=False),dict(component_connected=False),
                       dict(project_authorized=0),dict(execution_ready=True),dict(instance_id='wrong'),
                       dict(scheduler={'state':'FAILED'}),dict(provider={'ready':False})):
            with self.subTest(change=change):
                with self.assertRaises(ForgeServerAdapterError):
                    ForgeHTTPReadinessProbe.validate_installation_readiness(dict(self.ready,**change),self.target)

    def test_http_profile_pins_release_endpoint_and_forbids_redirects(self):
        from dataclasses import replace
        from forge_platform.forge_server_adapter import ForgeHTTPReadinessProbe
        with tempfile.TemporaryDirectory() as directory:
            credential=Path(directory)/'api';credential.write_text('SOURCE_FIXTURE_API_ONLY')
            self.target.api_credential_file=credential;self.target.bind_port=32273
            probe=ForgeHTTPReadinessProbe()
            with patch.object(probe,'_response',return_value=json.dumps(self.ready).encode()) as response:
                self.assertEqual(probe.installation_readiness(self.target,self.artifact),self.ready)
                self.assertEqual(response.call_args.args[0].full_url,'http://127.0.0.1:32273/v1/readiness/installation')
                self.assertIs(response.call_args.kwargs['allow_redirects'],False)
            with patch.object(probe,'_response') as response:
                with self.assertRaises(ForgeServerAdapterError):
                    probe.installation_readiness(self.target,replace(self.artifact,version='2.7.39'))
                response.assert_not_called()

    def test_unpaired_classification_requires_actual_absent_installation_binding(self):
        adapter=object.__new__(ForgeServerProductAdapter)
        adapter.installed_artifact=self.artifact;adapter.instance_bootstrap=object()
        adapter.target=SimpleNamespace(product_runtime_id='actual-forge-runtime',service_user_identity_sha256='sha256:'+'1'*64)
        unpaired=dict(self.ready,ready=False,component_connected=False,installation_peer={'status':'NOT_READY'})
        with patch.object(adapter,'read_installation_peer',return_value={'status':'NOT_CONFIGURED','execution_ready':False}):
            self.assertTrue(adapter._awaiting_peer(unpaired))
        with patch.object(adapter,'read_installation_peer',return_value={'status':'CONFIGURED','execution_ready':False}):
            self.assertFalse(adapter._awaiting_peer(unpaired))

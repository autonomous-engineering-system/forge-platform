"""Currency-bound factory for installation-only issuance inside the real saga.

The scope is frozen only after product receipts are committed. Later terminal
readback tolerates pairing/composition revision changes but never component,
runtime, operator or credential-reference changes.
"""
from pathlib import Path
from dataclasses import replace

from .component_operations import QualifiedArtifact
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .forge_server_adapter import ForgeServerProductAdapter
from .forge_ep_pairing_executor import ForgeEPInstallationPairingBinding
from .managed_deployments import ManagedDeployment, ManagedDeploymentRegistry
from .managed_ep_credential_issuance import _deployment_fingerprint
from .managed_ep_installation_credential import (EPInstallationCredentialScope, InstallationCredentialError,
    ManagedEPInstallationCredentialCoordinator, installation_component_digest)
from .ep_installation_pairing_adapter import EPInstallationPairingProductAdapter
from .managed_system_keychain_store import ManagedSystemKeychainCredentialStore
from .qualified_ep_lifecycle import qualified_ep_installation_pairing_artifact
from .qualified_forge_lifecycle import qualified_forge_installation_pairing_artifact


class ManagedEPInstallationCredentialIssuer:
    def __init__(self, *, operations_root: Path, deployment_id: str,
                 binding: ForgeEPInstallationPairingBinding, registry: ManagedDeploymentRegistry,
                 currency_guard, forge: ForgeServerProductAdapter,
                 ep: EngineeringPlatformSystemProvisionerAdapter,
                 ep_artifact: QualifiedArtifact, store: ManagedSystemKeychainCredentialStore,
                 expected_owner_uid: int = 0):
        if (not isinstance(operations_root,Path) or not operations_root.is_absolute()
                or not isinstance(binding,ForgeEPInstallationPairingBinding)
                or not isinstance(registry,ManagedDeploymentRegistry)
                or not callable(getattr(currency_guard,'require_current',None))
                or not isinstance(forge,ForgeServerProductAdapter)
                or not isinstance(ep,EngineeringPlatformSystemProvisionerAdapter)
                or not qualified_ep_installation_pairing_artifact(ep_artifact)
                or not isinstance(store,ManagedSystemKeychainCredentialStore)
                or type(expected_owner_uid) is not int or expected_owner_uid<0):
            raise TypeError('sealed installation credential factory required')
        self.root,self.deployment_id,self.binding,self.registry,self.guard,self.forge,self.ep,self.ep_artifact,self.store,self.uid=(
            operations_root,deployment_id,binding,registry,currency_guard,forge,ep,ep_artifact,store,expected_owner_uid)

    def _scope(self,current,operation_id,fingerprint,reference):
        b=self.binding
        if (not isinstance(current,ManagedDeployment) or current.deployment_id!=self.deployment_id
                or self.registry.load(self.deployment_id)!=current
                or operation_id!=b.operation_id or fingerprint!=_deployment_fingerprint(current)
                or reference!=b.credential_reference
                or not qualified_forge_installation_pairing_artifact(self.forge.installed_artifact)
                or current.by_component.get('forge-runtime') is None
                or current.by_component.get('engineering-platform-server') is None
                or current.by_component['forge-runtime'].instance_id!=self.forge.target.instance_id
                or current.by_component['engineering-platform-server'].instance_id!=self.ep.target.instance_id
                or b.expected_ep_instance_id!=self.ep.target.instance_id):
            raise InstallationCredentialError('sealed installation credential target changed')
        return EPInstallationCredentialScope(operation_id,self.deployment_id,b.binding_id,self.forge.target.instance_id,
            self.forge.target.product_runtime_id,self.ep.target.instance_id,b.consumer_id,reference,fingerprint,
            self.forge.target.service_user_identity_sha256,installation_component_digest(current))

    def _coordinator(self,scope):
        product=EPInstallationPairingProductAdapter(provisioner=self.ep,scope=scope,
            expected_artifact=self.ep_artifact,expected_owner_uid=self.uid)
        return ManagedEPInstallationCredentialCoordinator(operations_root=self.root,registry=self.registry,
            currency_guard=self.guard,product=product,store=self.store,expected_owner_uid=self.uid)

    def ensure(self, *, operation_id, reviewed_current, reviewed_fingerprint, credential_reference):
        if not isinstance(reviewed_current,ManagedDeployment) or reviewed_current.peer_binding is not None:
            raise InstallationCredentialError('installation already paired; use terminal readback')
        scope=self._scope(reviewed_current,operation_id,reviewed_fingerprint,credential_reference)
        return self._coordinator(scope).ensure()

    def read_terminal(self, *, operation_id, deployment):
        b=self.binding
        if operation_id not in (None,b.operation_id):
            raise InstallationCredentialError('installation operation changed')
        live=self._scope(deployment,b.operation_id,_deployment_fingerprint(deployment),b.credential_reference)
        coordinator=self._coordinator(live)
        # Only read the exact operation's private journal; no search or fallback.
        record=coordinator._read(self.root/(b.operation_id+'.json'),require_scope=False)
        if record is None or record.state!='COMPLETE' or replace(record.scope,reviewed_fingerprint=live.reviewed_fingerprint)!=live:
            raise InstallationCredentialError('terminal installation receipts or authority changed')
        coordinator=self._coordinator(record.scope)
        self.guard.require_current(deployment_id=self.deployment_id,mutation='ep-installation-credential-readback',
            component='engineering-platform-server',instance_id=live.ep_instance_id,operation_id=b.operation_id)
        terminal=coordinator._terminal(record)
        if self.registry.load(self.deployment_id)!=deployment:
            raise InstallationCredentialError('installation registry changed during readback')
        return terminal

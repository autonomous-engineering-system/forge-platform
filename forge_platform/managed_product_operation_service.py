"""Closed helper service composing native request admission and product dispatch.

The XPC-facing helper supplies canonical request bytes only.  This service asks
one injected helper-owned authority resolver for the exact manifests and current
installer release, independently admits the request against the dispatcher's
same durable registry, and only then invokes the durable Forge+EP dispatcher.
No path, command, adapter, environment value, credential, or service selector is
accepted from the native caller.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from types import MappingProxyType
from typing import Iterable, Mapping, Protocol

from .managed_product_operation_admission import (
    NativeInstallerReleaseBinding,
    NativeProductOperationRequest,
    admit_native_product_operation,
    decode_native_product_operation_request,
)
from .managed_product_operation_dispatch import (
    ManagedProductOperationDispatcher,
    PinnedManagedProductRouteResolver,
    ResolvedManagedProductRoute,
)
from .managed_product_removal_admission import (
    NativeProductRemovalRequest, decode_native_product_removal_request,
)
from .managed_product_removal_proposal import (
    NativeProductRemovalReviewIntent,
    decode_native_product_removal_review_intent,
    prepare_native_product_removal_review,
)
from .managed_product_removal_dispatch import ManagedProductRemovalDispatcher
from .managed_installer import ManagedDeploymentExecutionRecord
from .managed_install_flow import ManagedForgeEPInstallationCoordinator
from .released_product_routes import (
    ReleasedManagedProductRouteBuilder,
    ReleasedManagedProductRouteConfiguration,
)
from .universal_installer import (
    CompositionManifest,
    VerifiedCompositionSelection,
    VerifiedInstallerContext,
)


MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES = 128 * 1_024
MAXIMUM_NATIVE_PRODUCT_REMOVAL_RECEIPT_BYTES = 32 * 1_024
NATIVE_PRODUCT_REMOVAL_RECEIPT_SCHEMA = "forge-platform.native-product-removal-receipt/v1"


class ManagedProductOperationServiceError(RuntimeError):
    """The helper could not authorize and complete the closed native request."""


@dataclass(frozen=True)
class ManagedProductOperationAuthorities:
    """Helper-owned authority selected for one decoded request.

    The installed manifest is absent for a fresh deployment or for a legacy
    deployment that has no durable composition provenance.  This value carries
    no adapter, executable, filesystem path, command, environment, or secret.
    """

    candidate_manifest: CompositionManifest
    current_installer_release: NativeInstallerReleaseBinding
    installed_manifest: CompositionManifest | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.candidate_manifest, CompositionManifest):
            raise TypeError("candidate composition manifest authority is required")
        if not isinstance(self.current_installer_release, NativeInstallerReleaseBinding):
            raise TypeError("current installer release authority is required")
        if self.installed_manifest is not None and not isinstance(
            self.installed_manifest, CompositionManifest
        ):
            raise TypeError("installed composition manifest authority is invalid")


class ManagedProductOperationAuthorityResolving(Protocol):
    """Resolve only helper-owned public authority for one decoded request."""

    def resolve(
        self, request: NativeProductOperationRequest
    ) -> ManagedProductOperationAuthorities: ...


class PinnedManagedProductOperationAuthorityResolver:
    """Immutable helper authority for exact already-verified manifests.

    The builder must supply typed manifests previously verified through the
    signed catalog boundary and the exact running installer release.  Native
    request values can select only an exact `(composition_id, digest)` already
    present in this snapshot; they can never introduce bytes or a locator.
    """

    def __init__(
        self,
        *,
        current_installer_release: NativeInstallerReleaseBinding,
        manifests: Iterable[CompositionManifest],
        installed_manifests: Iterable[CompositionManifest] = (),
    ) -> None:
        if not isinstance(current_installer_release, NativeInstallerReleaseBinding):
            raise TypeError("current installer release authority is required")
        values = tuple(manifests)
        if not values or any(not isinstance(value, CompositionManifest) for value in values):
            raise TypeError("verified composition manifest authorities are required")
        identities = [value.composition_id for value in values]
        digests = [value.manifest_digest for value in values]
        if len(set(identities)) != len(identities):
            raise ValueError("composition authority identities are ambiguous")
        if len(set(digests)) != len(digests):
            raise ValueError("composition authority digests are ambiguous")
        installed_values = tuple(installed_manifests)
        if any(not isinstance(value, CompositionManifest) for value in installed_values):
            raise TypeError("installed composition manifest authorities are invalid")
        all_values = tuple(dict.fromkeys(values + installed_values))
        all_identities = [value.composition_id for value in all_values]
        all_digests = [value.manifest_digest for value in all_values]
        if len(set(all_identities)) != len(all_identities):
            raise ValueError("composition authority identities are ambiguous")
        if len(set(all_digests)) != len(all_digests):
            raise ValueError("composition authority digests are ambiguous")
        self.current_installer_release = current_installer_release
        self._candidate_manifests = MappingProxyType({
            (value.composition_id, value.manifest_digest): value for value in values
        })
        self._installed_manifests = MappingProxyType({
            (value.composition_id, value.manifest_digest): value for value in all_values
        })

    def resolve(
        self, request: NativeProductOperationRequest
    ) -> ManagedProductOperationAuthorities:
        if not isinstance(request, NativeProductOperationRequest):
            raise TypeError("decoded native product request is required")
        candidate = self._candidate_manifests.get(
            (request.composition_identity, request.manifest_sha256)
        )
        if candidate is None:
            raise ManagedProductOperationServiceError(
                "candidate composition authority is unavailable"
            )
        installed: CompositionManifest | None = None
        if request.installed_composition_identity is not None:
            installed = self._installed_manifests.get((
                request.installed_composition_identity,
                request.installed_composition_manifest_sha256,
            ))
            if installed is None:
                raise ManagedProductOperationServiceError(
                    "installed composition authority is unavailable"
                )
        return ManagedProductOperationAuthorities(
            candidate,
            self.current_installer_release,
            installed,
        )

    def resolve_installed_removal(
        self, request: NativeProductRemovalRequest
    ) -> CompositionManifest:
        """Select only an already pinned installed composition for removal."""

        if not isinstance(request, NativeProductRemovalRequest):
            raise TypeError("decoded native removal request is required")
        if request.installer_release != self.current_installer_release:
            raise ManagedProductOperationServiceError(
                "installer release authority changed for removal"
            )
        installed = self._installed_manifests.get((
            request.installed_composition_identity,
            request.installed_manifest_sha256,
        ))
        if installed is None:
            raise ManagedProductOperationServiceError(
                "installed removal composition authority is unavailable"
            )
        return installed

    def resolve_installed_review(
        self, intent: NativeProductRemovalReviewIntent
    ) -> CompositionManifest:
        """Select one pinned installed composition for read-only review."""

        if not isinstance(intent, NativeProductRemovalReviewIntent):
            raise TypeError("decoded native removal review intent is required")
        if intent.installer_release != self.current_installer_release:
            raise ManagedProductOperationServiceError(
                "installer release authority changed for removal review"
            )
        installed = self._installed_manifests.get((
            intent.installed_composition_identity,
            intent.installed_manifest_sha256,
        ))
        if installed is None:
            raise ManagedProductOperationServiceError(
                "installed removal review composition authority is unavailable"
            )
        return installed


class ReleasedManagedProductOperationAuthorityLoader:
    """Load one helper snapshot only from verified released selections.

    Candidate selections must all belong to one exact current signed catalog
    under the same in-process verified installer context. Historical selections
    may authorize only an installed-manifest lookup; they never become candidate
    authority. No path, URL, bytes, request value or trust adapter enters this
    boundary.
    """

    @staticmethod
    def load(
        *,
        current_installer_context: VerifiedInstallerContext,
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
    ) -> PinnedManagedProductOperationAuthorityResolver:
        if not isinstance(current_installer_context, VerifiedInstallerContext):
            raise TypeError("verified current installer context is required")
        candidates = tuple(candidate_selections)
        installed = tuple(installed_selections)
        if not candidates or any(
            not isinstance(value, VerifiedCompositionSelection) for value in candidates
        ):
            raise TypeError("verified candidate composition selections are required")
        if any(not isinstance(value, VerifiedCompositionSelection) for value in installed):
            raise TypeError("verified installed composition selections are invalid")
        if any(
            value.installer_context is not current_installer_context
            for value in candidates + installed
        ):
            raise ValueError(
                "composition authority does not share the exact verified installer context"
            )
        current_catalog_identity = candidates[0].catalog_identity
        if any(
            value.catalog_identity != current_catalog_identity
            or value.catalog != candidates[0].catalog
            for value in candidates[1:]
        ):
            raise ValueError(
                "candidate composition authorities do not share one verified current catalog"
            )
        for value in installed:
            identity = value.catalog_identity
            if identity.scope != current_catalog_identity.scope:
                raise ValueError(
                    "installed composition authority does not share the current catalog scope"
                )
            if (
                identity.sequence > current_catalog_identity.sequence
                or (
                    identity.sequence == current_catalog_identity.sequence
                    and identity.catalog_digest != current_catalog_identity.catalog_digest
                )
            ):
                raise ValueError(
                    "installed composition authority is newer than the current catalog"
                )

        release = current_installer_context.release
        asset = release.asset_for("arm64")
        if asset is None:
            raise ValueError("verified current installer has no arm64 release asset")
        signing_key_ids = tuple(sorted(signature.key_id for signature in release.signatures))
        if not signing_key_ids:
            raise ValueError("verified current installer has no signing key identity")
        native_release = NativeInstallerReleaseBinding(
            str(release.version),
            (
                f"https://github.com/{release.github_release.repository}/releases/tag/"
                f"{release.github_release.tag}"
            ),
            asset.asset_name,
            asset.archive_digest,
            signing_key_ids[0],
        )
        return PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=native_release,
            manifests=(value.manifest for value in candidates),
            installed_manifests=(value.manifest for value in installed),
        )


class ManagedProductOperationHelperService:
    """Decode, authorize and dispatch one native product operation atomically.

    Admission and dispatch use the exact same registry object.  The dispatcher
    performs a second registry read after route resolution, closing the race
    between helper admission and the first possible product mutation.
    """

    def __init__(
        self,
        *,
        authority_resolver: ManagedProductOperationAuthorityResolving,
        dispatcher: ManagedProductOperationDispatcher,
        removal_dispatcher: ManagedProductRemovalDispatcher | None = None,
    ) -> None:
        if not callable(getattr(authority_resolver, "resolve", None)):
            raise TypeError("helper-owned authority resolver is required")
        if not isinstance(dispatcher, ManagedProductOperationDispatcher):
            raise TypeError("managed product operation dispatcher is required")
        self.authority_resolver = authority_resolver
        self.dispatcher = dispatcher
        self.removal_dispatcher = removal_dispatcher

    def execute(self, canonical_request: bytes) -> bytes:
        """Return one bounded canonical receipt or raise a generic failure."""

        try:
            request = decode_native_product_operation_request(canonical_request)
            authorities = self.authority_resolver.resolve(request)
            if not isinstance(authorities, ManagedProductOperationAuthorities):
                raise TypeError("helper authority resolver returned an invalid result")
            admitted = admit_native_product_operation(
                request,
                manifest=authorities.candidate_manifest,
                installed_manifest=authorities.installed_manifest,
                registry=self.dispatcher.coordinator.registry,
                current_installer_release=authorities.current_installer_release,
            )
            receipt = self.dispatcher.dispatch(admitted)
            response = receipt.canonical_json_bytes()
            if not response or len(response) > MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES:
                raise ValueError(
                    "native product operation receipt exceeded its bound"
                )
            return response
        except Exception as error:
            raise ManagedProductOperationServiceError(
                "native product operation was rejected"
            ) from error

    def execute_removal(self, canonical_request: bytes) -> bytes:
        """Admit and dispatch one exact removal, returning no product secret text."""

        try:
            if (
                not isinstance(self.authority_resolver, PinnedManagedProductOperationAuthorityResolver)
                or not isinstance(self.removal_dispatcher, ManagedProductRemovalDispatcher)
            ):
                raise TypeError("released removal authority is unavailable")
            request = decode_native_product_removal_request(canonical_request)
            manifest = self.authority_resolver.resolve_installed_removal(request)
            admitted = self.removal_dispatcher.admit_or_restore(
                request, installed_manifest=manifest,
            )
            record = self.removal_dispatcher.dispatch(admitted)
            if (
                not isinstance(record, ManagedDeploymentExecutionRecord)
                or record.operation_id != request.operation_id
                or record.deployment_id != request.deployment_id
                or record.expected_registry_revision != request.reviewed_revision
                or record.plan_fingerprint != "sha256:" + request.reviewed_plan_sha256
                or record.state not in {"COMPLETE", "RECOVERY_PENDING"}
            ):
                raise ValueError("removal product receipt is inconsistent")
            diffs = {diff.component: diff for diff in admitted.plan.component_diffs}
            components = {item.component: item for item in record.components}
            if len(record.components) != len(diffs) or set(components) != set(diffs) or any(
                item.instance_id != diffs[component].instance_id
                or item.action != diffs[component].action
                or item.receipt_reference is not None and (
                    not isinstance(item.receipt_reference, str)
                    or len(item.receipt_reference.encode("utf-8")) > 4096
                )
                for component, item in components.items()
            ):
                raise ValueError("removal component receipt changed")
            current = self.removal_dispatcher.coordinator.registry.load(request.deployment_id)
            if record.state == "COMPLETE":
                if request.action == "REMOVE_DEPLOYMENT":
                    if current is not None or record.registry_revision != 0:
                        raise ValueError("removed deployment remains registered")
                elif (
                    current is None or admitted.plan.desired is None
                    or current.revision != request.reviewed_revision + 1
                    or record.registry_revision != current.revision
                    or current.by_component != admitted.plan.desired.by_component
                    or current.peer_binding is not None
                    or current.composition_binding
                    != admitted.plan.desired.composition_binding
                ):
                    raise ValueError("retained EP deployment changed")
                if any(
                    item.state != ("UNCHANGED" if item.action == "NO_CHANGE" else "COMPLETE")
                    for item in components.values()
                ):
                    raise ValueError("terminal removal component is incomplete")
            elif current != admitted.reviewed_current or record.registry_revision is not None:
                raise ValueError("pending removal changed the registry")
            response = {
                "schema": NATIVE_PRODUCT_REMOVAL_RECEIPT_SCHEMA,
                "request_fingerprint": request.request_fingerprint,
                "operation_id": request.operation_id,
                "deployment_id": request.deployment_id,
                "action": request.action,
                "plan_fingerprint": record.plan_fingerprint,
                "state": record.state,
                "registry_revision": record.registry_revision,
                "components": [
                    {
                        "component": item.component,
                        "instance_id": item.instance_id,
                        "action": item.action,
                        "state": item.state,
                        "product_receipt_digest": (
                            None if item.receipt_reference is None else
                            "sha256:" + sha256(item.receipt_reference.encode("utf-8")).hexdigest()
                        ),
                    }
                    for _component, item in sorted(components.items())
                ],
            }
            raw = json.dumps(
                response, sort_keys=True, separators=(",", ":"),
                ensure_ascii=True, allow_nan=False,
            ).encode("utf-8")
            if not raw or len(raw) > MAXIMUM_NATIVE_PRODUCT_REMOVAL_RECEIPT_BYTES:
                raise ValueError("removal receipt exceeded its bound")
            return raw
        except Exception as error:
            raise ManagedProductOperationServiceError(
                "native product removal was rejected"
            ) from error

    def prepare_removal_review(self, canonical_intent: bytes) -> bytes:
        """Produce one read-only proposal from the dispatcher's exact registry."""

        try:
            if (
                not isinstance(self.authority_resolver, PinnedManagedProductOperationAuthorityResolver)
                or not isinstance(self.removal_dispatcher, ManagedProductRemovalDispatcher)
            ):
                raise TypeError("released removal review authority is unavailable")
            intent = decode_native_product_removal_review_intent(canonical_intent)
            manifest = self.authority_resolver.resolve_installed_review(intent)
            return prepare_native_product_removal_review(
                canonical_intent, installed_manifest=manifest,
                registry=self.removal_dispatcher.coordinator.registry,
                current_installer_release=self.authority_resolver.current_installer_release,
            )
        except Exception as error:
            raise ManagedProductOperationServiceError(
                "native product removal review was rejected"
            ) from error


class ManagedProductOperationHelperBuilder:
    """Compose the closed helper service from already typed helper authority.

    One builder creates the release/catalog authority resolver, immutable
    product-route resolver and dispatcher around the exact supplied coordinator.
    This prevents released wiring from accidentally giving admission and
    dispatch different registries or from substituting a caller-owned resolver.
    """

    @staticmethod
    def build_released(
        *,
        current_installer_context: VerifiedInstallerContext,
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
        coordinator: ManagedForgeEPInstallationCoordinator,
        route_configurations: Iterable[ReleasedManagedProductRouteConfiguration],
    ) -> ManagedProductOperationHelperService:
        """Construct concrete adapters and the closed helper service together."""

        candidates = tuple(candidate_selections)
        installed = tuple(installed_selections)
        routes = ReleasedManagedProductRouteBuilder.build(
            configurations=route_configurations,
            candidate_selections=candidates,
            installed_selections=installed,
        )
        return ManagedProductOperationHelperBuilder.build(
            current_installer_context=current_installer_context,
            candidate_selections=candidates,
            installed_selections=installed,
            coordinator=coordinator,
            routes=routes,
        )

    @staticmethod
    def build_pinned(
        *,
        current_installer_release: NativeInstallerReleaseBinding,
        candidate_manifests: Iterable[CompositionManifest],
        installed_manifests: Iterable[CompositionManifest] = (),
        coordinator: ManagedForgeEPInstallationCoordinator,
        route_configurations: Iterable[ReleasedManagedProductRouteConfiguration],
    ) -> ManagedProductOperationHelperService:
        """Compose a worker service from one immutable helper-owned snapshot.

        The caller is responsible for establishing the trusted filesystem and
        signed-catalog provenance of this already typed snapshot.  No request
        value, locator, command, environment or credential is accepted here.
        """

        candidates = tuple(candidate_manifests)
        installed = tuple(installed_manifests)
        routes = ReleasedManagedProductRouteBuilder.build_from_manifests(
            configurations=route_configurations,
            candidate_manifests=candidates,
            installed_manifests=installed,
        )
        authority_resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=current_installer_release,
            manifests=candidates,
            installed_manifests=installed,
        )
        return ManagedProductOperationHelperBuilder._compose(
            authority_resolver=authority_resolver,
            coordinator=coordinator,
            routes=routes,
        )

    @staticmethod
    def build(
        *,
        current_installer_context: VerifiedInstallerContext,
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
        coordinator: ManagedForgeEPInstallationCoordinator,
        routes: Mapping[str, ResolvedManagedProductRoute],
    ) -> ManagedProductOperationHelperService:
        authority_resolver = ReleasedManagedProductOperationAuthorityLoader.load(
            current_installer_context=current_installer_context,
            candidate_selections=candidate_selections,
            installed_selections=installed_selections,
        )
        return ManagedProductOperationHelperBuilder._compose(
            authority_resolver=authority_resolver,
            coordinator=coordinator,
            routes=routes,
        )

    @staticmethod
    def _compose(
        *,
        authority_resolver: PinnedManagedProductOperationAuthorityResolver,
        coordinator: ManagedForgeEPInstallationCoordinator,
        routes: Mapping[str, ResolvedManagedProductRoute],
    ) -> ManagedProductOperationHelperService:
        if not isinstance(coordinator, ManagedForgeEPInstallationCoordinator):
            raise TypeError("managed Forge+EP coordinator is required")
        if not isinstance(
            authority_resolver, PinnedManagedProductOperationAuthorityResolver
        ):
            raise TypeError("pinned product-operation authority is required")
        route_resolver = PinnedManagedProductRouteResolver(routes)
        dispatcher = ManagedProductOperationDispatcher(
            coordinator=coordinator,
            resolver=route_resolver,
        )
        removal_dispatcher = ManagedProductRemovalDispatcher(
            coordinator=coordinator,
            routes=routes,
            current_installer_release=authority_resolver.current_installer_release,
        )
        return ManagedProductOperationHelperService(
            authority_resolver=authority_resolver,
            dispatcher=dispatcher,
            removal_dispatcher=removal_dispatcher,
        )

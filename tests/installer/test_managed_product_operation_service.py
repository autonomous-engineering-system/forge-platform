#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
from unittest.mock import patch
import tempfile
import unittest

from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_product_operation_dispatch import (
    ManagedProductOperationDispatcher,
)
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationAuthorities,
    ManagedProductOperationHelperService,
    ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from tests.installer.test_managed_product_operation_admission import (
    canonical,
    decoded,
    installer_release,
    request_payload,
    stored_deployment,
)
from tests.installer.test_managed_product_operation_dispatch import (
    coordinator,
    manifests,
    route,
)


class AuthorityResolver:
    def __init__(self, result=None, error: Exception | None = None) -> None:
        self.result = result
        self.error = error
        self.requests = []

    def resolve(self, request):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return self.result


class RouteResolver:
    def __init__(self, resolved) -> None:
        self.resolved = resolved
        self.requests = []

    def resolve(self, admitted):
        self.requests.append(admitted)
        return self.resolved


class ManagedProductOperationHelperServiceTests(unittest.TestCase):
    def test_pinned_authority_resolver_selects_only_exact_verified_manifests(self) -> None:
        installed, candidate = manifests()
        values = [installed, candidate]
        resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=installer_release(),
            manifests=values,
        )
        values.clear()
        fresh = decoded(request_payload(candidate, installed=None, exists=False))
        existing = decoded(request_payload(candidate, installed=installed))

        fresh_authority = resolver.resolve(fresh)
        existing_authority = resolver.resolve(existing)

        self.assertIs(fresh_authority.candidate_manifest, candidate)
        self.assertIsNone(fresh_authority.installed_manifest)
        self.assertIs(existing_authority.candidate_manifest, candidate)
        self.assertIs(existing_authority.installed_manifest, installed)
        self.assertEqual(
            existing_authority.current_installer_release,
            installer_release(),
        )

    def test_pinned_authority_resolver_rejects_unknown_or_cross_bound_identity(self) -> None:
        installed, candidate = manifests()
        resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=installer_release(),
            manifests=(installed, candidate),
        )
        request = decoded(request_payload(candidate, installed=installed))

        for changed in (
            replace(request, manifest_sha256="sha256:" + "0" * 64),
            replace(
                request,
                installed_composition_manifest_sha256="sha256:" + "0" * 64,
            ),
        ):
            with self.subTest(changed=changed), self.assertRaises(
                ManagedProductOperationServiceError
            ):
                resolver.resolve(changed)
        with self.assertRaises(TypeError):
            resolver.resolve(object())

    def test_pinned_authority_snapshot_rejects_invalid_or_ambiguous_inputs(self) -> None:
        installed, candidate = manifests()
        release = installer_release()
        with self.assertRaises(TypeError):
            PinnedManagedProductOperationAuthorityResolver(
                current_installer_release=object(), manifests=(candidate,)
            )
        for values in ((), (object(),)):
            with self.subTest(values=values), self.assertRaises(TypeError):
                PinnedManagedProductOperationAuthorityResolver(
                    current_installer_release=release,
                    manifests=values,
                )
        same_identity = replace(
            candidate,
            manifest_digest="sha256:" + "0" * 64,
        )
        same_digest = replace(
            installed,
            manifest_digest=candidate.manifest_digest,
        )
        for values, message in (
            ((candidate, same_identity), "identities"),
            ((candidate, same_digest), "digests"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(
                ValueError, message
            ):
                PinnedManagedProductOperationAuthorityResolver(
                    current_installer_release=release,
                    manifests=values,
                )

    def fixture(self, root: Path, *, authorities, resolved=None):
        registry = ManagedDeploymentRegistry(root / "registry")
        route_resolver = RouteResolver(resolved or route())
        dispatcher = ManagedProductOperationDispatcher(
            coordinator=coordinator(root, registry),
            resolver=route_resolver,
        )
        authority_resolver = AuthorityResolver(authorities)
        service = ManagedProductOperationHelperService(
            authority_resolver=authority_resolver,
            dispatcher=dispatcher,
        )
        return service, registry, authority_resolver, route_resolver

    def test_canonical_fresh_request_runs_admission_and_dispatch_once(self) -> None:
        _installed, candidate = manifests()
        authorities = ManagedProductOperationAuthorities(
            candidate,
            installer_release(),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            service, registry, authority, routes = self.fixture(
                root, authorities=authorities
            )
            request = decoded(request_payload(candidate, installed=None, exists=False))

            response = service.execute(canonical(
                request_payload(candidate, installed=None, exists=False)
            ))

            payload = json.loads(response)
            self.assertEqual(payload["request_fingerprint"], request.request_fingerprint)
            self.assertEqual(payload["operation_id"], request.operation_id)
            self.assertEqual(
                response,
                json.dumps(
                    payload,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                    allow_nan=False,
                ).encode("utf-8"),
            )
            self.assertEqual(authority.requests, [request])
            self.assertEqual(len(routes.requests), 1)
            stored = registry.load(request.deployment_id)
            self.assertEqual(stored.composition_binding.composition_id, candidate.composition_id)

    def test_existing_request_uses_exact_installed_manifest_authority(self) -> None:
        installed, candidate = manifests()
        authorities = ManagedProductOperationAuthorities(
            candidate,
            installer_release(),
            installed,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            service, registry, _authority, routes = self.fixture(
                root, authorities=authorities,
                resolved=route(forge="forge-prod", ep="ep-prod"),
            )
            registry.create(stored_deployment(installed))
            request = request_payload(candidate, installed=installed)

            with self.assertRaises(ManagedProductOperationServiceError):
                service.execute(canonical(request))

            self.assertEqual(len(routes.requests), 1)

    def test_invalid_or_noncanonical_request_never_reaches_helper_authorities(self) -> None:
        _installed, candidate = manifests()
        authorities = ManagedProductOperationAuthorities(candidate, installer_release())
        with tempfile.TemporaryDirectory() as directory:
            service, _registry, authority, routes = self.fixture(
                Path(directory).resolve(), authorities=authorities
            )
            valid = canonical(request_payload(candidate, installed=None, exists=False))
            inputs = (b"{}", b" " + valid)

            for value in inputs:
                with self.subTest(value=value[:8]), self.assertRaisesRegex(
                    ManagedProductOperationServiceError, "rejected"
                ):
                    service.execute(value)

            self.assertEqual(authority.requests, [])
            self.assertEqual(routes.requests, [])

    def test_untyped_or_mismatched_authority_fails_before_route_resolution(self) -> None:
        _installed, candidate = manifests()
        current = installer_release()
        wrong_release = replace(current, version="9.9.9")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            valid = canonical(request_payload(candidate, installed=None, exists=False))
            cases = (
                object(),
                ManagedProductOperationAuthorities(candidate, wrong_release),
            )
            for index, authorities in enumerate(cases):
                with self.subTest(index=index):
                    service, _registry, resolver, routes = self.fixture(
                        root / str(index), authorities=authorities
                    )
                    with self.assertRaises(ManagedProductOperationServiceError):
                        service.execute(valid)
                    self.assertEqual(len(resolver.requests), 1)
                    self.assertEqual(routes.requests, [])

    def test_resolver_and_dispatch_failures_are_sanitized(self) -> None:
        _installed, candidate = manifests()
        valid = canonical(request_payload(candidate, installed=None, exists=False))
        authorities = ManagedProductOperationAuthorities(candidate, installer_release())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            service, _registry, _resolver, _routes = self.fixture(
                root / "pending",
                authorities=authorities,
                resolved=route(pending_ep=True),
            )
            with self.assertRaisesRegex(
                ManagedProductOperationServiceError, "native product operation was rejected"
            ) as dispatch_error:
                service.execute(valid)
            self.assertNotIn("RECOVERY_PENDING", str(dispatch_error.exception))

            registry = ManagedDeploymentRegistry(root / "resolver-registry")
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root / "resolver", registry),
                resolver=RouteResolver(route()),
            )
            failing = ManagedProductOperationHelperService(
                authority_resolver=AuthorityResolver(
                    error=RuntimeError("secret=must-not-escape")
                ),
                dispatcher=dispatcher,
            )
            with self.assertRaises(ManagedProductOperationServiceError) as resolver_error:
                failing.execute(valid)
            self.assertNotIn("secret", str(resolver_error.exception))

    def test_receipt_bound_and_construction_fail_closed(self) -> None:
        _installed, candidate = manifests()
        authorities = ManagedProductOperationAuthorities(candidate, installer_release())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            service, registry, resolver, _routes = self.fixture(
                root, authorities=authorities
            )
            valid = canonical(request_payload(candidate, installed=None, exists=False))
            with patch(
                "forge_platform.managed_product_operation_service."
                "MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES",
                1,
            ):
                with self.assertRaises(ManagedProductOperationServiceError):
                    service.execute(valid)
            self.assertIsNotNone(registry.load("production"))
            self.assertEqual(len(resolver.requests), 1)

        with self.assertRaises(TypeError):
            ManagedProductOperationAuthorities(object(), installer_release())
        with self.assertRaises(TypeError):
            ManagedProductOperationAuthorities(candidate, object())
        with self.assertRaises(TypeError):
            ManagedProductOperationAuthorities(candidate, installer_release(), object())
        with self.assertRaises(TypeError):
            ManagedProductOperationHelperService(
                authority_resolver=object(), dispatcher=object()
            )
        with self.assertRaises(TypeError):
            ManagedProductOperationHelperService(
                authority_resolver=AuthorityResolver(authorities), dispatcher=object()
            )


if __name__ == "__main__":
    unittest.main()

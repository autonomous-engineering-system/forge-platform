"""Source-only closed-wire checks, not a signed executor or installed permit."""
from dataclasses import replace
from hashlib import sha256
import json
import unittest
from uuid import uuid4

from forge_platform.managed_historical_execution_evidence import (
    HistoricalExecutionEvidenceError, HistoricalExecutionExpectedBinding,
    ROLES, SCHEMA, decode_historical_execution_evidence,
)
from forge_platform.managed_product_operation_admission import (
    AdmittedNativeProductOperation, decode_native_product_operation_request,
)
from tests.installer.test_managed_product_operation_admission import composition_manifest, request_payload


def canonical(v):
    return json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def digest(c): return "sha256:" + c * 64


def fixture():
    manifest = composition_manifest(composition_id="forge-ep-managed-v1", forge_version="2.8.1", forge_digest=digest("7"), ep_version="2.3.113", ep_digest=digest("8"))
    payload = request_payload(manifest, installed=None, exists=False)
    request = decode_native_product_operation_request(canonical(payload))
    current = {"version": "1.2.4", "release_page": "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/v1.2.4", "asset_name": "ForgePlatformInstaller-1.2.4-arm64.zip", "sha256": digest("5"), "signing_key_id": request.installer_release.signing_key_id, "sequence": 1, "source_revision": "a" * 40, "release_trust_sha256": digest("a"), "code_directory_sha256": digest("b"), "team_identifier": "ZEML4LPXH4"}
    expected = HistoricalExecutionExpectedBinding(request, {r: digest("c") for r in ROLES}, digest("d"), digest("e"), digest("a"), current, str(uuid4()), str(uuid4()), digest("f"), digest("0"))
    ep = "product-" + sha256((request.request_fingerprint + "\x1fengineering-platform-server\x1fmutation").encode()).hexdigest()
    forge = "product-" + sha256((request.request_fingerprint + "\x1fforge-runtime\x1fmutation").encode()).hexdigest()
    inspection = {"schema": "forge-platform.historical-inspection-binding/v1", "state": "INSPECTED", "execution_authorized": False, "scope": "original-dual-create-and-installation-pairing", "original_request": payload, "original_ep_operation_id": ep, "original_descriptor_sha256": expected.descriptor_sha256, "original_operator_identity_sha256": expected.operator_sha256, "protected_sha256_by_role": dict(expected.protected_sha256_by_role), "current_executor": current, "preserve_original_journals": True, "preserve_historical_uncertainty": True}
    value = {"schema": SCHEMA, "state": "RESERVED", "execution_authorized": True, "inspection": inspection, "inspection_sha256": "sha256:" + sha256(canonical(inspection)).hexdigest(), "worker_id": expected.worker_id, "nonce": expected.nonce, "original_effect_sha256": expected.original_effect_sha256, "reserved_effect_sha256": expected.reserved_effect_sha256, "original_forge_operation_id": forge}
    return expected, value


class HistoricalExecutionEvidenceTests(unittest.TestCase):
    def testExactCorrelationProducesNoAdmittedProductOperation(self):
        expected, value = fixture()
        decoded = decode_historical_execution_evidence(canonical(value), expected=expected)
        self.assertEqual(decoded.request, expected.request)
        self.assertEqual(decoded.record_sha256, "sha256:" + sha256(canonical(value)).hexdigest())
        self.assertNotIsInstance(decoded, AdmittedNativeProductOperation)
        with self.assertRaises(HistoricalExecutionEvidenceError):
            decode_historical_execution_evidence(canonical(value["inspection"]), expected=expected)

    def testEveryOuterBindingMutationIsRejected(self):
        expected, original = fixture()
        mutations = {"schema": "other", "state": "COMPLETE", "execution_authorized": False, "inspection_sha256": digest("0"), "worker_id": str(uuid4()), "nonce": str(uuid4()), "original_effect_sha256": digest("1"), "reserved_effect_sha256": digest("2"), "original_forge_operation_id": "product-" + "0" * 64}
        for key, changed in mutations.items():
            with self.subTest(key=key):
                value = json.loads(canonical(original)); value[key] = changed
                with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(canonical(value), expected=expected)
        for missing in original:
            value = dict(original); del value[missing]
            with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(canonical(value), expected=expected)

    def testAllFrozenRolesAndCurrentExecutorFieldsStayExact(self):
        expected, original = fixture()
        for key in ROLES:
            value = json.loads(canonical(original)); value["inspection"]["protected_sha256_by_role"][key] = digest("0")
            value["inspection_sha256"] = "sha256:" + sha256(canonical(value["inspection"])).hexdigest()
            with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(canonical(value), expected=expected)
        for key in original["inspection"]["current_executor"]:
            value = json.loads(canonical(original)); value["inspection"]["current_executor"][key] = True if key == "sequence" else "changed"
            value["inspection_sha256"] = "sha256:" + sha256(canonical(value["inspection"])).hexdigest()
            with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(canonical(value), expected=expected)

    def testInspectionCannotPromoteItselfOrChangeOriginalRequest(self):
        expected, original = fixture()
        for key, changed in {"execution_authorized": True, "state": "READY", "scope": "any", "original_ep_operation_id": "product-other", "original_descriptor_sha256": digest("0"), "original_operator_identity_sha256": digest("0"), "preserve_original_journals": False, "preserve_historical_uncertainty": False}.items():
            value = json.loads(canonical(original)); value["inspection"][key] = changed
            value["inspection_sha256"] = "sha256:" + sha256(canonical(value["inspection"])).hexdigest()
            with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(canonical(value), expected=expected)
        value = json.loads(canonical(original)); value["inspection"]["original_request"]["operation_id"] = "another"
        value["inspection_sha256"] = "sha256:" + sha256(canonical(value["inspection"])).hexdigest()
        with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(canonical(value), expected=expected)

    def testExpectedBindingRefusesOldExecutorTrustDriftOrNoncanonicalReservation(self):
        expected, _ = fixture()
        for current in [dict(expected.current_executor, version="1.2.3"), dict(expected.current_executor, sha256=expected.request.installer_release.sha256), dict(expected.current_executor, signing_key_id="another-key"), dict(expected.current_executor, release_trust_sha256=digest("0")), dict(expected.current_executor, sequence=True)]:
            with self.assertRaises(HistoricalExecutionEvidenceError): replace(expected, current_executor=current)
        for kwargs in [{"worker_id": expected.worker_id.upper()}, {"nonce": "00000000-0000-0000-0000-000000000000"}, {"reserved_effect_sha256": expected.original_effect_sha256}, {"protected_sha256_by_role": {}}]:
            with self.assertRaises(HistoricalExecutionEvidenceError): replace(expected, **kwargs)
        # Mutating source dictionaries cannot change the validated expectation.
        with self.assertRaises(TypeError): expected.current_executor["version"] = "9.9.9"

    def testUnknownDuplicateNoncanonicalAndOversizedJsonIsDenied(self):
        expected, value = fixture(); raw = canonical(value)
        bad = [b"", raw + b"\n", b'{"schema":"one","schema":"two"}', b'{"schema":NaN}', b"[" * 10000, b" " * (256 * 1024 + 1)]
        for fields in [value, value["inspection"], value["inspection"]["current_executor"], value["inspection"]["protected_sha256_by_role"]]:
            clone = json.loads(raw)
            if fields is value: clone["unknown"] = True
            elif fields is value["inspection"]: clone["inspection"]["unknown"] = True
            elif fields is value["inspection"]["current_executor"]: clone["inspection"]["current_executor"]["unknown"] = True
            else: clone["inspection"]["protected_sha256_by_role"]["unknown"] = digest("a")
            bad.append(canonical(clone))
        for data in bad:
            with self.assertRaises(HistoricalExecutionEvidenceError): decode_historical_execution_evidence(data, expected=expected)


if __name__ == "__main__": unittest.main()

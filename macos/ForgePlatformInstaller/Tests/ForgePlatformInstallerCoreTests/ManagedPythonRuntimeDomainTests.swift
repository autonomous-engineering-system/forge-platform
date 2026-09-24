import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeDomainTests: XCTestCase {
    func testExactRuntimeIdentityMatchesPythonCanonicalCommitment() {
        XCTAssertEqual(managedPythonTestRuntime.version, try! InstallerVersion("3.14.7"))
        XCTAssertEqual(managedPythonTestRuntime.minimumMacOSVersion, try! InstallerVersion("26.0.0"))
        XCTAssertEqual(managedPythonTestRuntime.pythonTag, "cp314")
        XCTAssertEqual(managedPythonTestRuntime.abiTag, "cp314")
        XCTAssertEqual(managedPythonTestRuntime.policyRevision, "test-policy/v1")
        XCTAssertEqual(
            managedPythonTestRuntime.computedIdentitySHA256,
            "sha256:a396aaf9695ae52f7a2f3a8cd4044212eae90f47bf5f4c54fa94ec736ac92846"
        )
    }

    func testDownloadIdentityRejectsUntrustedLocatorOrDigest() {
        XCTAssertThrowsError(try ManagedPythonDownloadIdentity(
            url: "http://example.com/python.tar.gz",
            sha256: taggedDigest("1")
        ))
        XCTAssertThrowsError(try ManagedPythonDownloadIdentity(
            url: "https://example.com/python.tar.gz",
            sha256: "1"
        ))
    }

    func testRuntimeRejectsPlatformTagPolicyAndCommitmentDrift() throws {
        XCTAssertThrowsError(try runtime(minimum: "25.9.0"))
        XCTAssertThrowsError(try runtime(pythonTag: "cp313"))
        XCTAssertThrowsError(try runtime(abiTag: "cp313"))
        XCTAssertThrowsError(try runtime(pythonTag: "python314", abiTag: "python314"))
        XCTAssertThrowsError(try runtime(policyRevision: "Invalid Policy"))
        XCTAssertThrowsError(try runtime(identity: taggedDigest("f")))
    }

    func testProductVenvIdentityRejectsUnsafeOrUnboundValues() {
        XCTAssertThrowsError(try ManagedProductVirtualEnvironmentIdentity(
            componentIdentity: "unsupported-component",
            venvIdentity: "forge-v1",
            pythonRuntimeIdentitySHA256: managedPythonTestRuntime.identitySHA256
        ))
        XCTAssertThrowsError(try ManagedProductVirtualEnvironmentIdentity(
            componentIdentity: "forge-runtime",
            venvIdentity: "Forge V1",
            pythonRuntimeIdentitySHA256: managedPythonTestRuntime.identitySHA256
        ))
        XCTAssertThrowsError(try ManagedProductVirtualEnvironmentIdentity(
            componentIdentity: "forge-runtime",
            venvIdentity: "forge-v1",
            pythonRuntimeIdentitySHA256: "sha256:nope"
        ))
    }

    private func runtime(
        minimum: String = "26.0.0",
        pythonTag: String = "cp314",
        abiTag: String = "cp314",
        policyRevision: String = "test-policy/v1",
        identity: String = "sha256:a396aaf9695ae52f7a2f3a8cd4044212eae90f47bf5f4c54fa94ec736ac92846"
    ) throws -> ManagedPythonRuntimeIdentity {
        try ManagedPythonRuntimeIdentity(
            version: InstallerVersion("3.14.7"),
            minimumMacOSVersion: InstallerVersion(minimum),
            pythonTag: pythonTag,
            abiTag: abiTag,
            artifact: managedPythonTestRuntime.artifact,
            source: managedPythonTestRuntime.source,
            sourceProvenance: managedPythonTestRuntime.sourceProvenance,
            buildProvenance: managedPythonTestRuntime.buildProvenance,
            policyRevision: policyRevision,
            identitySHA256: identity
        )
    }

    private func taggedDigest(_ nibble: Character) -> String {
        "sha256:" + String(repeating: nibble, count: 64)
    }
}

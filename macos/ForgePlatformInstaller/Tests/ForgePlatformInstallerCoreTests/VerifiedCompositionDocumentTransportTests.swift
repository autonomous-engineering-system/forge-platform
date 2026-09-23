import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class VerifiedCompositionDocumentTransportTests: XCTestCase {
    func testInvalidLocatorDigestIsRejectedByLocatorConsumersBeforeSession() throws {
        let bytes = Data("{\"ok\":true}".utf8)
        let locator = VerifiedCompositionCatalogDocumentLocator(
            url: "https://documents.example.test/manifest.json",
            sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
        )
        XCTAssertTrue(CompositionCatalogValidation.isCanonicalHTTPSURL(locator.url))
        XCTAssertTrue(CompositionCatalogValidation.isTaggedSHA256(locator.sha256))
        XCTAssertEqual(
            locator.sha256,
            "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
        )
        XCTAssertNotEqual(
            locator.sha256,
            "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: Data("changed".utf8))
        )
    }

    func testTransportRejectsMalformedHTTPSLocatorBeforeNetwork() async {
        let transport = HTTPSVerifiedCompositionDocumentTransport()
        let locator = VerifiedCompositionCatalogDocumentLocator(
            url: "http://documents.example.test/manifest.json",
            sha256: "sha256:" + String(repeating: "a", count: 64)
        )
        let result = await transport.fetch(locator)
        XCTAssertEqual(result, .failure(.unavailable))
    }
}

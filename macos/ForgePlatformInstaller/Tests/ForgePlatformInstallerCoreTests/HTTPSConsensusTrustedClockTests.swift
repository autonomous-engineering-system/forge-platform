import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class HTTPSConsensusTrustedClockTests: XCTestCase {
    func testTwoIndependentCloseHTTPSDatesAttestExactCatalogBytes() async throws {
        let feed = try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/stable.json"
        )
        let readback = try UntrustedCompositionCatalogFeedReadback(
            feed: feed,
            bytes: Data("{\"catalog\":true}".utf8)
        )
        let base = Date(timeIntervalSince1970: 1_795_000_000)
        let attester = HTTPSConsensusTrustedCompositionCatalogClockAttester(
            first: DateObserver(host: "time-a.example", result: .success(base)),
            second: DateObserver(host: "time-b.example", result: .success(base.addingTimeInterval(4))),
            maximumSkew: 10,
            freshness: 60
        )

        let result = await attester.attestCatalogReadback(readback)
        guard case .success(let evidence) = result else {
            return XCTFail("expected trusted consensus")
        }
        XCTAssertEqual(evidence.readback.bytes, readback.bytes)
        XCTAssertEqual(evidence.readback.feed, feed)
        XCTAssertTrue(evidence.readback.trustedClock)
        XCTAssertEqual(evidence.verifiedAt, base.addingTimeInterval(2))
        XCTAssertLessThan(evidence.verifiedAt, evidence.readback.freshUntil)
    }

    func testCatalogHostCannotAttestItselfAndOriginsMustBeIndependent() async throws {
        let feed = try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/stable.json"
        )
        let readback = try UntrustedCompositionCatalogFeedReadback(
            feed: feed,
            bytes: Data("{}".utf8)
        )
        let now = Date(timeIntervalSince1970: 1_795_000_000)

        for pair in [
            ("catalog.example.test", "time-b.example"),
            ("time-a.example", "time-a.example"),
        ] {
            let attester = HTTPSConsensusTrustedCompositionCatalogClockAttester(
                first: DateObserver(host: pair.0, result: .success(now)),
                second: DateObserver(host: pair.1, result: .success(now))
            )
            let result = await attester.attestCatalogReadback(readback)
            XCTAssertEqual(result, .failure(.unavailable))
        }
    }

    func testClockFailureAndExcessiveSkewFailClosed() async throws {
        let feed = try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/stable.json"
        )
        let readback = try UntrustedCompositionCatalogFeedReadback(
            feed: feed,
            bytes: Data("{}".utf8)
        )
        let now = Date(timeIntervalSince1970: 1_795_000_000)

        let failed = HTTPSConsensusTrustedCompositionCatalogClockAttester(
            first: DateObserver(host: "a.example", result: .failure(.unavailable)),
            second: DateObserver(host: "b.example", result: .success(now))
        )
        let failedResult = await failed.attestCatalogReadback(readback)
        XCTAssertEqual(failedResult, .failure(.unavailable))

        let skewed = HTTPSConsensusTrustedCompositionCatalogClockAttester(
            first: DateObserver(host: "a.example", result: .success(now)),
            second: DateObserver(host: "b.example", result: .success(now.addingTimeInterval(31))),
            maximumSkew: 30
        )
        let skewedResult = await skewed.attestCatalogReadback(readback)
        XCTAssertEqual(skewedResult, .failure(.unavailable))
    }
}

private struct DateObserver: IndependentHTTPSDateObserving {
    let originHost: String
    let result: Result<Date, TrustedClockHTTPSFailure>

    init(host: String, result: Result<Date, TrustedClockHTTPSFailure>) {
        originHost = host
        self.result = result
    }

    func observeDate() async -> Result<Date, TrustedClockHTTPSFailure> {
        result
    }
}

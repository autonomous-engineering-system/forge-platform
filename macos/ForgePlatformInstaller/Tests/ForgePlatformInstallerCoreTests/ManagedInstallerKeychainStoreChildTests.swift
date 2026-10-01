import Darwin
import Foundation
import XCTest
import ForgePlatformInstallerCore
@testable import ForgePlatformInstallerPrivilegedHelper

private struct FakeKeychainChildStore: ManagedInstallerKeychainChildStoring {
    let fingerprintResult: Result<String?, ManagedInstallerSystemKeychainFailure>
    let putResult: Result<Bool, ManagedInstallerSystemKeychainFailure>
    let clearResult: Result<Void, ManagedInstallerSystemKeychainFailure>

    init(
        fingerprint: Result<String?, ManagedInstallerSystemKeychainFailure> = .success(nil),
        put: Result<Bool, ManagedInstallerSystemKeychainFailure> = .success(true),
        clear: Result<Void, ManagedInstallerSystemKeychainFailure> = .success(())
    ) {
        fingerprintResult = fingerprint
        putResult = put
        clearResult = clear
    }

    func fingerprint(
        reference: String, operationID: String
    ) -> Result<String?, ManagedInstallerSystemKeychainFailure> {
        fingerprintResult
    }

    func putVerified(
        reference: String, operationID: String, material: String
    ) -> Result<Bool, ManagedInstallerSystemKeychainFailure> {
        putResult
    }

    func clearOwned(
        reference: String, operationID: String
    ) -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        clearResult
    }
}

final class ManagedInstallerKeychainStoreChildTests: XCTestCase {
    private let reference = "keychain://forge.ep/consumer"
    private let operationID = "operation-123"
    private let material = String(repeating: "a", count: 32)

    private func request(
        _ action: String, material: String? = nil
    ) throws -> Data {
        var value: [String: Any] = [
            "schema": ManagedInstallerKeychainStoreChild.schema,
            "action": action,
            "reference": reference,
            "operation_id": operationID,
        ]
        if let material { value["material"] = material }
        return try JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    func testExactPrivateRequestAndRootOnlyDispatch() throws {
        let raw = try request("put-verified", material: material)
        let decoded = try XCTUnwrap(ManagedInstallerKeychainStoreChild.Request.decode(raw))
        XCTAssertEqual(decoded.action, "put-verified")
        XCTAssertEqual(decoded.reference, reference)
        XCTAssertEqual(decoded.operationID, operationID)
        XCTAssertEqual(decoded.material, material)
        let arguments = ["forge-platform-installer-helper",
                         ManagedInstallerKeychainStoreChild.flag]
        var observed: ManagedInstallerKeychainStoreChild.Request?
        var written: Data?
        let execute: (ManagedInstallerKeychainStoreChild.Request) -> Data? = {
            observed = $0
            return Data(#"{"verified":true}"#.utf8)
        }
        let write: (Data) -> Bool = { written = $0; return true }
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.run(
            arguments, effectiveUID: { 0 }, read: { raw },
            perform: execute, write: write
        ), 0)
        XCTAssertEqual(observed, decoded)
        XCTAssertEqual(written, Data(#"{"verified":true}"#.utf8))
        XCTAssertFalse(try XCTUnwrap(written).contains(Data(material.utf8)))

        observed = nil
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.run(
            arguments, effectiveUID: { 501 },
            read: { XCTFail("unprivileged request was read"); return raw },
            perform: execute, write: write
        ), 78)
        XCTAssertNil(observed)
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.run(
            [arguments[0]], effectiveUID: { 0 },
            read: { XCTFail("invalid invocation was read"); return raw },
            perform: execute, write: write
        ), 78)
    }

    func testRejectsNoncanonicalAndAmbiguousRequestsBeforeStore() throws {
        let valid = try request("fingerprint")
        XCTAssertNotNil(ManagedInstallerKeychainStoreChild.Request.decode(valid))
        for raw in [
            Data(),
            Data(" {}".utf8),
            Data(String(repeating: "x", count: 2_049).utf8),
            Data(#"{"action":"fingerprint","action":"clear-owned","operation_id":"operation-123","reference":"keychain://forge.ep/consumer","schema":"forge-platform.keychain-store-child/v1"}"#.utf8),
            Data(#"{"action":"fingerprint","material":"secret","operation_id":"operation-123","reference":"keychain://forge.ep/consumer","schema":"forge-platform.keychain-store-child/v1"}"#.utf8),
            Data(#"{"action":"shell","operation_id":"operation-123","reference":"keychain://forge.ep/consumer","schema":"forge-platform.keychain-store-child/v1"}"#.utf8),
        ] {
            XCTAssertNil(ManagedInstallerKeychainStoreChild.Request.decode(raw))
        }
        XCTAssertNil(ManagedInstallerKeychainStoreChild.Request.decode(
            try request("put-verified", material: "short")
        ))
        XCTAssertNil(ManagedInstallerKeychainStoreChild.Request.decode(
            try request("put-verified", material: String(repeating: "a", count: 257))
        ))
        let raw = Data(#"{"action":"fingerprint","operation_id":"operation-123","reference":"keychain://other/path/extra","schema":"forge-platform.keychain-store-child/v1"}"#.utf8)
        XCTAssertNil(ManagedInstallerKeychainStoreChild.Request.decode(raw))
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.run(
            ["helper", ManagedInstallerKeychainStoreChild.flag],
            effectiveUID: { 0 }, read: { raw },
            perform: { _ in XCTFail("invalid request reached store"); return nil },
            write: { _ in XCTFail("invalid request emitted receipt"); return true }
        ), 78)
    }

    func testFailureNeverEmitsStoreDiagnosticsOrSecret() throws {
        let raw = try request("put-verified", material: material)
        var writes = 0
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.run(
            ["helper", ManagedInstallerKeychainStoreChild.flag],
            effectiveUID: { 0 }, read: { raw }, perform: { _ in nil },
            write: { _ in writes += 1; return true }
        ), 78)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.run(
            ["helper", ManagedInstallerKeychainStoreChild.flag],
            effectiveUID: { 0 }, read: { raw },
            perform: { _ in Data(repeating: 65, count: 257) },
            write: { _ in writes += 1; return true }
        ), 78)
        XCTAssertEqual(writes, 0)
    }

    func testStoreResponsesAreBoundedAndNeverExposeMaterial() throws {
        let fingerprint = try XCTUnwrap(
            ManagedInstallerKeychainStoreChild.Request.decode(request("fingerprint"))
        )
        let put = try XCTUnwrap(ManagedInstallerKeychainStoreChild.Request.decode(
            request("put-verified", material: material)
        ))
        let clear = try XCTUnwrap(
            ManagedInstallerKeychainStoreChild.Request.decode(request("clear-owned"))
        )
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.execute(
            fingerprint, store: FakeKeychainChildStore()
        ), Data(#"{"fingerprint":null}"#.utf8))
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.execute(
            fingerprint, store: FakeKeychainChildStore(fingerprint: .success(
                String(repeating: "f", count: 64)
            ))
        ), Data((#"{"fingerprint":""# + String(repeating: "f", count: 64)
                 + #""}"#).utf8))
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.execute(
            put, store: FakeKeychainChildStore(put: .success(true))
        ), Data(#"{"verified":true}"#.utf8))
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.execute(
            put, store: FakeKeychainChildStore(put: .success(false))
        ), Data(#"{"verified":false}"#.utf8))
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.execute(
            clear, store: FakeKeychainChildStore()
        ), Data(#"{"cleared":true}"#.utf8))
        XCTAssertNil(ManagedInstallerKeychainStoreChild.execute(
            fingerprint, store: FakeKeychainChildStore(fingerprint: .failure(.unavailable))
        ))
        XCTAssertNil(ManagedInstallerKeychainStoreChild.execute(
            put, store: FakeKeychainChildStore(put: .failure(.occupied))
        ))
        XCTAssertNil(ManagedInstallerKeychainStoreChild.execute(
            clear, store: FakeKeychainChildStore(clear: .failure(.unavailable))
        ))
    }

    func testBoundedPrivatePipeIO() throws {
        var requestPipe: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&requestPipe), 0)
        defer { Darwin.close(requestPipe[0]) }
        let raw = try request("fingerprint")
        let count = raw.withUnsafeBytes { bytes in
            Darwin.write(requestPipe[1], bytes.baseAddress!, bytes.count)
        }
        XCTAssertEqual(count, raw.count)
        Darwin.close(requestPipe[1])
        XCTAssertEqual(ManagedInstallerKeychainStoreChild.readBounded(
            descriptor: requestPipe[0]
        ), raw)

        var responsePipe: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&responsePipe), 0)
        defer { Darwin.close(responsePipe[0]) }
        let receipt = Data(#"{"verified":true}"#.utf8)
        XCTAssertTrue(ManagedInstallerKeychainStoreChild.writeBounded(
            receipt, descriptor: responsePipe[1]
        ))
        Darwin.close(responsePipe[1])
        var buffer = [UInt8](repeating: 0, count: 256)
        let observed = Darwin.read(responsePipe[0], &buffer, buffer.count)
        XCTAssertEqual(Data(buffer.prefix(observed)), receipt)
        XCTAssertNil(ManagedInstallerKeychainStoreChild.readBounded(descriptor: -1))
        XCTAssertFalse(ManagedInstallerKeychainStoreChild.writeBounded(
            receipt, descriptor: -1
        ))

        var oversizedPipe: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&oversizedPipe), 0)
        defer { Darwin.close(oversizedPipe[0]) }
        let oversized = Data(repeating: 65, count: 2_049)
        let oversizedCount = oversized.withUnsafeBytes { bytes in
            Darwin.write(oversizedPipe[1], bytes.baseAddress!, bytes.count)
        }
        XCTAssertEqual(oversizedCount, oversized.count)
        Darwin.close(oversizedPipe[1])
        XCTAssertNil(ManagedInstallerKeychainStoreChild.readBounded(
            descriptor: oversizedPipe[0]
        ))
    }
}

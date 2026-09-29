import Foundation

/// The released helper can use its own product executor without connecting to
/// its installer-only Mach service as a client. Both paths enter the same
/// canonical service handler and retain the same bounded receipt validation.
public struct ManagedInstallerHelperLocalProductOperationTransport:
    ManagedInstallerProductOperationTransporting,
    ManagedInstallerProductRemovalReviewTransporting,
    ManagedInstallerProductRemovalTransporting,
    ManagedInstallerPreservedLifecycleReviewTransporting,
    ManagedInstallerPreservedLifecycleTransporting,
    ManagedInstallerPreserveRecoveryTransporting, Sendable {
    private let service: ManagedInstallerProductOperationXPCServiceHandler

    public init(executor: any ManagedInstallerProductOperationHelperExecuting) {
        service = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
    }

    public func executeProductOperation(_ canonicalRequest: Data) async
        -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard let request = try? ManagedInstallerProductOperationRequest.decodeJSON(
            canonicalRequest
        ) else { return .failure(.invalidRequest) }
        return await call(
            canonicalRequest, isCanonical: request.canonicalJSONData() == canonicalRequest,
            maximumResponseBytes: ManagedInstallerProductOperationReceipt.maximumBytes,
            send: service.executeProductOperation,
            validResponse: { bytes in
                guard let receipt = try? ManagedInstallerProductOperationReceipt.decodeJSON(
                    bytes, request: request
                ) else { return false }
                return receipt.canonicalJSONData() == bytes
            }
        )
    }

    public func executeProductRemoval(_ canonicalRequest: Data) async
        -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard let request = try? ManagedInstallerProductRemovalRequest.decodeJSON(
            canonicalRequest
        ) else { return .failure(.invalidRequest) }
        return await call(
            canonicalRequest, isCanonical: request.canonicalJSONData() == canonicalRequest,
            maximumResponseBytes: ManagedInstallerProductRemovalReceipt.maximumBytes,
            send: service.executeProductRemoval,
            validResponse: { bytes in
                guard let receipt = try? ManagedInstallerProductRemovalReceipt.decodeJSON(
                    bytes, request: request
                ) else { return false }
                return receipt.canonicalJSONData() == bytes
            }
        )
    }

    public func prepareProductRemovalReview(_ canonicalIntent: Data) async
        -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard let intent = try? ManagedInstallerProductRemovalReviewIntent.decodeJSON(
            canonicalIntent
        ) else { return .failure(.invalidRequest) }
        return await call(
            canonicalIntent, isCanonical: intent.canonicalJSONData() == canonicalIntent,
            maximumResponseBytes: ManagedInstallerProductRemovalReviewProposal.maximumBytes,
            send: service.prepareProductRemovalReview,
            validResponse: { bytes in
                guard let proposal = try? ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                    bytes, intent: intent
                ) else { return false }
                return proposal.canonicalJSONData() == bytes
            }
        )
    }

    public func preparePreservedLifecycleReview(_ canonicalIntent: Data) async
        -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard let intent = try? ManagedInstallerPreservedLifecycleReviewIntent.decodeJSON(
            canonicalIntent
        ) else { return .failure(.invalidRequest) }
        return await call(
            canonicalIntent, isCanonical: intent.canonicalJSONData() == canonicalIntent,
            maximumResponseBytes: ManagedInstallerPreservedLifecycleReviewProposal.maximumBytes,
            send: service.preparePreservedLifecycleReview,
            validResponse: { bytes in
                guard let proposal = try? ManagedInstallerPreservedLifecycleReviewProposal
                    .decodeJSON(bytes, intent: intent) else { return false }
                return proposal.canonicalJSONData() == bytes
            }
        )
    }

    public func executePreservedLifecycle(_ canonicalRequest: Data) async
        -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard let request = try? ManagedInstallerPreservedLifecycleRequest.decodeJSON(
            canonicalRequest
        ) else { return .failure(.invalidRequest) }
        return await call(
            canonicalRequest, isCanonical: request.canonicalJSONData() == canonicalRequest,
            maximumResponseBytes: ManagedInstallerPreservedLifecycleReceipt.maximumBytes,
            send: service.executePreservedLifecycle,
            validResponse: { bytes in
                guard let receipt = try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                    bytes, request: request
                ) else { return false }
                return receipt.canonicalJSONData() == bytes
            }
        )
    }

    public func readTerminalPreserveRecovery(_ canonicalRequest: Data) async
        -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard let request = try? ManagedInstallerPreserveRecoveryRequest.decodeJSON(
            canonicalRequest
        ) else { return .failure(.invalidRequest) }
        return await call(
            canonicalRequest, isCanonical: request.canonicalJSONData() == canonicalRequest,
            maximumResponseBytes: ManagedInstallerPreserveRecoveryReceipt.maximumBytes,
            send: service.readTerminalPreserveRecovery,
            validResponse: { bytes in
                guard let receipt = try? ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
                    bytes, request: request
                ) else { return false }
                return receipt.canonicalJSONData() == bytes
            }
        )
    }

    private func call(
        _ canonicalRequest: Data,
        isCanonical: Bool,
        maximumResponseBytes: Int,
        send: @escaping (Data, @escaping (Data?) -> Void) -> Void,
        validResponse: @escaping (Data) -> Bool
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        guard isCanonical else { return .failure(.invalidRequest) }
        let response = await withCheckedContinuation { continuation in
            send(canonicalRequest) { bytes in continuation.resume(returning: bytes) }
        }
        guard let response else { return .failure(.unavailable) }
        guard response.count <= maximumResponseBytes,
              validResponse(response) else { return .failure(.rejected) }
        return .success(response)
    }
}

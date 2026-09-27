import CryptoKit
import Darwin
import Foundation

/// Owns only the private filesystem layout for a single product venv. The
/// actual Python invocation and independent venv readback are separate gates.
/// No path from a GUI, CLI or XPC request selects a destination.
struct MacOSManagedPythonProductVenvSlotLayout: Sendable {
    struct Pending: Sendable {
        fileprivate let name: String
        let url: URL
    }

    private let root: URL
    private let expectedOwner: uid_t

    init(root: URL, expectedOwner: uid_t = 0) {
        self.root = root
        self.expectedOwner = expectedOwner
    }

    static func slotName(for request: ManagedPythonProductVenvMutationRequest) -> String {
        let material: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.managed-python-product-venv-slot/v1"),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "component_identity": .string(request.componentIdentity),
            "venv_identity": .string(request.venvIdentity),
            "runtime_identity": .string(request.runtimeIdentitySHA256),
            "runtime_slot_identity": .string(request.runtimeSlotIdentity),
            "runtime_slot_evidence": .string(request.runtimeSlotEvidenceReference),
        ])
        return "venv-" + SHA256.hash(data: StrictSignedJSON.canonicalPayload(from: material))
            .map { String(format: "%02x", $0) }.joined()
    }

    func readPublishedDirectory(
        for request: ManagedPythonProductVenvMutationRequest
    ) -> Result<URL?, ManagedPythonRuntimeActivationFailure> {
        do {
            let descriptor = try openRoot()
            defer { _ = Darwin.close(descriptor) }
            let name = Self.slotName(for: request)
            guard try inspectChild(name, in: descriptor) else { return .success(nil) }
            return .success(root.appendingPathComponent(name, isDirectory: true))
        } catch let failure as ManagedPythonRuntimeActivationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    func createPendingDirectory() -> Result<Pending, ManagedPythonRuntimeActivationFailure> {
        do {
            let descriptor = try openRoot()
            defer { _ = Darwin.close(descriptor) }
            let name = "pending-" + UUID().uuidString.lowercased()
            guard name.withCString({ Darwin.mkdirat(descriptor, $0, 0o700) }) == 0 else {
                return .failure(.unavailable)
            }
            guard try inspectChild(name, in: descriptor), Darwin.fsync(descriptor) == 0 else {
                return .failure(.unavailable)
            }
            return .success(Pending(
                name: name, url: root.appendingPathComponent(name, isDirectory: true)
            ))
        } catch let failure as ManagedPythonRuntimeActivationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    func publish(
        _ pending: Pending,
        for request: ManagedPythonProductVenvMutationRequest
    ) -> Result<URL, ManagedPythonRuntimeActivationFailure> {
        do {
            let descriptor = try openRoot()
            defer { _ = Darwin.close(descriptor) }
            guard pending.url == root.appendingPathComponent(pending.name, isDirectory: true),
                  pending.name.hasPrefix("pending-"),
                  try inspectChild(pending.name, in: descriptor) else {
                return .failure(.rejected)
            }
            let destination = Self.slotName(for: request)
            let renamed = pending.name.withCString { source in
                destination.withCString { target in
                    Darwin.renameatx_np(descriptor, source, descriptor, target, UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 else {
                return .failure(errno == EEXIST ? .rejected : .unavailable)
            }
            guard Darwin.fsync(descriptor) == 0,
                  try inspectChild(destination, in: descriptor) else {
                return .failure(.rejected)
            }
            return .success(root.appendingPathComponent(destination, isDirectory: true))
        } catch let failure as ManagedPythonRuntimeActivationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    private func openRoot() throws -> Int32 {
        guard Darwin.geteuid() == expectedOwner,
              root.isFileURL, root.baseURL == nil, root.path.hasPrefix("/"),
              root.path != "/" else {
            throw ManagedPythonRuntimeActivationFailure.rejected
        }
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ManagedPythonRuntimeActivationFailure.rejected }
        do {
            try requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func inspectChild(_ name: String, in parent: Int32) throws -> Bool {
        var details = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &details, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else { throw ManagedPythonRuntimeActivationFailure.rejected }
            return false
        }
        guard (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedPythonRuntimeActivationFailure.rejected
        }
        return true
    }

    private func requirePrivateDirectory(_ descriptor: Int32) throws {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedPythonRuntimeActivationFailure.rejected
        }
    }
}

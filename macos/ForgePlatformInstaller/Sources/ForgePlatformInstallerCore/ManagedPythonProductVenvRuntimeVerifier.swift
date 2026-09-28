import Darwin
import Foundation

/// Reopens the exact qualified runtime slot before a product venv may use its
/// interpreter. The archive member inventory is helper-owned input from the
/// admitted runtime artifact; no caller-selected executable path is accepted.
struct MacOSManagedPythonProductVenvRuntimeVerifier: Sendable {
    private let slotsRoot: URL
    private let expectedOwner: uid_t
    private let runtimeIdentitySHA256: String
    private let members: [ManagedPythonRuntimeArchiveMember]

    init(
        slotsRoot: URL,
        runtimeIdentitySHA256: String,
        members: [ManagedPythonRuntimeArchiveMember],
        expectedOwner: uid_t = 0
    ) {
        self.slotsRoot = slotsRoot
        self.expectedOwner = expectedOwner
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.members = members
    }

    func verifiedInterpreter(
        for request: ManagedPythonProductVenvMutationRequest
    ) -> Result<URL, ManagedPythonRuntimeActivationFailure> {
        guard request.runtimeIdentitySHA256 == runtimeIdentitySHA256,
              request.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtimeIdentitySHA256
                ),
              members.contains(where: {
                  $0.path == ManagedPythonRuntimeArchiveInspection.interpreterRelativePath
                      && $0.kind == .file
              }),
              Darwin.geteuid() == expectedOwner,
              slotsRoot.isFileURL, slotsRoot.baseURL == nil,
              slotsRoot.path.hasPrefix("/"), slotsRoot.path != "/" else {
            return .failure(.rejected)
        }
        let root = slotsRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(root) }
        var details = stat()
        guard Darwin.fstat(root, &details) == 0,
              Self.isPrivateDirectory(details, owner: expectedOwner),
              request.runtimeSlotIdentity.withCString({
                  Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              Self.isPrivateDirectory(details, owner: expectedOwner) else {
            return .failure(.rejected)
        }
        let slot = slotsRoot.appendingPathComponent(
            request.runtimeSlotIdentity, isDirectory: true
        )
        do {
            let evidence = try MacOSManagedPythonRuntimeExtractedTreeVerifier(
                slotRoot: slot, expectedOwner: expectedOwner
            ).verify(members: members)
            guard evidence == request.runtimeSlotEvidenceReference else {
                return .failure(.rejected)
            }
            return .success(slot.appendingPathComponent(
                ManagedPythonRuntimeArchiveInspection.interpreterRelativePath
            ))
        } catch { return .failure(.rejected) }
    }

    private static func isPrivateDirectory(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && details.st_mode & mode_t(0o7777) == mode_t(0o700)
    }
}

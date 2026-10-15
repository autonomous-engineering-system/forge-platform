import Darwin
import Foundation
import ForgePlatformInstallerCore

/// An unprivileged customer report. No helper journal, challenge, raw stream,
/// path, account or exception text is admitted by the fixed status projection.
/// Failure is informational and can never grant or block execution authority.
@MainActor
final class InstallerMVPEventLog {
    private let directory: URL?
    private let name = "installation-" + UUID().uuidString.lowercased() + ".log"
    private var identity: (device: dev_t, inode: ino_t)?
    private var lastSnapshot: String?
    private var events = 0
    private var startedAt: Date?
    private(set) var fileURL: URL?
    private(set) var unavailable = false
    static let maximumBytes = 128 * 1024
    static let maximumEvents = 256

    init(directory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/ForgePlatformInstaller", isDirectory: true)) {
        self.directory = directory
    }

    func record(state: InstallerWizardState, choice: ManagedInstallerCompositionChoice,
                step: InstallerMVPFlowStep, at date: Date = Date()) {
        guard !unavailable, events < Self.maximumEvents else { return }
        let snapshot = "Stap: \(step.title)\n" + InstallerMVPSafeReport.text(state: state, choice: choice)
        guard snapshot != lastSnapshot else { return }
        let seconds = max(0, Int(date.timeIntervalSince(startedAt ?? date)))
        let elapsed = String(format: "Verstreken tijd: %d:%02d", seconds / 60, seconds % 60)
        let text = ISO8601DateFormatter().string(from: date) + "\n" + elapsed + "\n" + snapshot + "\n\n"
        guard let bytes = text.data(using: .utf8), append(bytes) else {
            unavailable = true
            fileURL = nil
            return
        }
        if startedAt == nil { startedAt = date }
        lastSnapshot = snapshot
        events += 1
    }

    private func append(_ bytes: Data) -> Bool {
        guard let directory, directory.isFileURL, directory.baseURL == nil,
              !bytes.isEmpty, bytes.count <= Self.maximumBytes else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { return false }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { return false }
        defer { Darwin.close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & 0o777 == 0o700 else { return false }
        let flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        let descriptor = openat(parent, name, identity == nil ? flags | O_CREAT | O_EXCL : flags, 0o600)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumBytes - bytes.count else { return false }
        if let identity {
            guard identity.device == info.st_dev, identity.inode == info.st_ino else { return false }
        } else {
            identity = (info.st_dev, info.st_ino)
        }
        let written = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written else { return false }
        fileURL = directory.appendingPathComponent(name)
        return true
    }
}

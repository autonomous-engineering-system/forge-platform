import Darwin
import Foundation
@testable import ForgePlatformInstallerCore

/// Anonymous XPC source tests still exercise the real per-user review boundary.
/// No installed authority or provider credentials are created by this helper.
func temporaryReviewedOperatorTestStore() throws
    -> (FileManagedInstallerHelperReviewedSelectionStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-review-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    return (FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: root, expectedOwner: getuid()), root)
}

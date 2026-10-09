import Darwin
import Foundation
import OpenDirectory

protocol ManagedInstallerLocalRecordReading: Sendable {
    func record(type: String, name: String, attributes: [String])
        -> Result<[String: [String]], ManagedInstallerProductServiceAccountPreparationFailure>
    func create(type: String, name: String, attributes: [String: [String]])
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure>
}

/// Always addresses the local node. A failed lookup is unavailable, never
/// interpreted as absence; POSIX absence is established separately first.
struct MacOSOpenDirectoryLocalRecordBackend: ManagedInstallerLocalRecordReading {
    func record(type: String, name: String, attributes: [String])
        -> Result<[String: [String]], ManagedInstallerProductServiceAccountPreparationFailure> {
        do {
            let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
            let record = try node.record(withRecordType: type, name: name, attributes: nil)
            let details = try record.recordDetails(forAttributes: attributes)
            var values: [String: [String]] = [:]
            for key in attributes {
                guard let strings = details[key] as? [String] else { return .failure(.rejected) }
                values[key] = strings
            }
            return .success(values)
        } catch {
            return .failure(.unavailable)
        }
    }

    func create(type: String, name: String, attributes: [String: [String]])
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        do {
            let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
            _ = try node.createRecord(withRecordType: type, name: name, attributes: attributes)
            return .success(())
        } catch {
            return .failure(.unavailable)
        }
    }
}

protocol ManagedInstallerPOSIXDirectoryReading: Sendable {
    func user(name: String) -> Result<(uid: UInt32, gid: UInt32)?,
        ManagedInstallerProductServiceAccountPreparationFailure>
    func group(name: String) -> Result<UInt32?,
        ManagedInstallerProductServiceAccountPreparationFailure>
    func userName(uid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure>
    func groupName(gid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure>
}

/// POSIX projection is read independently of the local Open Directory record.
struct MacOSPOSIXLocalAccountProjection: ManagedInstallerPOSIXDirectoryReading {
    func user(name: String) -> Result<(uid: UInt32, gid: UInt32)?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        var entry = passwd(); var pointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let status = name.withCString { key in buffer.withUnsafeMutableBufferPointer {
            Darwin.getpwnam_r(key, &entry, $0.baseAddress, $0.count, &pointer)
        }}
        guard status == 0 else { return .failure(.unavailable) }
        guard pointer != nil else { return .success(nil) }
        guard entry.pw_name.map({ String(cString: $0) }) == name else { return .failure(.rejected) }
        return .success((entry.pw_uid, entry.pw_gid))
    }

    func group(name: String) -> Result<UInt32?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        var entry = Darwin.group(); var pointer: UnsafeMutablePointer<Darwin.group>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let status = name.withCString { key in buffer.withUnsafeMutableBufferPointer {
            Darwin.getgrnam_r(key, &entry, $0.baseAddress, $0.count, &pointer)
        }}
        guard status == 0 else { return .failure(.unavailable) }
        guard pointer != nil else { return .success(nil) }
        guard entry.gr_name.map({ String(cString: $0) }) == name else { return .failure(.rejected) }
        return .success(entry.gr_gid)
    }

    func userName(uid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        var entry = passwd(); var pointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let status = buffer.withUnsafeMutableBufferPointer {
            Darwin.getpwuid_r(uid, &entry, $0.baseAddress, $0.count, &pointer)
        }
        guard status == 0 else { return .failure(.unavailable) }
        guard pointer != nil else { return .success(nil) }
        return .success(entry.pw_name.map { String(cString: $0) })
    }

    func groupName(gid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        var entry = Darwin.group(); var pointer: UnsafeMutablePointer<Darwin.group>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let status = buffer.withUnsafeMutableBufferPointer {
            Darwin.getgrgid_r(gid, &entry, $0.baseAddress, $0.count, &pointer)
        }
        guard status == 0 else { return .failure(.unavailable) }
        guard pointer != nil else { return .success(nil) }
        return .success(entry.gr_name.map { String(cString: $0) })
    }
}

struct MacOSOpenDirectoryLocalAccountStore: ManagedInstallerLocalDirectoryOperating {
    private let records: any ManagedInstallerLocalRecordReading
    private let posix: any ManagedInstallerPOSIXDirectoryReading

    init(records: any ManagedInstallerLocalRecordReading = MacOSOpenDirectoryLocalRecordBackend(),
         posix: any ManagedInstallerPOSIXDirectoryReading = MacOSPOSIXLocalAccountProjection()) {
        self.records = records
        self.posix = posix
    }

    func user(named name: String) -> Result<ManagedInstallerLocalDirectoryUser?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        switch posix.user(name: name) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .success(nil)
        case .success(let projection?):
            let keys = [kODAttributeTypeUniqueID, kODAttributeTypePrimaryGroupID,
                        kODAttributeTypeNFSHomeDirectory, kODAttributeTypeUserShell,
                        kODAttributeTypeAuthenticationAuthority]
            switch records.record(type: kODRecordTypeUsers, name: name, attributes: keys) {
            case .failure(let failure): return .failure(failure)
            case .success(let values):
                guard let uid = one(values, kODAttributeTypeUniqueID).flatMap(UInt32.init),
                      let gid = one(values, kODAttributeTypePrimaryGroupID).flatMap(UInt32.init),
                      let home = one(values, kODAttributeTypeNFSHomeDirectory),
                      let shell = one(values, kODAttributeTypeUserShell),
                      let authority = one(values, kODAttributeTypeAuthenticationAuthority),
                      uid == projection.uid, gid == projection.gid else { return .failure(.rejected) }
                return .success(ManagedInstallerLocalDirectoryUser(
                    name: name, uid: uid, gid: gid, home: home, shell: shell,
                    authenticationAuthority: authority
                ))
            }
        }
    }

    func group(named name: String) -> Result<ManagedInstallerLocalDirectoryGroup?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        switch posix.group(name: name) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .success(nil)
        case .success(let gid?):
            switch records.record(type: kODRecordTypeGroups, name: name,
                                  attributes: [kODAttributeTypePrimaryGroupID]) {
            case .failure(let failure): return .failure(failure)
            case .success(let values):
                guard one(values, kODAttributeTypePrimaryGroupID).flatMap(UInt32.init) == gid else {
                    return .failure(.rejected)
                }
                return .success(ManagedInstallerLocalDirectoryGroup(name: name, gid: gid))
            }
        }
    }

    func userName(forUID uid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> { posix.userName(uid: uid) }
    func groupName(forGID gid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> { posix.groupName(gid: gid) }

    func createGroup(_ group: ManagedInstallerLocalDirectoryGroup)
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        records.create(type: kODRecordTypeGroups, name: group.name,
                       attributes: [kODAttributeTypePrimaryGroupID: [String(group.gid)]])
    }

    func createUser(_ user: ManagedInstallerLocalDirectoryUser)
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        records.create(type: kODRecordTypeUsers, name: user.name,
                       attributes: [
                        kODAttributeTypeUniqueID: [String(user.uid)],
                        kODAttributeTypePrimaryGroupID: [String(user.gid)],
                        kODAttributeTypeNFSHomeDirectory: [user.home],
                        kODAttributeTypeUserShell: [user.shell],
                        kODAttributeTypeAuthenticationAuthority: [user.authenticationAuthority]
                       ])
    }

    private func one(_ values: [String: [String]], _ key: String) -> String? {
        guard let array = values[key], array.count == 1 else { return nil }
        return array[0]
    }
}

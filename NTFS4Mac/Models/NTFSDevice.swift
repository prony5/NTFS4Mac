import AppKit

// MARK: - Filesystem Type

enum FilesystemType: String, Sendable, Hashable {
    case ntfs
    case ext4

    var displayName: String {
        switch self {
        case .ntfs: return "NTFS"
        case .ext4: return "ext4"
        }
    }

    var supportsReadWriteMount: Bool { self == .ntfs }

    var mountButtonLabel: String {
        supportsReadWriteMount ? "Mount RW" : "Mount"
    }
}

// MARK: - Device Model

struct NTFSDevice: Identifiable, Hashable, Sendable {
    let id: String          // e.g. "disk4s1" or "disk4@p1"
    let diskNode: String    // e.g. "/dev/disk4s1" or "/dev/disk4"
    let volumeName: String
    let fileSystem: String
    let filesystemType: FilesystemType
    let size: String        // e.g. "500.1 GB"
    let usedSpace: String
    let availableSpace: String
    let byteOffset: UInt64  // non-zero when macOS can't expose the partition

    var mountPoint: String?
    var isReadWrite: Bool   // true = ntfs-3g mounted
    var isMounted: Bool     // mounted at all

    var displayName: String { volumeName.isEmpty ? id : volumeName }
    var mountTarget: String { diskNode }

    var statusText: String {
        if !isMounted { return "Unmounted" }
        if isReadWrite { return "Read-Write" }
        if filesystemType == .ext4 { return "Mounted (read-only)" }
        return "Read-Only"
    }

    var statusColor: String {
        if !isMounted { return "gray" }
        return isReadWrite ? "green" : "orange"
    }

    var needsMountAction: Bool {
        if filesystemType == .ext4 { return !isMounted }
        return !isReadWrite
    }

    var isAccessible: Bool {
        guard let mountPoint else { return false }
        return FileManager.default.isReadableFile(atPath: mountPoint)
    }
}

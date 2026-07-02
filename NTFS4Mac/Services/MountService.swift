import Foundation

// MARK: - Mount Service

@Observable
@MainActor
final class MountService: Sendable {
    private let ntfs3gPath: String?

    init(ntfs3gPath: String? = nil) {
        if let ntfs3gPath {
            self.ntfs3gPath = ntfs3gPath
        } else {
            self.ntfs3gPath = Self.resolveNTFS3GPath()
        }
    }

    var isNTFS3GAvailable: Bool { ntfs3gPath != nil }

    private static func resolveNTFS3GPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ntfs-3g",
            "/usr/local/bin/ntfs-3g"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func resolveNTFSFixPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ntfsfix",
            "/usr/local/bin/ntfsfix"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Mount as read-write

    func mount(device: NTFSDevice) async throws {
        guard let ntfs3gPath else {
            throw MountError.ntfs3gNotFound
        }

        let ntfsfixPath = Self.resolveNTFSFixPath()
        let mountPath = "/Volumes/\(device.displayName)"
        let escapedMountPath = mountPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNode = device.diskNode.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNTFS3G = ntfs3gPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNTFSFix = ntfsfixPath?.replacingOccurrences(of: "'", with: "'\\''")
        let volName = device.displayName.replacingOccurrences(of: "'", with: "'\\''")

        let fixStep: String
        if let escapedNTFSFix {
            fixStep = "'\(escapedNTFSFix)' '\(escapedNode)' || true; sleep 0.3; "
        } else {
            fixStep = ""
        }

        let mountScript = """
        /sbin/umount -f '\(escapedNode)' 2>/dev/null || true; \
        /usr/sbin/diskutil unmount force '\(escapedNode)' 2>/dev/null || true; \
        sleep 0.5; \
        \(fixStep)\
        /bin/rm -rf '\(escapedMountPath)'; \
        /bin/mkdir -p '\(escapedMountPath)'; \
        '\(escapedNTFS3G)' '\(escapedNode)' '\(escapedMountPath)' \
          -o auto_xattr -o volname='\(volName)' -o local -o remove_hiberfile
        """

        let (_, exitCode, stderr) = try await Shell.runWithSudoDetailed("/bin/sh", arguments: ["-c", mountScript])

        if exitCode != 0 {
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(code: exitCode, details: details.isEmpty ? nil : details)
        }
    }

    // MARK: - Unmount

    func unmount(device: NTFSDevice) async throws {
        let result = try await Shell.runWithSudo("/sbin/umount", arguments: ["-f", device.diskNode])
        if result.exitCode != 0 {
            _ = try? await Shell.run("/usr/sbin/diskutil", arguments: ["unmount", "force", device.diskNode])
        }
    }

    // MARK: - Eject

    func eject(device: NTFSDevice) async throws {
        let escapedNode = device.diskNode.replacingOccurrences(of: "'", with: "'\\''")

        let ejectScript = """
        /sbin/umount -f '\(escapedNode)' 2>/dev/null || true; \
        /usr/sbin/diskutil unmount force '\(escapedNode)' 2>/dev/null || true; \
        sleep 0.5; \
        /usr/sbin/diskutil eject '\(escapedNode)'
        """

        let (_, exitCode, stderr) = try await Shell.runWithSudoDetailed("/bin/sh", arguments: ["-c", ejectScript])

        if exitCode != 0 {
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.ejectFailed(details: details.isEmpty ? nil : details)
        }
    }

    // MARK: - Restore read-only

    func restore(device: NTFSDevice) async throws {
        guard device.isReadWrite else {
            throw MountError.alreadyReadOnly
        }

        _ = try? await Shell.runWithSudo("/sbin/umount", arguments: ["-f", device.diskNode])
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try? await Shell.run("/usr/sbin/diskutil", arguments: ["mount", device.diskNode])
    }
}

// MARK: - Errors

enum MountError: LocalizedError, Sendable {
    case ntfs3gNotFound
    case mountFailed(code: Int32, details: String?)
    case unmountFailed
    case ejectFailed(details: String?)
    case timeout
    case alreadyReadOnly

    var errorDescription: String? {
        switch self {
        case .ntfs3gNotFound:
            return "ntfs-3g not found. Install: brew install ntfs-3g-mac"
        case .mountFailed(let code, let details):
            var message = "Mount failed (exit code \(code))."
            if let details, !details.isEmpty {
                message += "\n\(details)"
            }
            if details?.localizedCaseInsensitiveContains("Operation not permitted") == true {
                message += """

                Добавьте NTFS4Mac в:
                Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску
                Затем перезапустите приложение.
                """
            } else {
                message += """

                Or in Terminal:
                sudo ntfsfix /dev/diskXsY
                sudo ntfs-3g /dev/diskXsY /Volumes/YourDisk -o remove_hiberfile -o local
                """
            }
            return message
        case .unmountFailed:
            return "Unmount failed. Close any apps using this volume."
        case .ejectFailed(let details):
            var message = "Failed to safely eject the drive."
            if let details, !details.isEmpty {
                message += "\n\(details)"
            } else {
                message += " Close Finder windows and apps using this disk, then try again."
            }
            return message
        case .timeout:
            return "Mount timed out. Possible Windows Fast Startup issue."
        case .alreadyReadOnly:
            return "Device is already read-only."
        }
    }
}

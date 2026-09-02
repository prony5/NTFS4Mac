import Foundation

// MARK: - Mount Service

@Observable
@MainActor
final class MountService: Sendable {
    private let ntfs3gPath: String?
    private let ext4fusePath: String?

    init(ntfs3gPath: String? = nil, ext4fusePath: String? = nil) {
        if let ntfs3gPath {
            self.ntfs3gPath = ntfs3gPath
        } else {
            self.ntfs3gPath = Self.resolveBinary(named: "ntfs-3g", candidates: [
                "/opt/homebrew/bin/ntfs-3g",
                "/usr/local/bin/ntfs-3g"
            ])
        }

        if let ext4fusePath {
            self.ext4fusePath = ext4fusePath
        } else {
            self.ext4fusePath = Self.resolveBinary(named: "ext4fuse", candidates: [
                "/opt/homebrew/bin/ext4fuse",
                "/usr/local/bin/ext4fuse"
            ])
        }
    }

    var isNTFS3GAvailable: Bool { ntfs3gPath != nil }
    var isExt4FuseAvailable: Bool { ext4fusePath != nil }

    private static func resolveBinary(named: String, candidates: [String]) -> String? {
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

    // MARK: - Mount

    func mount(device: NTFSDevice) async throws {
        switch device.filesystemType {
        case .ntfs:
            try await mountNTFS(device: device)
        case .ext4:
            try await mountExt4(device: device)
        }
    }

    private func mountNTFS(device: NTFSDevice) async throws {
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

        let mountScript = """
        \(Self.ntfs3gUnmountScript(
            escapedNode: escapedNode,
            escapedMountPath: escapedMountPath,
            escapedNtfsfix: nil
        ))
        \(Self.ntfs3gMountScript(
            escapedMountPath: escapedMountPath,
            escapedNode: escapedNode,
            escapedNTFS3G: escapedNTFS3G,
            escapedNtfsfix: escapedNTFSFix,
            volName: volName
        ))
        """

        let (_, exitCode, stderr) = try await Shell.runShellScriptWithSudoDetailed(mountScript)

        if exitCode != 0 {
            if await isVolumeMounted(at: mountPath),
               FileManager.default.isReadableFile(atPath: mountPath) {
                return
            }
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(code: exitCode, details: details.isEmpty ? nil : details, filesystem: .ntfs)
        }
    }

    private static func ntfs3gUnmountScript(
        escapedNode: String,
        escapedMountPath: String,
        escapedNtfsfix: String?
    ) -> String {
        let ntfsfixBlock = escapedNtfsfix.map {
            """
            NTFSFIX='\($0)'
            RAW="${DISK/disk/rdisk}"
            if [ ! -e "$RAW" ]; then RAW="$DISK"; fi
            "$NTFSFIX" -d "$RAW" 2>/dev/null || "$NTFSFIX" -d "$DISK" 2>/dev/null || true
            """
        } ?? ""
        return """
        DISK='\(escapedNode)'
        MOUNT_PATH='\(escapedMountPath)'
        /bin/sync
        if /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH (" >/dev/null 2>&1; then
          /sbin/umount "$MOUNT_PATH" 2>/dev/null || true
          /bin/sleep 1
          /sbin/umount -f "$MOUNT_PATH" 2>/dev/null || true
        fi
        /usr/bin/pkill -f "ntfs-3g.*$MOUNT_PATH" 2>/dev/null || true
        /usr/bin/pkill -f "ntfs-3g.*$DISK" 2>/dev/null || true
        /bin/sleep 0.5
        if /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH (" >/dev/null 2>&1; then
          /usr/sbin/diskutil unmount force "$MOUNT_PATH" 2>/dev/null || true
        fi
        /sbin/umount -f "$DISK" 2>/dev/null || true
        /usr/sbin/diskutil unmount force "$DISK" 2>/dev/null || true
        /bin/sync
        /bin/sleep 0.5
        \(ntfsfixBlock)
        """
    }

    private static func ntfs3gMountScript(
        escapedMountPath: String,
        escapedNode: String,
        escapedNTFS3G: String,
        escapedNtfsfix: String?,
        volName: String
    ) -> String {
        let ntfsfixBlock = escapedNtfsfix.map {
            """
            NTFSFIX='\($0)'
            RAW="${DISK/disk/rdisk}"
            if [ ! -e "$RAW" ]; then RAW="$DISK"; fi
            "$NTFSFIX" -d "$RAW" 2>/dev/null || "$NTFSFIX" -d "$DISK" 2>/dev/null || true
            """
        } ?? ""
        return """
        MOUNT_PATH='\(escapedMountPath)'
        DISK='\(escapedNode)'
        NTFS3G='\(escapedNTFS3G)'
        \(ntfsfixBlock)
        if [ ! -d "$MOUNT_PATH" ]; then /bin/mkdir -p "$MOUNT_PATH"; fi
        "$NTFS3G" "$DISK" "$MOUNT_PATH" -o auto_xattr -o volname='\(volName)' -o local -o remove_hiberfile -o sync &
        FUSE_PID=$!
        MOUNTED=0
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
          if /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH (" >/dev/null 2>&1 \
            || /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH," >/dev/null 2>&1; then
            MOUNTED=1
            break
          fi
          /bin/sleep 0.5
        done
        if [ "$MOUNTED" -eq 0 ]; then
          echo "ntfs-3g did not mount $MOUNT_PATH" >&2
          exit 1
        fi
        exit 0
        """
    }

    private static func ext4UnmountScript(escapedMountPath: String) -> String {
        """
        MOUNT_PATH='\(escapedMountPath)'
        /usr/sbin/diskutil unmount force "$MOUNT_PATH" 2>/dev/null || true
        /usr/bin/pkill -f "ext4fuse.*$MOUNT_PATH" 2>/dev/null || true
        sleep 0.5
        /sbin/umount -f "$MOUNT_PATH" 2>/dev/null || true
        /usr/sbin/diskutil unmount force "$MOUNT_PATH" 2>/dev/null || true
        if /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH (" >/dev/null 2>&1; then
          echo "Failed to unmount $MOUNT_PATH" >&2
          exit 1
        fi
        """
    }

    private static func ext4PreUnmountScript(escapedMountPath: String) -> String {
        """
        MOUNT_PATH='\(escapedMountPath)'
        /usr/sbin/diskutil unmount force "$MOUNT_PATH" 2>/dev/null || true
        /usr/bin/pkill -f "ext4fuse.*$MOUNT_PATH" 2>/dev/null || true
        /bin/sleep 0.5
        /sbin/umount -f "$MOUNT_PATH" 2>/dev/null || true
        """
    }

    private static func ext4MountScript(
        escapedMountPath: String,
        escapedNode: String,
        escapedExt4Fuse: String
    ) -> String {
        """
        MOUNT_PATH='\(escapedMountPath)'
        DISK='\(escapedNode)'
        EXT4FUSE='\(escapedExt4Fuse)'
        CONSOLE_USER=$(stat -f '%Su' /dev/console)
        CONSOLE_UID=$(id -u "$CONSOLE_USER")
        CONSOLE_GID=$(id -g "$CONSOLE_USER")
        \(ext4PreUnmountScript(escapedMountPath: escapedMountPath))
        if [ ! -d "$MOUNT_PATH" ]; then /bin/mkdir -p "$MOUNT_PATH"; fi
        "$EXT4FUSE" "$DISK" "$MOUNT_PATH" -o allow_other -o defer_permissions -o uid=$CONSOLE_UID -o gid=$CONSOLE_GID &
        FUSE_PID=$!
        MOUNTED=0
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
          if /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH (" >/dev/null 2>&1 \
            || /sbin/mount | /usr/bin/grep -F " on $MOUNT_PATH," >/dev/null 2>&1; then
            MOUNTED=1
            break
          fi
          /bin/sleep 0.5
        done
        if [ "$MOUNTED" -eq 0 ]; then
          /bin/kill "$FUSE_PID" 2>/dev/null || true
          echo "ext4fuse did not mount $MOUNT_PATH" >&2
          exit 1
        fi
        exit 0
        """
    }

    private func isVolumeMounted(at mountPath: String) async -> Bool {
        guard let output = try? await Shell.run("/sbin/mount") else { return false }
        return output.contains(" on \(mountPath) (") || output.contains(" on \(mountPath),")
    }

    private func mountExt4(device: NTFSDevice) async throws {
        guard let ext4fusePath else {
            throw MountError.ext4fuseNotFound
        }

        if device.byteOffset > 0 {
            throw MountError.partitionOffsetUnsupported(
                disk: device.diskNode.replacingOccurrences(of: "/dev/", with: "")
            )
        }

        let mountPath = "/Volumes/\(device.displayName)"
        let escapedMountPath = mountPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNode = device.mountTarget.replacingOccurrences(of: "'", with: "'\\''")
        let escapedExt4Fuse = ext4fusePath.replacingOccurrences(of: "'", with: "'\\''")

        let mountScript = Self.ext4MountScript(
            escapedMountPath: escapedMountPath,
            escapedNode: escapedNode,
            escapedExt4Fuse: escapedExt4Fuse
        )

        let (_, exitCode, stderr) = try await Shell.runShellScriptWithSudoDetailed(mountScript)

        if exitCode != 0 {
            if FileManager.default.isReadableFile(atPath: mountPath),
               await isVolumeMounted(at: mountPath) {
                return
            }
            var details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                details = "Mount command failed."
            }
            throw MountError.mountFailed(code: exitCode, details: details, filesystem: .ext4)
        }
    }

    // MARK: - Unmount

    func unmount(device: NTFSDevice) async throws {
        let mountPoint = device.mountPoint ?? "/Volumes/\(device.displayName)"
        let escapedMountPoint = mountPoint.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNode = device.diskNode.replacingOccurrences(of: "'", with: "'\\''")

        let unmountScript: String
        if device.filesystemType == .ext4 {
            unmountScript = Self.ext4UnmountScript(escapedMountPath: escapedMountPoint)
        } else {
            let ntfsfixPath = Self.resolveNTFSFixPath()?.replacingOccurrences(of: "'", with: "'\\''")
            unmountScript = Self.ntfs3gUnmountScript(
                escapedNode: escapedNode,
                escapedMountPath: escapedMountPoint,
                escapedNtfsfix: ntfsfixPath
            )
        }

        let result = try await Shell.runShellScriptWithSudo(unmountScript)
        if result.exitCode != 0 && device.filesystemType != .ext4 {
            _ = try? await Shell.run("/usr/sbin/diskutil", arguments: ["unmount", "force", device.diskNode])
        }
    }

    // MARK: - Eject

    func eject(device: NTFSDevice) async throws {
        let escapedNode = device.diskNode.replacingOccurrences(of: "'", with: "'\\''")
        let mountPoint = device.mountPoint ?? "/Volumes/\(device.displayName)"
        let escapedMountPoint = mountPoint.replacingOccurrences(of: "'", with: "'\\''")

        let ejectScript: String
        if device.filesystemType == .ext4 {
            ejectScript = """
            \(Self.ext4UnmountScript(escapedMountPath: escapedMountPoint))
            sleep 0.5
            /usr/sbin/diskutil eject '\(escapedNode)'
            """
        } else {
            let ntfsfixPath = Self.resolveNTFSFixPath()?.replacingOccurrences(of: "'", with: "'\\''")
            ejectScript = """
            \(Self.ntfs3gUnmountScript(
                escapedNode: escapedNode,
                escapedMountPath: escapedMountPoint,
                escapedNtfsfix: ntfsfixPath
            ))
            sleep 0.5
            /usr/sbin/diskutil eject '\(escapedNode)'
            """
        }

        let (_, exitCode, stderr) = try await Shell.runShellScriptWithSudoDetailed(ejectScript)

        if exitCode != 0 {
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.ejectFailed(details: details.isEmpty ? nil : details)
        }
    }

    // MARK: - Restore read-only (NTFS only)

    func restore(device: NTFSDevice) async throws {
        guard device.filesystemType == .ntfs else {
            throw MountError.restoreNotSupported
        }
        guard device.isReadWrite else {
            throw MountError.alreadyReadOnly
        }

        _ = try? await Shell.runShellScriptWithSudo(
            Self.ntfs3gUnmountScript(
                escapedNode: device.diskNode.replacingOccurrences(of: "'", with: "'\\''"),
                escapedMountPath: (device.mountPoint ?? "/Volumes/\(device.displayName)")
                    .replacingOccurrences(of: "'", with: "'\\''"),
                escapedNtfsfix: Self.resolveNTFSFixPath()?.replacingOccurrences(of: "'", with: "'\\''")
            )
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try? await Shell.run("/usr/sbin/diskutil", arguments: ["mount", device.diskNode])
    }
}

// MARK: - Errors

enum MountError: LocalizedError, Sendable {
    case ntfs3gNotFound
    case ext4fuseNotFound
    case mountFailed(code: Int32, details: String?, filesystem: FilesystemType)
    case unmountFailed
    case ejectFailed(details: String?)
    case timeout
    case alreadyReadOnly
    case restoreNotSupported
    case partitionOffsetUnsupported(disk: String)

    var errorDescription: String? {
        switch self {
        case .ntfs3gNotFound:
            return "ntfs-3g not found. Install: brew tap gromgit/fuse && brew install ntfs-3g-mac"
        case .ext4fuseNotFound:
            return "ext4fuse not found. Install: brew tap gromgit/fuse && brew install ext4fuse-mac"
        case .mountFailed(let code, let details, let filesystem):
            var message = "Mount failed (exit code \(code))."
            if let details, !details.isEmpty {
                message += "\n\(details)"
            }
            if details?.localizedCaseInsensitiveContains("Operation not permitted") == true
                && details?.localizedCaseInsensitiveContains("Full Disk Access") != true {
                if details?.contains("rm:") == true || details?.contains("/Volumes/") == true {
                    message += """

                    Could not clean up the mount point. Try in Terminal:
                    sudo umount -f /Volumes/YourDisk
                    Then click Mount again.
                    """
                } else {
                    message += """

                    Add NTFS4Mac in:
                    System Settings → Privacy & Security → Full Disk Access
                    Then restart the app.
                    """
                }
            } else if filesystem == .ntfs {
                message += """

                Or in Terminal:
                sudo ntfsfix -d /dev/diskXsY
                sudo ntfs-3g /dev/diskXsY /Volumes/YourDisk -o remove_hiberfile -o local -o sync
                """
            } else {
                message += """

                Or in Terminal:
                diskutil unmount force /Volumes/YourDisk
                sudo ext4fuse /dev/diskXsY /Volumes/YourDisk -o allow_other -o defer_permissions -o uid=$(id -u) -o gid=$(id -g)
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
        case .restoreNotSupported:
            return "Restore to read-only is only supported for NTFS volumes."
        case .partitionOffsetUnsupported(let disk):
            return """
            macOS can't expose this partition as a separate device.
            Try repairing the partition map in Terminal:
            diskutil repairDisk \(disk)
            Then click Refresh and mount again.
            """
        }
    }
}

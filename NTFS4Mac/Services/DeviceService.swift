import Foundation

// MARK: - Device Service

@Observable
@MainActor
final class DeviceService {
    var devices: [NTFSDevice] = []
    var isRefreshing = false

    private var ntfs3gPath: String?
    private var ext4fusePath: String?

    init() {
        resolveNTFS3GPath()
        resolveExt4FusePath()
    }

    // MARK: - Find binaries

    private func resolveNTFS3GPath() {
        ntfs3gPath = Self.findExecutable(named: "ntfs-3g", candidates: [
            "/opt/homebrew/bin/ntfs-3g",
            "/usr/local/bin/ntfs-3g"
        ])
    }

    private func resolveExt4FusePath() {
        ext4fusePath = Self.findExecutable(named: "ext4fuse", candidates: [
            "/opt/homebrew/bin/ext4fuse",
            "/usr/local/bin/ext4fuse"
        ])
    }

    private static func findExecutable(named: String, candidates: [String]) -> String? {
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [named]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let which = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !which.isEmpty {
                return which
            }
        } catch {}
        return nil
    }

    var isNTFS3GAvailable: Bool { ntfs3gPath != nil }
    var isExt4FuseAvailable: Bool { ext4fusePath != nil }

    // MARK: - Discover Devices

    @MainActor
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let mountOutput = try await Shell.run("/sbin/mount")
            let output = try await Shell.run("/usr/sbin/diskutil", arguments: ["list", "external", "physical"])
            let diskIDs = parseTopLevelDiskIDs(from: output)

            var found: [NTFSDevice] = []
            for diskID in diskIDs {
                let partitionsOutput = try? await Shell.run("/usr/sbin/diskutil", arguments: ["list", "/dev/\(diskID)"])
                let partIDs = parsePartitionIDs(from: partitionsOutput ?? "")

                if partIDs.isEmpty {
                    found.append(contentsOf: await discoverWholeDisk(diskID, mountOutput: mountOutput))
                } else {
                    for partID in partIDs {
                        if let device = try? await fetchDeviceInfo(partID, mountOutput: mountOutput) {
                            found.append(device)
                        }
                    }
                }
            }
            self.devices = found
        } catch {
            print("Failed to list devices: \(error)")
        }
    }

    // MARK: - Parse diskutil output

    private func parseTopLevelDiskIDs(from output: String) -> [String] {
        let pattern = "/dev/(disk[0-9]+) \\("
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: output) else { return nil }
            return String(output[swiftRange])
        }.removingDuplicates()
    }

    private func parsePartitionIDs(from output: String) -> [String] {
        let pattern = "(disk[0-9]+s[0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: range)
            .compactMap { Range($0.range, in: output).map { String(output[$0]) } }
            .removingDuplicates()
    }

    // MARK: - Whole disk discovery

    private func discoverWholeDisk(_ diskID: String, mountOutput: String) async -> [NTFSDevice] {
        let diskNode = "/dev/\(diskID)"
        let infoOutput = (try? await Shell.run("/usr/sbin/diskutil", arguments: ["info", diskNode])) ?? ""
        let info = parseDiskutilInfo(infoOutput)
        let probed = FilesystemProbe.probe(deviceNode: diskNode)

        if probed.isEmpty {
            if let device = await buildWholeDiskFallback(diskID: diskID, info: info, mountOutput: mountOutput) {
                return [device]
            }
            return []
        }

        return probed.map { volume in
            buildProbedDevice(
                diskID: diskID,
                info: info,
                volume: volume,
                mountOutput: mountOutput
            )
        }
    }

    private func buildWholeDiskFallback(
        diskID: String,
        info: [String: String],
        mountOutput: String
    ) async -> NTFSDevice? {
        let content = info["content"] ?? ""
        guard content == "None" || content.isEmpty else { return nil }

        return NTFSDevice(
            id: diskID,
            diskNode: "/dev/\(diskID)",
            volumeName: info["mediaName"] ?? diskID,
            fileSystem: "Unknown (Linux?)",
            filesystemType: .ext4,
            size: info["diskSize"] ?? "Unknown",
            usedSpace: "",
            availableSpace: "",
            byteOffset: 0,
            mountPoint: ext4MountInfo(volumeName: info["mediaName"] ?? diskID, deviceID: diskID, mountOutput: mountOutput).mountPoint,
            isReadWrite: false,
            isMounted: ext4MountInfo(volumeName: info["mediaName"] ?? diskID, deviceID: diskID, mountOutput: mountOutput).isMounted
        )
    }

    private func buildProbedDevice(
        diskID: String,
        info: [String: String],
        volume: ProbedVolume,
        mountOutput: String
    ) -> NTFSDevice {
        let suffix = volume.partitionIndex.map { "p\($0)" } ?? "whole"
        let id = volume.byteOffset == 0 ? diskID : "\(diskID)@\(suffix)"
        let mediaName = info["mediaName"] ?? diskID
        let volumeName = volume.partitionIndex.map { "\(mediaName) (partition \($0))" } ?? mediaName

        return NTFSDevice(
            id: id,
            diskNode: "/dev/\(diskID)",
            volumeName: volumeName,
            fileSystem: volume.label,
            filesystemType: volume.filesystemType,
            size: info["diskSize"] ?? "Unknown",
            usedSpace: "",
            availableSpace: "",
            byteOffset: volume.byteOffset,
            mountPoint: ext4MountInfo(volumeName: volumeName, deviceID: diskID, mountOutput: mountOutput).mountPoint,
            isReadWrite: false,
            isMounted: ext4MountInfo(volumeName: volumeName, deviceID: diskID, mountOutput: mountOutput).isMounted
        )
    }

    // MARK: - Filesystem detection

    private static func detectFilesystem(fsType: String, partitionType: String, mountedNatively: Bool) -> FilesystemType? {
        if fsType.localizedCaseInsensitiveContains("NTFS") {
            return .ntfs
        }

        if fsType.localizedCaseInsensitiveContains("ext4") {
            return .ext4
        }

        // macOS may misreport an NTFS volume as exfat, but a volume it actually mounted
        // with its own driver really has that filesystem (MBR type 0x07 is shared by NTFS and exFAT).
        if mountedNatively {
            return nil
        }

        if partitionType.localizedCaseInsensitiveContains("NTFS") {
            return .ntfs
        }

        if partitionType.localizedCaseInsensitiveContains("ext4") {
            return .ext4
        }

        let isLinux = partitionType.localizedCaseInsensitiveContains("Linux")
            && !partitionType.localizedCaseInsensitiveContains("Swap")
            && !partitionType.localizedCaseInsensitiveContains("LVM")
        if isLinux {
            return .ext4
        }

        return nil
    }

    /// True when macOS mounted the partition with the filesystem it reports,
    /// e.g. "/dev/disk4s1 on /Volumes/X (exfat, local, ...)".
    private static func isMountedNatively(partID: String, fsType: String, mountOutput: String) -> Bool {
        guard !fsType.isEmpty else { return false }
        return mountOutput.components(separatedBy: "\n").contains { line in
            line.hasPrefix("/dev/\(partID) on ") && line.localizedCaseInsensitiveContains("(\(fsType),")
        }
    }

    // MARK: - Fetch single device info

    private func fetchDeviceInfo(_ partID: String, mountOutput: String) async throws -> NTFSDevice? {
        let output = try await Shell.run("/usr/sbin/diskutil", arguments: ["info", "/dev/\(partID)"])
        let info = parseDiskutilInfo(output)

        let fsType = info["fsType"] ?? ""
        let partitionType = info["partitionType"] ?? ""
        let mountedNatively = Self.isMountedNatively(partID: partID, fsType: fsType, mountOutput: mountOutput)
        guard let filesystemType = Self.detectFilesystem(
            fsType: fsType,
            partitionType: partitionType,
            mountedNatively: mountedNatively
        ) else {
            return nil
        }

        let volumeName = info["volumeName"] ?? ""
        let effectiveVolumeName = volumeName.isEmpty ? partID : volumeName
        let expectedMount = "/Volumes/\(effectiveVolumeName)"
        var isRW = false
        var isMounted = false
        var mountPoint: String? = nil

        switch filesystemType {
        case .ntfs:
            for line in mountOutput.components(separatedBy: "\n") {
                guard let mp = extractMountPoint(from: line) else { continue }

                if mp == expectedMount {
                    if line.contains("fuse-t") || line.contains("ntfs-3g") || line.contains("macfuse") {
                        isMounted = true
                        mountPoint = mp
                        isRW = FileManager.default.isWritableFile(atPath: mp)
                        break
                    }
                    if line.contains("ntfs") {
                        isMounted = true
                        mountPoint = mp
                    }
                }

                if line.contains("fuse-t:/\(effectiveVolumeName)") {
                    isMounted = true
                    mountPoint = mp
                    isRW = FileManager.default.isWritableFile(atPath: mp)
                    break
                }
                if line.contains(partID) && (line.contains("macfuse") || line.contains("ntfs-3g")) {
                    isRW = true
                    isMounted = true
                    mountPoint = mp
                    break
                }
                if line.contains(partID) && line.contains("ntfs") {
                    isMounted = true
                    mountPoint = mp
                }
            }

        case .ext4:
            let mountInfo = ext4MountInfo(
                volumeName: volumeName.isEmpty ? partID : volumeName,
                deviceID: partID,
                mountOutput: mountOutput
            )
            isMounted = mountInfo.isMounted
            mountPoint = mountInfo.mountPoint
        }

        let displayFS: String
        switch filesystemType {
        case .ntfs:
            displayFS = info["fsType"] ?? "NTFS"
        case .ext4:
            displayFS = fsType.localizedCaseInsensitiveContains("ext4") ? fsType : "ext4 (Linux)"
        }

        return NTFSDevice(
            id: partID,
            diskNode: "/dev/\(partID)",
            volumeName: effectiveVolumeName == partID && volumeName.isEmpty ? "" : effectiveVolumeName,
            fileSystem: displayFS,
            filesystemType: filesystemType,
            size: info["diskSize"] ?? "Unknown",
            usedSpace: info["usedSpace"] ?? "",
            availableSpace: info["freeSpace"] ?? "",
            byteOffset: 0,
            mountPoint: mountPoint,
            isReadWrite: isRW,
            isMounted: isMounted
        )
    }

    private func ext4MountInfo(
        volumeName: String,
        deviceID: String,
        mountOutput: String
    ) -> (isMounted: Bool, mountPoint: String?) {
        let expectedMount = "/Volumes/\(volumeName.isEmpty ? deviceID : volumeName)"

        for line in mountOutput.components(separatedBy: "\n") {
            guard line.contains("ext4fuse") || line.contains("fuse-ext2") else { continue }
            guard let mountPoint = extractMountPoint(from: line) else { continue }
            guard mountPoint == expectedMount else { continue }

            let accessible = FileManager.default.isReadableFile(atPath: mountPoint)
            return (accessible, mountPoint)
        }

        return (false, nil)
    }

    private func extractMountPoint(from line: String) -> String? {
        guard let range = line.range(of: " on ") else { return nil }
        let afterOn = line[range.upperBound...]
        guard let endRange = afterOn.range(of: " (") else { return nil }
        return String(afterOn[..<endRange.lowerBound])
    }

    private func parseDiskutilInfo(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Type (Bundle)":
                result["fsType"] = value
            case "Partition Type":
                result["partitionType"] = value
            case "Volume Name":
                result["volumeName"] = (value == "Not applicable (no file system)") ? "" : value
            case "Device / Media Name":
                result["mediaName"] = value
            case "Content (IOContent)":
                result["content"] = value.trimmingCharacters(in: .whitespaces)
            case "Mount Point":
                result["mountPoint"] = (value == "Not mounted") ? nil : value
            case "Disk Size":
                if let parenRange = value.range(of: "(", options: []) {
                    result["diskSize"] = String(value[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                } else {
                    result["diskSize"] = value
                }
            case "Volume Used Space":
                if let parenRange = value.range(of: "(", options: []) {
                    result["usedSpace"] = String(value[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                } else {
                    result["usedSpace"] = value
                }
            case "Volume Free Space":
                if let parenRange = value.range(of: "(", options: []) {
                    result["freeSpace"] = String(value[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                } else {
                    result["freeSpace"] = value
                }
            default:
                break
            }
        }
        return result
    }
}

// MARK: - Array extension

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

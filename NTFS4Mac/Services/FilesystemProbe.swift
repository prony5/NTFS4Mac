import Foundation

// MARK: - Filesystem Probe

struct ProbedVolume: Sendable, Hashable {
    let filesystemType: FilesystemType
    let byteOffset: UInt64
    let partitionIndex: Int?
    let label: String
}

enum FilesystemProbe {
    private static let sectorSize: UInt64 = 512
    private static let linuxPartitionGUID = Data([
        0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47,
        0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4
    ])

    static func probe(deviceNode: String) -> [ProbedVolume] {
        let rawNode = deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let path = FileManager.default.isReadableFile(atPath: rawNode) ? rawNode : deviceNode
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        guard let header = readData(from: handle, offset: 0, count: 32 * 1024) else { return [] }

        var results: [ProbedVolume] = []

        if let fs = detectFilesystem(in: header, baseOffset: 0) {
            results.append(ProbedVolume(
                filesystemType: fs,
                byteOffset: 0,
                partitionIndex: nil,
                label: fs.displayName
            ))
        }

        if header.count > 520, header[512..<520] == Data("EFI PART".utf8) {
            results.append(contentsOf: probeGPT(header: header, handle: handle))
        }

        return deduplicate(results)
    }

    private static func probeGPT(header: Data, handle: FileHandle) -> [ProbedVolume] {
        guard header.count >= 512 + 92 else { return [] }

        let entryLBA = readUInt64(header, at: 512 + 72)
        let entryCount = Int(readUInt32(header, at: 512 + 80))
        let entrySize = Int(readUInt32(header, at: 512 + 84))
        guard entryLBA > 0, entryCount > 0, entrySize >= 128 else { return [] }

        let tableOffset = entryLBA * sectorSize
        let tableSize = entryCount * entrySize
        guard let table = readData(from: handle, offset: tableOffset, count: tableSize) else { return [] }

        var results: [ProbedVolume] = []
        let usableEntries = min(entryCount, table.count / entrySize)

        for index in 0..<usableEntries {
            let start = index * entrySize
            let entry = table[start..<(start + entrySize)]
            guard entry.contains(where: { $0 != 0 }) else { continue }

            let typeGUID = Data(entry[0..<16])
            let firstLBA = readUInt64(entry, at: 32)
            let lastLBA = readUInt64(entry, at: 40)
            guard firstLBA > 0, lastLBA >= firstLBA else { continue }

            let byteOffset = firstLBA * sectorSize
            let isLinux = typeGUID == linuxPartitionGUID
                || typeGUID.starts(with: Data([0xAF, 0x3D, 0xC6, 0x0F]))
            guard isLinux || typeGUID.starts(with: Data([0xA2, 0xA0, 0xD0, 0xEB])) else { continue }

            guard let superblock = readData(from: handle, offset: byteOffset + 1024, count: 512) else { continue }
            guard superblock.count >= 58 else { continue }
            let magic = UInt16(superblock[56]) | (UInt16(superblock[57]) << 8)
            guard magic == 0xEF53 else { continue }

            results.append(ProbedVolume(
                filesystemType: .ext4,
                byteOffset: byteOffset,
                partitionIndex: index + 1,
                label: "ext4 (partition \(index + 1))"
            ))
        }

        return results
    }

    private static func detectFilesystem(in data: Data, baseOffset: UInt64) -> FilesystemType? {
        if data.count > 11 {
            let oem = data[3..<11]
            if oem == Data("NTFS    ".utf8) { return .ntfs }
        }

        if data.count > 1082 {
            let magic = UInt16(data[1080]) | (UInt16(data[1081]) << 8)
            if magic == 0xEF53 { return .ext4 }
        }

        return nil
    }

    private static func readData(from handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (8 * i)
        }
        return value
    }

    private static func deduplicate(_ volumes: [ProbedVolume]) -> [ProbedVolume] {
        var seen = Set<UInt64>()
        return volumes.filter { seen.insert($0.byteOffset).inserted }
    }
}

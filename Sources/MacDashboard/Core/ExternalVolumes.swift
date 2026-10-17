import DiskArbitration
import Foundation

struct ExternalVolume: Identifiable, Equatable {
    let id: String        // mount path
    let name: String
    let detail: String    // e.g. "USB · HFS+"
    let total: Int64
    let available: Int64

    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Mounted volumes on external physical disks (USB / Thunderbolt drives). Network and FUSE
/// mounts have no backing disk in DiskArbitration, so they are skipped without being touched.
enum ExternalVolumes {
    static func scan() -> [ExternalVolume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var result: [ExternalVolume] = []
        for url in urls where url.path != "/" {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let desc = DADiskCopyDescription(disk) as? [String: Any]
            else { continue }
            let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
            let network = desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false
            guard !isInternal, !network else { continue }

            var st = statfs()
            guard statfs(url.path, &st) == 0, st.f_blocks > 0 else { continue }
            let blockSize = Int64(st.f_bsize)
            let name = desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? url.lastPathComponent
            let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let kind = (desc[kDADiskDescriptionVolumeKindKey as String] as? String).map(fileSystemName)
            result.append(ExternalVolume(
                id: url.path,
                name: name,
                detail: [proto, kind].compactMap { $0 }.joined(separator: " · "),
                total: Int64(st.f_blocks) * blockSize,
                available: Int64(st.f_bavail) * blockSize
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func fileSystemName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "apfs": "APFS"
        case "hfs": "HFS+"
        case "exfat": "exFAT"
        case "msdos": "FAT32"
        case "ntfs": "NTFS"
        default: kind.uppercased()
        }
    }
}

import Foundation

/// A mounted volume shown on the start screen.
struct Volume: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isInternal: Bool
    let isRemovable: Bool

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            let avail = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return Volume(url: url, name: v.volumeName ?? url.lastPathComponent, totalCapacity: total,
                          availableCapacity: avail, isInternal: v.volumeIsInternal ?? false,
                          isRemovable: v.volumeIsRemovable ?? false)
        }
    }
}

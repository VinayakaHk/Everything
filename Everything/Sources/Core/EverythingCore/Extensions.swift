import Foundation

// MARK: - FSNode Extensions

extension FSNode {
    public var extension: String {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts.last!) : ""
    }
    
    public var stem: String {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts.first!) : name
    }
    
    public var parentPath: String {
        let pathComponents = path.split(separator: "/").dropLast()
        return pathComponents.isEmpty ? "/" : "/" + pathComponents.joined(separator: "/")
    }
    
    public var depthFromRoot: Int {
        return pathComponents.count - 1
    }
    
    private var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }
}

// MARK: - Search Property Extensions

extension SearchProperty {
    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        case .created: return "Created"
        case .accessed: return "Accessed"
        case .changed: return "Changed"
        case .extension: return "Extension"
        case .writeGen: return "Write Gen"
        }
    }
    
    public var isNumeric: Bool {
        switch self {
        case .size, .writeGen: return true
        default: return false
        }
    }
    
    public var isTemporal: Bool {
        switch self {
        case .modified, .created, .accessed, .changed: return true
        default: return false
        }
    }
}

// MARK: - Search Result Extensions

extension SearchResult {
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }
    
    public var formattedModTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(modTime)))
    }
    
    public var formattedCreateTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(createTime)))
    }
    
    public var age: String {
        let interval = Date().timeIntervalSince1970 - TimeInterval(modTime)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "unknown"
    }
}

// MARK: - Volume Info Extensions

extension VolumeInfo {
    public var formattedCapacity: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalCapacity))
    }
    
    public var formattedFreeSpace: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(freeCapacity))
    }
    
    public var usagePercentage: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(totalCapacity - freeCapacity) / Double(totalCapacity) * 100
    }
    
    public var formattedUsage: String {
        return String(format: "%.1f%%", usagePercentage)
    }
}

// MARK: - Scan Progress Extensions

extension ScanProgress {
    public var formattedFilesPerSecond: String {
        guard elapsedTime > 0 else { return "0" }
        let fps = Double(filesScanned) / elapsedTime
        return String(format: "%.0f", fps)
    }
    
    public var formattedBytesPerSecond: String {
        guard elapsedTime > 0 else { return "0 B/s" }
        let bps = Double(bytesScanned) / elapsedTime
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bps)) + "/s"
    }
    
    public var estimatedTimeRemaining: TimeInterval? {
        guard let estimatedTotal = estimatedTotalFiles,
              filesScanned > 0,
              elapsedTime > 0 else { return nil }
        
        let rate = Double(filesScanned) / elapsedTime
        let remaining = Double(estimatedTotal - filesScanned) / rate
        return remaining > 0 ? remaining : nil
    }
    
    public var formattedETA: String? {
        guard let eta = estimatedTimeRemaining else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: eta)
    }
}

// MARK: - FSNode Comparison

extension FSNode: Comparable {
    public static func < (lhs: FSNode, rhs: FSNode) -> Bool {
        return lhs.name < rhs.name
    }
}

// MARK: - Composite Key Extensions

extension CompositeKey: CustomStringConvertible {
    public var description: String {
        return "\(deviceID):\(inodeID)"
    }
}

// MARK: - Search Result Comparable

extension SearchResult: Comparable {
    public static func < (lhs: SearchResult, rhs: SearchResult) -> Bool {
        return lhs.path < rhs.path
    }
}

// MARK: - IndexSnapshot Extensions

extension IndexSnapshot {
    public func node(for inodeID: UInt64, volumeID: UInt32) -> FSNode? {
        return nodesByInode[CompositeKey(deviceID: volumeID, inodeID: inodeID)]
    }
    
    public func nodes(in volume: UUID) -> [FSNode] {
        return nodes.filter { $0.apfsVolumeUUID == volume }
    }
    
    public func nodes(matching predicate: (FSNode) -> Bool) -> [FSNode] {
        return nodes.filter(predicate)
    }
    
    public func statistics() -> IndexStatistics {
        var stats = IndexStatistics()
        stats.totalNodes = totalNodes
        stats.totalSize = nodes.reduce(0) { $0 + $1.fileSize }
        stats.directoryCount = nodes.filter { $0.isDirectory }.count
        stats.fileCount = nodes.filter { $0.isRegularFile }.count
        stats.symlinkCount = nodes.filter { $0.isSymlink }.count
        stats.compressedCount = nodes.filter { $0.isCompressed }.count
        stats.encryptedCount = nodes.filter { ($0.bsdFlags & 0x100000) != 0 }.count // SF_ENCRYPTED would need proper constant
        stats.cloneCount = nodes.filter { $0.cloneGroupID != nil }.count
        stats.hardLinkCount = nodes.filter { $0.hardLinkCount > 1 }.count
        stats.totalMemoryBytes = estimatedMemoryBytes
        
        // Volume breakdown
        var volumeStats: [UUID: VolumeStatistics] = [:]
        for node in nodes {
            var volStat = volumeStats[node.apfsVolumeUUID] ?? VolumeStatistics()
            volStat.nodeCount += 1
            volStat.totalSize += node.fileSize
            if node.isDirectory { volStat.directoryCount += 1 }
            if node.isRegularFile { volStat.fileCount += 1 }
            volumeStats[node.apfsVolumeUUID] = volStat
        }
        stats.volumeStatistics = volumeStats
        
        return stats
    }
}

// MARK: - Index Statistics

public struct IndexStatistics {
    public var totalNodes: Int = 0
    public var totalSize: UInt64 = 0
    public var directoryCount: Int = 0
    public var fileCount: Int = 0
    public var symlinkCount: Int = 0
    public var compressedCount: Int = 0
    public var encryptedCount: Int = 0
    public var cloneCount: Int = 0
    public var hardLinkCount: Int = 0
    public var totalMemoryBytes: UInt64 = 0
    public var volumeStatistics: [UUID: VolumeStatistics] = [:]
}

public struct VolumeStatistics {
    public var nodeCount: Int = 0
    public var totalSize: UInt64 = 0
    public var directoryCount: Int = 0
    public var fileCount: Int = 0
}
import Foundation

// MARK: - Protocol Version

public let EverythingXPCProtocolVersion = "1.0.0"

// MARK: - Volume Info

public struct VolumeInfo: Codable, Sendable {
    public let uuid: UUID
    public let name: String
    public let bsdName: String          // e.g., "disk3s1"
    public let mountPoint: String
    public let fileSystem: String       // "apfs", "hfs", "smb", etc.
    public let totalCapacity: UInt64
    public let freeCapacity: UInt64
    public let isEncrypted: Bool
    public let isRoot: Bool
    public let isRemovable: Bool
    
    public init(uuid: UUID, name: String, bsdName: String, mountPoint: String,
                fileSystem: String, totalCapacity: UInt64, freeCapacity: UInt64,
                isEncrypted: Bool, isRoot: Bool, isRemovable: Bool) {
        self.uuid = uuid
        self.name = name
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.isEncrypted = isEncrypted
        self.isRoot = isRoot
        self.isRemovable = isRemovable
    }
}

// MARK: - Volume Identity

public struct VolumeIdentity: Codable, Sendable {
    public let apfsUUID: UUID
    public let volfsID: UInt32
    public let filerefID: UInt32
    public let deviceID: UInt32        // st_dev from stat
    public let mountPoint: String
    public let bsdName: String
    
    public init(apfsUUID: UUID, volfsID: UInt32, filerefID: UInt32,
                deviceID: UInt32, mountPoint: String, bsdName: String) {
        self.apfsUUID = apfsUUID
        self.volfsID = volfsID
        self.filerefID = filerefID
        self.deviceID = deviceID
        self.mountPoint = mountPoint
        self.bsdName = bsdName
    }
}

// MARK: - Scan Progress

public struct ScanProgress: Codable, Sendable {
    public let volumeUUID: UUID
    public let phase: ScanPhase
    public let filesScanned: UInt64
    public let bytesScanned: UInt64
    public let currentPath: String?
    public let elapsedTime: TimeInterval
    public let estimatedTotalFiles: UInt64?
    
    public init(volumeUUID: UUID, phase: ScanPhase, filesScanned: UInt64,
                bytesScanned: UInt64, currentPath: String?, elapsedTime: TimeInterval,
                estimatedTotalFiles: UInt64?) {
        self.volumeUUID = volumeUUID
        self.phase = phase
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
        self.elapsedTime = elapsedTime
        self.estimatedTotalFiles = estimatedTotalFiles
    }
}

public enum ScanPhase: String, Codable, Sendable {
    case openingDevice = "opening_device"
    case readingSuperblocks = "reading_superblocks"
    case resolvingOMAP = "resolving_omap"
    case iteratingFSTree = "iterating_fs_tree"
    case parsingRecords = "parsing_records"
    case buildingIndex = "building_index"
    case postProcessing = "post_processing"
    case complete = "complete"
    case failed = "failed"
}

// MARK: - Scan Result

public struct ScanResult: Codable, Sendable {
    public let volumeUUID: UUID
    public let nodes: [FSNode]
    public let stats: ScanStats
    public let errors: [ScanError]
    public let duration: TimeInterval
    
    public init(volumeUUID: UUID, nodes: [FSNode], stats: ScanStats,
                errors: [ScanError], duration: TimeInterval) {
        self.volumeUUID = volumeUUID
        self.nodes = nodes
        self.stats = stats
        self.errors = errors
        self.duration = duration
    }
}

public struct ScanStats: Codable, Sendable {
    public let totalFiles: UInt64
    public let totalFolders: UInt64
    public let totalBytes: UInt64
    public let clonesFound: UInt64
    public let hardLinksFound: UInt64
    public let compressedFiles: UInt64
    public let encryptedFiles: UInt64
    public let snapshotsFound: UInt64
    
    public init(totalFiles: UInt64, totalFolders: UInt64, totalBytes: UInt64,
                clonesFound: UInt64, hardLinksFound: UInt64,
                compressedFiles: UInt64, encryptedFiles: UInt64,
                snapshotsFound: UInt64) {
        self.totalFiles = totalFiles
        self.totalFolders = totalFolders
        self.totalBytes = totalBytes
        self.clonesFound = clonesFound
        self.hardLinksFound = hardLinksFound
        self.compressedFiles = compressedFiles
        self.encryptedFiles = encryptedFiles
        self.snapshotsFound = snapshotsFound
    }
}

public struct ScanError: Codable, Sendable, Error {
    public let code: String
    public let message: String
    public let path: String?
    public let inodeID: UInt64?
    
    public init(code: String, message: String, path: String? = nil, inodeID: UInt64? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.inodeID = inodeID
    }
}

// MARK: - FSNode (Index Entry)

public struct FSNode: Codable, Sendable, Hashable {
    public let inodeID: UInt64
    public let parentID: UInt64
    public let privateID: UInt64
    public let name: String
    public let createTime: UInt64          // seconds since epoch
    public let createTimeNsec: UInt32
    public let modTime: UInt64
    public let modTimeNsec: UInt32
    public let changeTime: UInt64
    public let changeTimeNsec: UInt32
    public let accessTime: UInt64
    public let accessTimeNsec: UInt32
    public let fileSize: UInt64
    public let uncompressedSize: UInt64
    public let mode: UInt16
    public let flags: UInt64               // INODE_* internal flags
    public let bsdFlags: UInt32            // UF_* / SF_* flags
    public let owner: UInt32
    public let group: UInt32
    public let writeGen: UInt32
    public let cloneGroupID: UInt64?
    public let hardLinkCount: Int32
    public let volumeID: UInt32
    public let apfsVolumeUUID: UUID
    public let volfsVolumeID: UInt32?
    public let filerefVolumeID: UInt32?
    // Computed (not persisted)
    public let path: String
    public let depth: Int
    
    public init(inodeID: UInt64, parentID: UInt64, privateID: UInt64, name: String,
                createTime: UInt64, createTimeNsec: UInt32,
                modTime: UInt64, modTimeNsec: UInt32,
                changeTime: UInt64, changeTimeNsec: UInt32,
                accessTime: UInt64, accessTimeNsec: UInt32,
                fileSize: UInt64, uncompressedSize: UInt64,
                mode: UInt16, flags: UInt64, bsdFlags: UInt32,
                owner: UInt32, group: UInt32, writeGen: UInt32,
                cloneGroupID: UInt64?, hardLinkCount: Int32,
                volumeID: UInt32, apfsVolumeUUID: UUID,
                volfsVolumeID: UInt32?, filerefVolumeID: UInt32?,
                path: String, depth: Int) {
        self.inodeID = inodeID
        self.parentID = parentID
        self.privateID = privateID
        self.name = name
        self.createTime = createTime
        self.createTimeNsec = createTimeNsec
        self.modTime = modTime
        self.modTimeNsec = modTimeNsec
        self.changeTime = changeTime
        self.changeTimeNsec = changeTimeNsec
        self.accessTime = accessTime
        self.accessTimeNsec = accessTimeNsec
        self.fileSize = fileSize
        self.uncompressedSize = uncompressedSize
        self.mode = mode
        self.flags = flags
        self.bsdFlags = bsdFlags
        self.owner = owner
        self.group = group
        self.writeGen = writeGen
        self.cloneGroupID = cloneGroupID
        self.hardLinkCount = hardLinkCount
        self.volumeID = volumeID
        self.apfsVolumeUUID = apfsVolumeUUID
        self.volfsVolumeID = volfsVolumeID
        self.filerefVolumeID = filerefVolumeID
        self.path = path
        self.depth = depth
    }
    
    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    public var isRegularFile: Bool { (mode & 0o170000) == 0o100000 }
    public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }
    public var isCompressed: Bool { (bsdFlags & 0x20) != 0 }  // UF_COMPRESSED
    public var isImmutable: Bool { (bsdFlags & 0x02) != 0 }   // UF_IMMUTABLE
    public var isDataLess: Bool { (bsdFlags & 0x1000) != 0 }  // SF_DATALESS
}

// MARK: - Index Delta (Real-time Updates)

public enum IndexDelta: Codable, Sendable {
    case insert(FSNode)
    case remove(inodeID: UInt64, volumeID: UInt32)
    case move(inodeID: UInt64, volumeID: UInt32, newParentID: UInt64, newName: String)
    case updateSize(inodeID: UInt64, volumeID: UInt32, newSize: UInt64)
    case updateAttrs(inodeID: UInt64, volumeID: UInt32, bsdFlags: UInt32, modTime: UInt64, modTimeNsec: UInt32)
    case updateCloneGroup(inodeID: UInt64, volumeID: UInt32, cloneGroupID: UInt64?)
    case updateHardLinks(inodeID: UInt64, volumeID: UInt32, count: Int32)
    case volumeMounted(VolumeInfo)
    case volumeUnmounted(volumeUUID: UUID)
}

// MARK: - Snapshot Info

public struct SnapshotInfo: Codable, Sendable {
    public let uuid: UUID
    public let name: String
    public let creationTime: UInt64
    public let volumeUUID: UUID
    
    public init(uuid: UUID, name: String, creationTime: UInt64, volumeUUID: UUID) {
        self.uuid = uuid
        self.name = name
        self.creationTime = creationTime
        self.volumeUUID = volumeUUID
    }
}

// MARK: - Debug Info

public struct DebugInfo: Codable, Sendable {
    public let helperVersion: String
    public let uptime: TimeInterval
    public let memoryUsage: UInt64
    public let activeSubscriptions: Int
    public let volumesMonitored: [UUID]
    public let lastScanTime: Date?
    public let lastScanDuration: TimeInterval?
    public let lastScanFiles: UInt64?
    
    public init(helperVersion: String, uptime: TimeInterval, memoryUsage: UInt64,
                activeSubscriptions: Int, volumesMonitored: [UUID],
                lastScanTime: Date?, lastScanDuration: TimeInterval?, lastScanFiles: UInt64?) {
        self.helperVersion = helperVersion
        self.uptime = uptime
        self.memoryUsage = memoryUsage
        self.activeSubscriptions = activeSubscriptions
        self.volumesMonitored = volumesMonitored
        self.lastScanTime = lastScanTime
        self.lastScanDuration = lastScanDuration
        self.lastScanFiles = lastScanFiles
    }
}

// MARK: - Subscription Token

public struct SubscriptionToken: Codable, Sendable, Hashable {
    public let id: UUID
    public let volumeUUID: UUID
    public let eventTypes: [String]
    
    public init(id: UUID, volumeUUID: UUID, eventTypes: [String]) {
        self.id = id
        self.volumeUUID = volumeUUID
        self.eventTypes = eventTypes
    }
}

// MARK: - ES Event Types (subset for subscription)

public enum ESEventType: String, Codable, Sendable, CaseIterable {
    case create = "create"
    case createDir = "create_dir"
    case createFile = "create_file"
    case createSymlink = "create_symlink"
    case delete = "delete"
    case deleteDir = "delete_dir"
    case deleteFile = "delete_file"
    case rename = "rename"
    case write = "write"
    case truncate = "truncate"
    case extend = "extend"
    case setattr = "setattr"
    case chmod = "chmod"
    case chown = "chown"
    case setxattr = "setxattr"
    case removexattr = "removexattr"
    case clone = "clone"
    case snapshot = "snapshot"
    case link = "link"
    case unlink = "unlink"
    case exchange = "exchange"
}

// MARK: - XPC Protocol

public protocol EverythingHelperProtocol {
    // Volume management
    func enumerateVolumes() async throws -> [VolumeInfo]
    func getVolumeIdentity(deviceID: UInt32) async throws -> VolumeIdentity?
    
    // Initial indexing
    func startFullScan(volumeUUID: UUID) async throws -> AsyncThrowingStream<ScanProgress, Error>
    func cancelScan(volumeUUID: UUID) async throws
    
    // Real-time monitoring
    func subscribeToEvents(_ events: [ESEventType], volumeUUID: UUID) async throws -> SubscriptionToken
    func unsubscribe(_ token: SubscriptionToken) async throws
    
    // File ID resolution
    func resolvePath(deviceID: UInt32, inodeID: UInt64) async throws -> String?
    func resolveFileRefURL(_ url: URL) async throws -> FSNode?
    
    // Snapshot management
    func listSnapshots(volumeUUID: UUID) async throws -> [SnapshotInfo]
    func mountSnapshot(volumeUUID: UUID, snapshotUUID: UUID, mountPoint: String) async throws
    func unmountSnapshot(mountPoint: String) async throws
    
    // Debug
    func getDebugInfo() async throws -> DebugInfo
}

// MARK: - Error Types

public enum HelperError: Error, Codable, Sendable, LocalizedError {
    case xpcConnectionFailed(String)
    case xpcTimeout
    case helperNotInstalled
    case helperNotRunning
    case invalidVolume(UUID)
    case permissionDenied(String)
    case deviceAccessFailed(String)
    case scanFailed(String)
    case scanCancelled
    case subscriptionFailed(String)
    case notSubscribed(UUID)
    case snapshotOperationFailed(String)
    case fileResolutionFailed(String)
    case invalidArgument(String)
    case internalError(String)
    
    public var errorDescription: String? {
        switch self {
        case .xpcConnectionFailed(let msg): return "XPC connection failed: \(msg)"
        case .xpcTimeout: return "XPC call timed out"
        case .helperNotInstalled: return "Privileged helper not installed"
        case .helperNotRunning: return "Privileged helper not running"
        case .invalidVolume(let uuid): return "Invalid volume: \(uuid)"
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .deviceAccessFailed(let msg): return "Device access failed: \(msg)"
        case .scanFailed(let msg): return "Scan failed: \(msg)"
        case .scanCancelled: return "Scan was cancelled"
        case .subscriptionFailed(let msg): return "Subscription failed: \(msg)"
        case .notSubscribed(let uuid): return "Not subscribed to volume: \(uuid)"
        case .snapshotOperationFailed(let msg): return "Snapshot operation failed: \(msg)"
        case .fileResolutionFailed(let msg): return "File resolution failed: \(msg)"
        case .invalidArgument(let msg): return "Invalid argument: \(msg)"
        case .internalError(let msg): return "Internal error: \(msg)"
        }
    }
}
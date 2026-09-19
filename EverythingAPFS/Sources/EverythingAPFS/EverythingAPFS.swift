import Foundation
import EverythingAPFS

// MARK: - Swift Wrappers for APFS C Structures

/// Parsed APFS key
public struct APFSKey: Sendable {
    public let objectID: UInt64
    public let recordType: UInt8
    
    public init(objectID: UInt64, recordType: UInt8) {
        self.objectID = objectID
        self.recordType = recordType
    }
    
    public static func parse(_ key: j_key_t) -> APFSKey {
        let objID = key.obj_id_and_type & OBJ_ID_MASK
        let type = UInt8(key.obj_id_and_type >> OBJ_TYPE_SHIFT)
        return APFSKey(objectID: objID, recordType: type)
    }
}

/// Parsed inode record
public struct APFSInode: Sendable {
    public let parentID: UInt64
    public let privateID: UInt64
    public let createTime: UInt64
    public let modTime: UInt64
    public let changeTime: UInt64
    public let accessTime: UInt64
    public let internalFlags: UInt64
    public let hardLinkCount: Int32
    public let writeGenerationCounter: UInt32
    public let bsdFlags: UInt32
    public let owner: UInt32
    public let group: UInt32
    public let mode: UInt16
    public let uncompressedSize: UInt64
    
    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    public var isRegularFile: Bool { (mode & 0o170000) == 0o100000 }
    public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }
    public var isCompressed: Bool { (bsdFlags & UInt32(UF_COMPRESSED)) != 0 }
    public var isImmutable: Bool { (bsdFlags & UInt32(UF_IMMUTABLE)) != 0 }
    public var isDataLess: Bool { (bsdFlags & UInt32(SF_DATALESS)) != 0 }
    
    public init(from parsed: apfs_inode_parsed_t) {
        self.parentID = parsed.parent_id
        self.privateID = parsed.private_id
        self.createTime = parsed.create_time
        self.modTime = parsed.mod_time
        self.changeTime = parsed.change_time
        self.accessTime = parsed.access_time
        self.internalFlags = parsed.internal_flags
        self.hardLinkCount = parsed.nlink
        self.writeGenerationCounter = parsed.write_generation_counter
        self.bsdFlags = parsed.bsd_flags
        self.owner = parsed.owner
        self.group = parsed.group
        self.mode = parsed.mode
        self.uncompressedSize = parsed.uncompressed_size
    }
}

/// Parsed directory record
public struct APFSDirectoryRecord: Sendable {
    public let parentInode: UInt64
    public let fileID: UInt64
    public let dateAdded: UInt64
    public let flags: UInt16
    public let name: String
    
    public var recordType: UInt8 { UInt8(flags & 0x0F) }
    public var isDirectory: Bool { recordType == DT_DIR }
    public var isRegularFile: Bool { recordType == DT_REG }
    public var isSymlink: Bool { recordType == DT_LNK }
    
    public init(from parsed: apfs_drec_parsed_t) {
        self.parentInode = parsed.parent_inode
        self.fileID = parsed.file_id
        self.dateAdded = parsed.date_added
        self.flags = parsed.flags
        self.name = parsed.name
    }
}

/// Parsed file extent
public struct APFSFileExtent: Sendable {
    public let logicalAddress: UInt64
    public let physicalAddress: UInt64
    public let length: UInt64
    public let flags: UInt32
    public let cryptoID: UInt32
    
    public init(from parsed: apfs_file_extent_parsed_t) {
        self.logicalAddress = parsed.logical_addr
        self.physicalAddress = parsed.phys_addr
        self.length = parsed.length
        self.flags = parsed.flags
        self.cryptoID = parsed.crypto_id
    }
}

/// Parsed extended field
public struct APFSExtendedField: Sendable {
    public let type: UInt8
    public let flags: UInt8
    public let size: UInt16
    public let data: Data
    
    public init(from parsed: apfs_xfield_parsed_t) {
        self.type = parsed.type
        self.flags = parsed.flags
        self.size = parsed.size
        if let dataPtr = parsed.data, parsed.size > 0 {
            self.data = Data(bytes: dataPtr, count: Int(parsed.size))
        } else {
            self.data = Data()
        }
    }
}

/// Parsed clonegroup record
public struct APFSCloneGroup: Sendable {
    public let groupID: UInt64
    public let recordType: UInt8  // 1 = mapping, 2 = cookie
    public let inodeID: UInt64
    public let privateID: UInt64
    public let physicalSize: UInt64
    public let flags: UInt32
    public var isFullClone: Bool { (flags & UInt32(CLONEGROUP_FLAG_FULL_CLONE)) != 0 }
    
    public init(groupID: UInt64, recordType: UInt8, inodeID: UInt64, privateID: UInt64, physicalSize: UInt64, flags: UInt32) {
        self.groupID = groupID
        self.recordType = recordType
        self.inodeID = inodeID
        self.privateID = privateID
        self.physicalSize = physicalSize
        self.flags = flags
    }
}

// MARK: - Directory Record Hash

/// Compute APFS directory record hash for a filename
/// Matches the algorithm: NFD + case fold -> UTF-32LE -> CRC-32C -> complement -> low 22 bits
public func apfsDirectoryRecordHash(for name: String) -> UInt32 {
    return apfs_drec_compute_hash(name)
}

// MARK: - Record Type Constants

public enum APFSRecordType: UInt8, Sendable {
    case snapMetadata = 1
    case extent = 2
    case inode = 3
    case xattr = 4
    case siblingLink = 5
    case dstreamID = 6
    case cryptoState = 7
    case fileExtent = 8
    case directoryRecord = 9
    case directoryStats = 10
    case snapName = 11
    case siblingMap = 12
    case fileInfo = 13
}

public enum APFSExtendedFieldType: UInt8, Sendable {
    // Inode extended fields
    case snapXID = 1
    case deltaTreeOID = 2
    case documentID = 3
    case name = 4
    case prevFSize = 5
    case finderInfo = 7
    case dstream = 8
    case dirStatsKey = 10
    case fsUUID = 11
    case unrawSize = 12
    case sparseBytes = 13
    case rdev = 14
    case purgeableFlags = 15
    case origSyncRootID = 16
    case nlink = 17
    case sourcePurgeID = 18
    case attributionTagHash = 19
    case specTelemetryState = 20
    case cloneGroupID = 21
    case specTelemetryTrigger = 22
    
    // Directory record extended fields
    case siblingID = 1 | 0x80  // Use high bit to distinguish
    case dirGenCount = 2 | 0x80
}

public enum APFSDirRecordType: UInt8, Sendable {
    case unknown = DT_UNKNOWN
    case fifo = DT_FIFO
    case characterDevice = DT_CHR
    case directory = DT_DIR
    case blockDevice = DT_BLK
    case regularFile = DT_REG
    case symlink = DT_LNK
    case socket = DT_SOCK
    case whiteout = DT_WHT
}

public enum APFSBSDFlag: UInt32, Sendable {
    case noDump = UF_NODUMP
    case immutable = UF_IMMUTABLE
    case appendOnly = UF_APPEND
    case opaque = UF_OPAQUE
    case hidden = UF_HIDDEN
    case compressed = UF_COMPRESSED
    case archived = SF_ARCHIVED
    case sysImmutable = SF_IMMUTABLE
    case sysAppend = SF_APPEND
    case dataLess = SF_DATALESS
}

// MARK: - Inode Internal Flags

public struct APFSInodeInternalFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    
    public static let isAPFSPrivate             = APFSInodeInternalFlags(rawValue: INODE_IS_APFS_PRIVATE)
    public static let maintainDirStats          = APFSInodeInternalFlags(rawValue: INODE_MAINTAIN_DIR_STATS)
    public static let dirStatsOrigin            = APFSInodeInternalFlags(rawValue: INODE_DIR_STATS_ORIGIN)
    public static let protClassExplicit         = APFSInodeInternalFlags(rawValue: INODE_PROT_CLASS_EXPLICIT)
    public static let wasCloned                 = APFSInodeInternalFlags(rawValue: INODE_WAS_CLONED)
    public static let wasPurged                 = APFSInodeInternalFlags(rawValue: INODE_WAS_PURGED)
    public static let hasSecurityEA             = APFSInodeInternalFlags(rawValue: INODE_HAS_SECURITY_EA)
    public static let beingTruncated            = APFSInodeInternalFlags(rawValue: INODE_BEING_TRUNCATED)
    public static let hasFinderInfo             = APFSInodeInternalFlags(rawValue: INODE_HAS_FINDER_INFO)
    public static let isSparse                  = APFSInodeInternalFlags(rawValue: INODE_IS_SPARSE)
    public static let wasEverCloned             = APFSInodeInternalFlags(rawValue: INODE_WAS_EVER_CLONED)
    public static let activeFileTrimmed         = APFSInodeInternalFlags(rawValue: INODE_ACTIVE_FILE_TRIMMED)
    public static let pinnedToMain              = APFSInodeInternalFlags(rawValue: INODE_PINNED_TO_MAIN)
    public static let pinnedToTier2             = APFSInodeInternalFlags(rawValue: INODE_PINNED_TO_TIER2)
    public static let hasRsrcFork               = APFSInodeInternalFlags(rawValue: INODE_HAS_RSRC_FORK)
    public static let noRsrcFork                = APFSInodeInternalFlags(rawValue: INODE_NO_RSRC_FORK)
    public static let allocationSpilledOver     = APFSInodeInternalFlags(rawValue: INODE_ALLOCATION_SPILLEDOVER)
    public static let fastPromote               = APFSInodeInternalFlags(rawValue: INODE_FAST_PROMOTE)
    public static let hasUncompressedSize       = APFSInodeInternalFlags(rawValue: INODE_HAS_UNCOMPRESSED_SIZE)
    public static let isPurgeable               = APFSInodeInternalFlags(rawValue: INODE_IS_PURGEABLE)
    public static let wantsToBePurgeable        = APFSInodeInternalFlags(rawValue: INODE_WANTS_TO_BE_PURGEABLE)
    public static let isSyncRoot                = APFSInodeInternalFlags(rawValue: INODE_IS_SYNC_ROOT)
    public static let snapshotCowExemption      = APFSInodeInternalFlags(rawValue: INODE_SNAPSHOT_COW_EXEMPTION)
    public static let protClassUpgradeRolling   = APFSInodeInternalFlags(rawValue: INODE_PROT_CLASS_UPGRADE_ROLLIP)
    public static let purgeableMarkChildren     = APFSInodeInternalFlags(rawValue: INODE_PURGEABLE_MARK_CHILDREN)
    public static let hasSourcePurgeID          = APFSInodeInternalFlags(rawValue: INODE_HAS_SOURCE_PURGE_ID)
    public static let hasAttributionTag         = APFSInodeInternalFlags(rawValue: INODE_HAS_ATTRIBUTION_TAG)
    public static let maintainSpeculativeTelemetry = APFSInodeInternalFlags(rawValue: INODE_MAINTAIN_SPECULATIVE_TELEMETRY)
    public static let speculativeTelemetryActive = APFSInodeInternalFlags(rawValue: INODE_SPECULATIVE_TELEMETRY_ACTIVE)
}

// MARK: - CloneGroup Flags

public struct APFSCloneGroupFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    public static let fullClone = APFSCloneGroupFlags(rawValue: UInt32(CLONEGROUP_FLAG_FULL_CLONE))
    public static let purgeableMask = APFSCloneGroupFlags(rawValue: UInt32(CLONEGROUP_FLAG_PURGEABLE_MASK))
}

// MARK: - Extended Field Flags

public struct APFSExtendedFieldFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    
    public static let dataDependent = APFSExtendedFieldFlags(rawValue: XF_DATA_DEPENDENT)
    public static let doNotCopy = APFSExtendedFieldFlags(rawValue: XF_DO_NOT_COPY)
    public static let btreeTracked = APFSExtendedFieldFlags(rawValue: XF_BTREE_TRACKED)
    public static let childrenInherit = APFSExtendedFieldFlags(rawValue: XF_CHILDREN_INHERIT)
    public static let userField = APFSExtendedFieldFlags(rawValue: XF_USER_FIELD)
    public static let systemField = APFSExtendedFieldFlags(rawValue: XF_SYSTEM_FIELD)
}

// MARK: - DECMPFS Compression Types

public enum DECMPFSCompressionType: UInt32, Sendable {
    case noneInline = 1
    case zlibInline = 3
    case zlibResourceFork = 4
    case dataless = 5
    case lzvnInline = 7
    case lzvnResourceFork = 8
    case uncompressedInline = 9
    case uncompressedResourceFork = 10
    case lzfseInline = 11
    case lzfseResourceFork = 12
    case lzbitmapInline = 13
    case lzbitmapResourceFork = 14
    
    public var isInline: Bool {
        return self.rawValue % 2 == 1
    }
    
    public var algorithmName: String {
        switch self {
        case .noneInline, .uncompressedInline: return "none"
        case .zlibInline, .zlibResourceFork: return "zlib"
        case .dataless: return "dataless"
        case .lzvnInline, .lzvnResourceFork: return "lzvn"
        case .uncompressedResourceFork: return "uncompressed"
        case .lzfseInline, .lzfseResourceFork: return "lzfse"
        case .lzbitmapInline, .lzbitmapResourceFork: return "lzbitmap"
        }
    }
}

// MARK: - DECMPFS Header

public struct DECMPFSHeader: Sendable {
    public let magic: UInt32
    public let compressionType: DECMPFSCompressionType
    public let uncompressedSize: UInt64
    public let attrData: Data
    
    public init(from data: Data) throws {
        guard data.count >= 24 else {
            throw APFSError.invalidDECMPFSHeader
        }
        self.magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let compTypeRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard magic == DECMPFS_MAGIC else {
            throw APFSError.invalidDECMPFSHeader
        }
        self.compressionType = DECMPFSCompressionType(rawValue: compTypeRaw) ?? .noneInline
        self.uncompressedSize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        self.attrData = data.dropFirst(24)
    }
}

// MARK: - Errors

public enum APFSError: Error, Sendable, CustomStringConvertible {
    case invalidDECMPFSHeader
    case parseError(String)
    case invalidRecordType(UInt8)
    case bufferTooSmall
    case crcMismatch
    
    public var description: String {
        switch self {
        case .invalidDECMPFSHeader: return "Invalid DECMPFS header (magic mismatch)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .invalidRecordType(let type): return "Invalid record type: \(type)"
        case .bufferTooSmall: return "Buffer too small for record"
        case .crcMismatch: return "CRC mismatch"
        }
    }
}
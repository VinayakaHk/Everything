# Everything for macOS (APFS) - Complete Technical Specification

## Overview

This document describes the architecture for **Everything-macOS** — a hypothetical instant file search engine for macOS built on APFS internals, mirroring the design principles of voidtools Everything for Windows/NTFS.

**Key Characteristics:**
- **Speed**: Indexes millions of files in seconds; searches return in milliseconds
- **Architecture**: Swift/Objective-C/C++ hybrid; leverages APFS B-Tree structures directly
- **Privilege Model**: Standard user process + privileged helper (XPC) for raw APFS access
- **Platform**: macOS 11+ (Big Sur), APFS volumes only (HFS+ not supported for instant indexing)
- **License**: Open source (MIT/Apache-2.0)

---

## Core Architecture: Three Pillars

### 1. APFS File System Tree (FS-Tree) Direct Enumeration

Instead of `find`/`readdir` traversal, Everything-macOS reads the **APFS File System Tree (FS-Tree)** directly — the on-disk B-Tree containing all inode and directory records.

#### FS-Tree Structure (from APFS Internals)
```
Container (NX Superblock)
  └── Volume Superblock
        └── FS-Tree (B-Tree, virtual, Object Map-backed)
              ├── Inode Records (APFS_TYPE_INODE = 3)
              ├── Directory Records (APFS_TYPE_DIR_REC = 9)
              ├── Extent Records (APFS_TYPE_FILE_EXTENT = 8)
              ├── Xattr Records (APFS_TYPE_XATTR = 4)
              ├── Sibling Links (APFS_TYPE_SIBLING_LINK = 5)
              ├── Clonegroup Records (OBJECT_TYPE_CLONEGROUP_TREE)
              └── Snapshot Metadata (APFS_TYPE_SNAP_METADATA = 1)
```

#### Key Encoding
```c
// 64-bit composite key: obj_id (60 bits) | type (4 bits)
#define OBJ_TYPE_SHIFT 60
#define OBJ_TYPE_MASK  0xF000000000000000
#define OBJ_ID_MASK    0x0FFFFFFFFFFFFFFF

typedef struct {
    uint64_t obj_id_and_type;  // inode number in low 60 bits, record type in high 4
} j_key_t;
```

#### Inode Record (j_inode_val_t) - 92+ bytes
```c
typedef struct {
    uint64_t parent_id;           // Parent directory inode
    uint64_t private_id;          // Data stream ID (for clones)
    uint64_t create_time;         // Seconds since epoch (macOS 10.13+)
    uint64_t mod_time;            // Seconds since epoch
    uint64_t change_time;         // Seconds since epoch (metadata change)
    uint64_t access_time;         // Seconds since epoch
    uint64_t internal_flags;      // INODE_* flags (see below)
    int32_t  nlink;               // Hard link count
    uint32_t write_generation_counter;  // Incremented on each write (st_gen)
    uint32_t bsd_flags;           // UF_IMMUTABLE, UF_APPEND, UF_COMPRESSED, etc.
    uid_t    owner;
    gid_t    group;
    mode_t   mode;                // File type + permissions
    uint64_t uncompressed_size;   // For DECMPFS compressed files (valid when INODE_HAS_UNCOMPRESSED_SIZE set)
    // Extended fields follow (xfields)
} j_inode_val_t;
```

#### Directory Record (j_drec_val_t) - 18+ bytes
```c
typedef struct {
    uint64_t file_id;       // Target inode number
    uint64_t date_added;    // When entry added to directory
    uint16_t flags;         // DT_DIR, DT_REG, DT_LNK, etc. (low 4 bits)
    // Extended fields follow
} j_drec_val_t;
```

#### Directory Record Key (hashed for case-insensitive volumes)
```c
typedef struct {
    j_key_t hdr;                // obj_id = parent inode, type = DIR_REC
    uint32_t name_len_and_hash; // 10 bits len | 22 bits CRC-32C(NFD+casefold)
    uint8_t name[];             // UTF-8 null-terminated
} j_drec_hashed_key_t;
```

#### Initial Enumeration Algorithm
```swift
// 1. Open volume raw device: /dev/diskXsY (requires root/helper)
let volumeFD = open("/dev/disk3s1", O_RDONLY | O_NOFOLLOW)

// 2. Read NX Superblock (block 0) -> Container Superblock -> Volume Superblock
//    Volume Superblock.apfs_fstree_oid = virtual OID of FS-Tree root
//    Use Object Map (OMAP) to resolve virtual OID -> physical block

// 3. Iterate FS-Tree B-Tree in key order:
//    - Keys are ordered by (inode_id, record_type)
//    - All records for one inode are contiguous
//    - Inode record comes first (APFS_TYPE_INODE = 3)
//    - Then DIR_REC children, EXTENT, XATTR, SIBLING_LINK, etc.

// 4. Build in-memory index:
//    INODE record -> create Node { inode_id, parent_id, timestamps, mode, size, flags }
//    DIR_REC -> link child to parent, store name
//    SIBLING_LINK -> track hard links (multiple DIR_REC per inode)
```

#### In-Memory Index Structures
```swift
struct FSNode {
    let inodeID: UInt64          // 64-bit APFS inode number (st_ino)
    let parentID: UInt64         // Parent directory inode
    let privateID: UInt64        // Data stream ID (for clones)
    let name: String             // UTF-8 name (from DIR_REC or INO_EXT_TYPE_NAME)
    let createTime: UInt64       // Seconds since epoch (st_birthtime)
    let createTimeNsec: UInt32   // Nanoseconds (st_birthtime_nsec)
    let modTime: UInt64          // Seconds since epoch (st_mtime)
    let modTimeNsec: UInt32      // Nanoseconds (st_mtime_nsec)
    let changeTime: UInt64       // Seconds since epoch (st_ctime)
    let changeTimeNsec: UInt32   // Nanoseconds (st_ctime_nsec)
    let accessTime: UInt64       // Seconds since epoch (st_atime)
    let accessTimeNsec: UInt32   // Nanoseconds (st_atime_nsec)
    let fileSize: UInt64         // Logical size (st_size)
    let uncompressedSize: UInt64 // For compressed files (DECMPFS)
    let mode: UInt16             // S_IFDIR, S_IFREG, S_IFLNK (st_mode)
    let flags: UInt64            // INODE_* internal flags
    let bsdFlags: UInt32         // UF_* / SF_* flags (st_flags)
    let owner: uid_t             // st_uid
    let group: gid_t             // st_gid
    let writeGen: UInt32         // Write generation counter (st_gen)
    let cloneGroupID: UInt64?    // INO_EXT_TYPE_CLONEGROUP_ID
    let hardLinkCount: Int32     // nlink from inode (st_nlink)
    let volumeID: UInt32         // st_dev (32-bit volume identifier)
    let apfsVolumeUUID: UUID     // APFS volume UUID (128-bit)
    let volfsVolumeID: UInt32?   // volfs volume ID (for /.vol/ paths)
    let filerefVolumeID: UInt32? // File Reference URL volume ID (for file:///.file/id=)
    // Computed:
    let path: String             // Reconstructed from parent chain
    let depth: Int               // Directory depth
}

// Sorted arrays for O(log n) prefix search:
var nodesByName: [FSNode]        // Sorted by name (for prefix search)
var nodesByPath: [FSNode]        // Sorted by full path
var nodesByInode: [UInt64: FSNode]  // Direct inode lookup
var nodesByParent: [UInt64: [FSNode]] // Children per parent

// Fast-sort auxiliary indexes (optional, like Everything):
var nodesBySize: [FSNode]        // Sorted by fileSize
var nodesByModTime: [FSNode]     // Sorted by modTime
var nodesByCreateTime: [FSNode]  // Sorted by createTime
var nodesByExtension: [FSNode]   // Sorted by extension
```

---

### 2. Real-Time Monitoring: EndpointSecurity + FSEvents Hybrid

macOS provides two complementary monitoring APIs:

#### EndpointSecurity (macOS 10.15+) — Primary
```swift
import EndpointSecurity

// Subscribe to filesystem events with minimal latency
let client = try ESClient.newClient { client, message in
    switch message.eventType {
    case .create, .createDir, .createFile, .createSymlink:
        // New file/dir - add to index
        handleCreate(message)
    case .delete, .deleteDir, .deleteFile:
        // Removed - mark deleted in index
        handleDelete(message)
    case .rename:
        // Moved/renamed - update path in index
        handleRename(message)
    case .write, .truncate, .extend:
        // Size/timestamp change - update if indexed
        handleWrite(message)
    case .setattr, .chmod, .chown, .setxattr, .removexattr:
        // Metadata change - update if indexed
        handleSetAttr(message)
    case .clone:
        // APFS clone (cp --clone, clonefile) - track clonegroup
        handleClone(message)
    case .snapshot:
        // Snapshot created/deleted
        handleSnapshot(message)
    default:
        break
    }
}

// Required entitlements:
// com.apple.developer.endpoint-security.client
// com.apple.developer.endpoint-security.system-extension (for kernel-level)
```

**Event Data Available:**
```c
typedef struct es_event_create_t {
    es_file_t *target;        // New file
    es_file_t *source;        // Source (for clone/link)
    uint32_t options;         // O_CREAT, O_EXCL, etc.
} es_event_create_t;

typedef struct es_event_rename_t {
    es_file_t *source;        // Old location
    es_file_t *target;        // New location
} es_event_rename_t;

typedef struct es_file_t {
    es_file_id_t file_id;     // {dev, ino} - stable across renames!
    char *path;               // Current path
    // ... timestamps, mode, uid, gid, size, etc.
} es_file_t;
```

**Key Advantage:** `es_file_t.stat` provides `st_dev` (i32) + `st_ino` (u64) — stable file identity (like NTFS FRN)!
// Note: `st_dev` is 32-bit volume ID, `st_ino` is 64-bit inode number

#### FSEvents (Legacy/Supplemental) — Directory-Level
```c
// Coarser granularity: directory-level change notifications
FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                    pathsToWatch, kFSEventStreamEventIdSinceNow,
                    latency, kFSEventStreamCreateFlagUseCFTypes | 
                               kFSEventStreamCreateFlagFileEvents |
                               kFSEventStreamCreateFlagWatchRoot)

// Flags of interest:
kFSEventStreamEventFlagItemCreated
kFSEventStreamEventFlagItemRemoved
kFSEventStreamEventFlagItemRenamed
kFSEventStreamEventFlagItemModified
kFSEventStreamEventFlagItemInodeMetaMod
kFSEventStreamEventFlagItemFinderInfoMod
kFSEventStreamEventFlagItemChangeOwner
kFSEventStreamEventFlagItemXattrMod
kFSEventStreamEventFlagItemIsDir
kFSEventStreamEventFlagItemIsSymlink
kFSEventStreamEventFlagItemIsHardlink
kFSEventStreamEventFlagItemIsFile
```

**Use FSEvents for:** Network volumes (SMB/NFS), non-APFS volumes, fallback when ES unavailable.

#### Hybrid Monitoring Strategy
```
APFS Volumes (local):
  Primary: EndpointSecurity (file-level, low latency, stable file IDs)
  Fallback: FSEvents (if ES fails)

Non-APFS / Network:
  Primary: FSEvents (directory-level)
  Fallback: Polling + getattrlistbulk (for FAT/exFAT/SMB)

Snapshots:
  Read-only - index once, no monitoring needed
```

#### Volume Identity Mapping

APFS uses multiple volume identifiers that must be correlated:

```swift
struct VolumeIdentity {
    let apfsUUID: UUID           // APFS volume UUID (from volume superblock)
    let volfsID: UInt32          // volfs volume ID (e.g., 16777240) for /.vol/ paths
    let filerefID: UInt32        // File Reference URL volume ID (e.g., 6571367) for file:///.file/id=
    let deviceID: dev_t          // st_dev from stat() / EndpointSecurity (32-bit)
    let mountPoint: String       // e.g., "/", "/Volumes/Data"
}

// Mapping table maintained by indexer:
// deviceID (st_dev) → VolumeIdentity
// inodeID + deviceID → FSNode (globally unique)
```

---

### 3. In-Memory Index with Bytecode Search

Identical to Windows Everything: compile search queries to bytecode, execute against sorted arrays.

#### Search Query AST → Bytecode
```swift
enum SearchOpcode {
    case matchName(prefix: String)           // Prefix B-tree search
    case matchPath(prefix: String)           // Full path prefix
    case matchExtension(String)              // Exact extension
    case matchRegex(NSRegularExpression)     // Regex
    case filterSize(range: ClosedRange<UInt64>)  // Binary search on size index
    case filterModTime(range: ClosedRange<UInt64>) // Binary search on time index
    case filterCreateTime(range: ClosedRange<UInt64>)
    case filterAttribute(attributes: UInt32) // Bitmask
    case filterType(fileType: FileType)      // file/dir/symlink
    case filterCloneGroup(UInt64)            // Clone group ID
    case filterHardLinkCount(Int)            // nlink > 1
    case filterOwner(uid_t)
    case filterContent(String)               // Delegate to Spotlight/mdfind
    case and, or, not
    case groupStart, groupEnd
    case sortBy(Property, ascending: Bool)
    case limit(Int)
    case offset(Int)
}
```

#### Query Execution
```swift
func execute(query: SearchQuery) -> [SearchResult] {
    // 1. Start with candidate set (all nodes or name prefix filter)
    var candidates = namePrefixFilter(query.namePrefix) 
        // O(log n) binary search on nodesByName
    
    // 2. Apply indexed filters (fast, no allocation):
    if query.hasSizeFilter {
        candidates = intersect(candidates, sizeRangeFilter(query.sizeRange))
            // Binary search on nodesBySize
    }
    if query.hasTimeFilter {
        candidates = intersect(candidates, timeRangeFilter(query.timeRange))
            // Binary search on nodesByModTime/CreateTime
    }
    
    // 3. Apply non-indexed filters (linear scan of candidates):
    candidates = candidates.filter { node in
        query.nonIndexedFilters.allSatisfy { $0.matches(node) }
    }
    
    // 4. Sort (use fast-sort index if available, else quicksort):
    if let sort = query.sort, fastSortEnabled[sort.property] {
        candidates = fastSort(candidates, by: sort)
    } else {
        candidates.sort(by: query.sortComparator)
    }
    
    // 5. Apply offset/limit
    return Array(candidates.dropFirst(query.offset).prefix(query.limit))
}
```

---

## Database Persistence (Everything.db equivalent)

### Format: Custom Binary + Compression
```swift
struct DatabaseHeader {
    let magic: UInt32 = 0x41504653  // "APFS"
    let version: UInt32 = 0x01000001
    let flags: UInt32               // Compression, encryption, etc.
    let volumeCount: UInt32
    let nodeCount: UInt32
    let creationTime: UInt64        // Host timestamp
    let volumeTableOffset: UInt64
    let excludeListOffset: UInt64
    let nodeTableOffset: UInt64
    let propertyIndexesOffset: UInt64
    let stringTableOffset: UInt64
}

struct VolumeEntry {
    let volumeUUID: UUID            // APFS volume UUID
    let volumeName: String
    let lastUSN: UInt64             // EndpointSecurity event sequence?
    let lastFSEventID: FSEventStreamEventId
    let isEncrypted: Bool
    let isSnapshot: Bool
    let rootInodeID: UInt64         // Usually 2 (ROOT_DIR_INO_NUM)
}

struct NodeEntry {
    let inodeID: UInt64
    let parentID: UInt64
    let privateID: UInt64
    let nameOffset: UInt32          // Offset in string table
    let nameLength: UInt16
    let createTime: UInt64
    let modTime: UInt64
    let changeTime: UInt64
    let accessTime: UInt64
    let fileSize: UInt64
    let uncompressedSize: UInt64
    let mode: UInt16
    let internalFlags: UInt64
    let bsdFlags: UInt32
    let owner: UInt32
    let group: UInt32
    let writeGen: UInt32
    let cloneGroupID: UInt64
    let hardLinkCount: Int32
    // Variable: extended attributes, xattrs, etc.
}
```

### Compression
- **LZ4** for speed (decompress ~4 GB/s) or **ZSTD** for ratio
- Delta-encode timestamps, inode IDs, parent IDs
- String table with prefix compression for paths/names
- Expected ratio: 8-12:1 (similar to Everything's BZIP2)

### Save/Load Strategy
- Memory-map on load (`mmap`)
- Background save timer (every 30s) + on clean exit
- Incremental: only dirty pages written
- Atomic write: write to `.tmp`, `rename()` to final

---

## APFS-Specific Features

### 1. Clones (copy-on-write)
```swift
// Detect clones via INO_EXT_TYPE_CLONEGROUP_ID extended field
// Clonegroup tree tracks shared extents (record_type=1 mapping, record_type=2 cookie)
struct CloneGroup {
    let groupID: UInt64
    let fullCloneInode: UInt64      // Owns physical extents (CLONEGROUP_FLAG_FULL_CLONE = 0x10)
    let partialClones: [UInt64]     // Copy-on-write references (physical_size = 0)
    let sharedPhysicalSize: UInt64  // Actual disk space shared (from full clone's physical_size)
}

// Clonegroup mapping key (from Joe Sylve blog):
// struct clonegroup_mapping_key { group_id, record_type=1, inode_id, private_id }
// clonegroup_val { physical_size, flags, xfields }

// Search functions:
func clonegroup(id: UInt64) -> [FSNode]     // All members of clone group
func isClone(_ node: FSNode) -> Bool        // Has cloneGroupID
func sharedSpace(_ node: FSNode) -> UInt64  // Physical bytes shared
```

### 2. Snapshots
```swift
// APFS snapshots are read-only FS-Tree checkpoints
// Access via: /Volumes/VolumeName/.snapshots/SnapshotName/
// Or mount with: mount_apfs -s snapshot_name /dev/diskXsY /mnt

struct SnapshotIndex {
    let snapshotUUID: UUID
    let creationTime: UInt64
    let name: String
    // Separate node table (read-only)
    let nodes: [FSNode]
}

// Search: snapshot:"Name" or snapshot:uuid
// Use case: Time Machine browsing, backup verification
```

### 3. Hard Links & Siblings
```swift
// APFS: multiple DIR_REC entries pointing to same inode
// SIBLING_LINK record maps inode -> all directory entries
// INODE.nlink = hard link count

func hardLinks(_ node: FSNode) -> [FSNode] {
    // All directory entries with same inodeID
    return inodeToDirEntries[node.inodeID] ?? []
}

func siblingPaths(_ node: FSNode) -> [String] {
    return hardLinks(node).map { $0.path }
}
```

### 4. File Reference URLs (Persistent Identity)
```swift
// file:///.file/id=FILEREF_VOLUME_ID.INODE_ID
// Stable across moves/renames on same volume
// Equivalent to NTFS FRN
// Note: File Reference URL volume ID DIFFERS from volfs volume ID

func fileReferenceURL(_ node: FSNode) -> URL {
    guard let filerefID = node.filerefVolumeID else { return URL(fileURLWithPath: node.path) }
    return URL(string: "file:///.file/id=\(filerefID).\(node.inodeID)")!
}

func resolveFileReferenceURL(_ url: URL) -> FSNode? {
    // Parse: file:///.file/id=VOLUME.INODE
    // Map fileref volume ID -> deviceID -> lookup (deviceID, inodeID) in index
    // Falls back to GetFileInfo /.vol/volfs_volume_id/inode
}

// volfs path: /.vol/VOLFS_VOLUME_ID/INODE_ID
func volfsPath(_ node: FSNode) -> String {
    guard let volfsID = node.volfsVolumeID else { return node.path }
    return "/.vol/\(volfsID)/\(node.inodeID)"
}
```

### 5. Transparent Compression (DECMPFS)
```swift
// Check the `UF_COMPRESSED` flag (bit 5 of `bsd_flags` in `j_inode_val_t`).
// Check `INODE_HAS_UNCOMPRESSED_SIZE` (0x40000) in `internal_flags` for uncompressed_size validity.
// Read the `com.apple.decmpfs` extended attribute from the File System Tree (xattr).
// Verify `compression_magic` equals `DECMPFS_MAGIC` (0x636d7066 = 'cmpf').
// Read `compression_type` to determine algorithm and data location:
//   Odd types (3,7,9,11,13) = inline in xattr
//   Even types (4,8,10,12,14) = resource fork (com.apple.ResourceFork xattr)
//   Types 0x80000001/0x80000002 = dataless (iCloud/network placeholder)
// Locate compressed data and decompress.

// Resource fork chunking (DECMPFS):
//   Type 4 (zlib): Fixed-offset scheme - 256-byte header at 0x104, chunk table [offset, length]
//   Types 8,10,12,14: Absolute-offset scheme - offset array at byte 0, chunk i = [offsets[i], offsets[i+1])
//   Chunk size: 64KB (65536 bytes)
//   Uncompressed chunk marker: zlib/LZFSE/LZBITMAP=0xFF, LZVN=0x06, none=0xCC
```

### 6. Encryption (FileVault / Per-file)
```swift
// APFS_INCOMPAT_ENCRYPTED flag on volume
// Per-file: INODE.internal_flags has INODE_HAS_CRYPTO_STATE
// CRYPTO_STATE record (APFS_TYPE_CRYPTO_STATE = 7)

// Indexing encrypted volumes:
// - Requires volume unlocked (mounted)
// - Metadata visible, content search requires file open
// - Can index names, sizes, timestamps without decryption
```

---

## Network & Non-APFS Volumes

### Folder Indexing (like Everything's folder indexing)
```swift
// For SMB, NFS, FAT32, exFAT, HFS+, WebDAV
// Uses getattrlistbulk + FSEvents polling

struct FolderIndexConfig {
    let url: URL                    // File URL to index
    let updateInterval: TimeInterval // e.g., 300s (5 min)
    let rescanOnFullBuffer: Bool
    let monitorChanges: Bool         // FSEvents
    let includeHidden: Bool
    let excludePatterns: [String]    // Glob patterns
}

func scanFolder(_ config: FolderIndexConfig) {
    let fd = open(config.url.path, O_RDONLY | O_DIRECTORY)
    var attrList = makeAttrList(
        common: .returnedAttrs | .name | .objType | .error,
        file: .size | .dataModTime | .createTime | .accessTime | .owner | .group | .mode,
        dir: .linkCount
    )
    
    while true {
        let count = getattrlistbulk(fd, &attrList, &buffer, bufferSize, 0)
        if count <= 0 { break }
        parseEntries(buffer, count: count)
    }
    close(fd)
}
```

### Cloud Sync (FileProvider)
```swift
// iCloud Drive, Dropbox, OneDrive, etc. use FileProvider extension
// Files may be "online-only" (placeholder) or "downloaded"

// NSFileProviderManager APIs:
let manager = NSFileProviderManager(for: domain)
manager.enumerateItems(at: url) { items, error in
    for item in items {
        // item.filename, item.size, item.contentType
        // item.isDownloaded, item.isDownloading
        // item.parentItemIdentifier
    }
}

// Search integration:
// - Index placeholder metadata (name, size, dates) always
// - Content search only for downloaded files
// - "online-only:" search filter
```

---

## Search Syntax (macOS Adaptation)

### Operators (same as Windows Everything)
| Operator | Meaning |
|----------|---------|
| ` ` (space) | AND |
| `\|` | OR |
| `!` | NOT |
| `< >` | Grouping |
| `"` | Literal |

### Modifiers
| Modifier | Description |
|----------|-------------|
| `case:` / `nocase:` | Case sensitivity (APFS is case-insensitive by default) |
| `diacritics:` / `nodiacritics:` | Diacritic sensitivity |
| `wholeword:` / `nowholeword:` | Whole word |
| `path:` / `nopath:` | Full path match |
| `regex:` / `noregex:` | Regular expression (ICU/NSRegularExpression) |

### APFS-Specific Functions
| Function | Description |
|----------|-------------|
| `inode:<num>` | Search by inode number |
| `frn:<num>` | Alias for inode (NTFS compat) |
| `clonegroup:<id>` | Files in clone group |
| `isclone:` | Files that are clones |
| `sharedspace:>100mb` | Clone shared physical space |
| `snapshot:"Name"` | Search within snapshot |
| `voluuid:<UUID>` | Limit to volume UUID |
| `writegen:>100` | Write generation counter |
| `bsdflags:uchg` | BSD flags (uchg, uappnd, schg, etc.) |
| `bsdflags:dataless` | FileProvider dataless placeholder (SF_DATALESS) |
| `compressed:` | DECMPFS compressed files |
| `encrypted:` | Per-file encrypted |
| `onlineonly:` | FileProvider placeholder |
| `downloaded:` | FileProvider downloaded |

### Standard Functions (ported from Windows)
| Function | Description |
|----------|-------------|
| `name:`, `stem:` | Filename / name without extension |
| `ext:`, `extension:` | Extension |
| `parent:`, `location:` | Parent directory |
| `size:`, `size-on-disk:` | Logical / physical size |
| `date-modified:`, `dm:` | Modification time |
| `date-created:`, `dc:` | Creation time |
| `date-accessed:`, `da:` | Access time |
| `date-changed:` | Metadata change time (ctime) |
| `attributes:`, `attr:` | BSD flags |
| `kind:` | File kind (UTI) |
| `content:` | Spotlight content search |
| `md5:`, `sha1:`, `sha256:` | Hash (on-demand) |
| `width:`, `height:`, `dimensions:` | Image dimensions |
| `duration:`, `length:` | Media duration |
| `dupe:`, `distinct:`, `unique:` | Duplicate detection |

### macOS-Specific Metadata (via Spotlight/MDItem)
```swift
// Bridge to Spotlight for rich metadata
func spotlightAttributes(_ node: FSNode) -> [String: Any] {
    let url = URL(fileURLWithPath: node.path)
    let attrs = MDItemCopyAttributes(MDItemCreate(nil, url as CFURL), nil)
    return attrs as? [String: Any] ?? [:]
}

// Available: kMDItemAuthors, kMDItemKeywords, kMDItemComment,
// kMDItemCameraModel, kMDItemFNumber, kMDItemExposureTime,
// kMDItemISOSpeed, kMDItemOrientation, kMDItemPixelWidth/Height,
// kMDItemDurationSeconds, kMDItemCodecs, kMDItemBitRate,
// kMDItemMusicalGenre, kMDItemAlbum, kMDItemArtist, ...
```

---

## IPC / SDK (macOS Equivalent)

### XPC Service (Privileged Helper)
```swift
// EverythingHelper.xpc (runs as root via SMJobBless)
// Provides: raw APFS access, EndpointSecurity subscription

protocol EverythingHelperProtocol {
    // Volume enumeration
    func enumerateVolumes(completion: @escaping ([VolumeInfo]) -> Void)
    
    // Raw FS-Tree scan (initial index)
    func scanVolume(volumeUUID: UUID, 
                    progress: @escaping (Double) -> Void,
                    completion: @escaping (Result<[FSNode], Error>) -> Void)
    
    // File ID lookup (like OpenByFileID)
    func resolveFileID(volumeUUID: UUID, inodeID: UInt64, 
                       completion: @escaping (String?) -> Void)
    
    // EndpointSecurity subscription
    func subscribeToEvents(_ events: [ES.EventType], 
                           handler: @escaping (ESMessage) -> Void)
    
    // Snapshot management
    func listSnapshots(volumeUUID: UUID, 
                       completion: @escaping ([SnapshotInfo]) -> Void)
    func mountSnapshot(volumeUUID: UUID, snapshotUUID: UUID, 
                       mountPoint: String, 
                       completion: @escaping (Error?) -> Void)
}

// Client connects via NSXPCConnection
let connection = NSXPCConnection(machServiceName: "com.everything.helper",
                                  options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: EverythingHelperProtocol.self)
connection.resume()
let helper = connection.remoteObjectProxy as! EverythingHelperProtocol
```

### Public Search API (for Apps)
```swift
// Distributed via Swift Package Manager
public struct EverythingSearch {
    public static func search(_ query: String, 
                              options: SearchOptions = .default) 
                              async throws -> [SearchResult]
    
    public static func searchAsync(_ query: String,
                                   options: SearchOptions,
                                   handler: @escaping (SearchResult) -> Void)
    
    public static func openResult(_ result: SearchResult)
    public static func revealInFinder(_ result: SearchResult)
}

// Command-line tool: `everything`
// everything "query" --json --limit 100 --sort size-desc
```

---

## Configuration (Everything.plist / JSON)

```json
{
  "general": {
    "runAtLogin": true,
    "showMenuBarIcon": true,
    "hotkey": "⌘⇧Space",
    "language": "en"
  },
  "indexing": {
    "includeAPFSVolumes": true,
    "includeSnapshots": false,
    "includeNetworkVolumes": false,
    "folderIndexes": [
      { "path": "/Volumes/External", "interval": 300, "monitor": true }
    ],
    "excludePaths": [
      "/System/Volumes/VM",
      "/private/var/vm",
      "*/.Trash",
      "*/.Spotlight-V100",
      "*/.fseventsd"
    ],
    "excludePatterns": [
      "*.tmp", "*.temp", "*.cache", "*.log",
      "*.dSYM", "*.build", "DerivedData"
    ],
    "indexProperties": {
      "size": true,
      "dates": ["created", "modified", "accessed", "changed"],
      "attributes": true,
      "hardLinks": true,
      "clones": true,
      "extendedAttributes": false,
      "finderInfo": false
    },
    "fastSort": {
      "size": true,
      "modified": true,
      "created": true,
      "extension": false,
      "path": false
    }
  },
  "monitoring": {
    "useEndpointSecurity": true,
    "fallbackToFSEvents": true,
    "latency": 0.1,
    "batchEvents": true
  },
  "search": {
    "defaultOperator": "AND",
    "caseSensitive": false,
    "diacriticsSensitive": false,
    "wholeWord": false,
    "matchPath": false,
    "regex": false,
    "maxResults": 1000
  },
  "ui": {
    "theme": "system",
    "showPreview": true,
    "showThumbnails": true,
    "thumbnailSize": 128,
    "columns": ["name", "size", "modified", "kind", "path"],
    "sortBy": "name",
    "sortAscending": true
  },
  "advanced": {
    "databasePath": "~/Library/Application Support/Everything/Everything.db",
    "maxMemoryMB": 512,
    "compression": "lz4",
    "debugLogging": false
  }
}
```

---

## Performance Characteristics

| Metric | Target |
|--------|--------|
| Initial index (1M files, APFS SSD) | 3-8 seconds |
| Initial index (5M files) | 15-30 seconds |
| Search latency (name prefix) | < 5 ms |
| Search latency (with size/date filter) | < 20 ms |
| Memory (name only, 1M files) | ~80 MB |
| Memory (all props, 1M files) | ~300 MB |
| Database size (1M files, LZ4) | ~25 MB |
| ES event processing latency | < 1 ms per event |
| Index update (create/delete/rename) | < 100 µs |

### Memory Optimization
```swift
// Disable unused indexes
indexProperties.size = false
indexProperties.dates = []
indexProperties.attributes = false
fastSort = [:]  // Disable all fast-sort indexes
```

---

## Security Model

### Privilege Separation
```
┌─────────────────────────────────────┐
│  Everything.app (User, Sandboxed)   │
│  - UI, search, settings             │
│  - XPC client to Helper             │
└──────────────┬──────────────────────┘
               │ XPC (NSXPCConnection)
               ▼
┌─────────────────────────────────────┐
│  EverythingHelper.xpc (Root, Unsanitized) │
│  - Raw block device access (/dev/diskXsY) │
│  - EndpointSecurity subscription         │
│  - Snapshot mount/unmount                │
│  - File ID resolution                    │
└─────────────────────────────────────┘
```

### Entitlements
```xml
<!-- Everything.app -->
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.network.client</key><true/>  <!-- ETP/HTTP server -->

<!-- EverythingHelper.xpc -->
<key>com.apple.developer.endpoint-security.client</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
```

### Data Protection
- Database encrypted with FileVault (user's keychain)
- No network traffic unless ETP/HTTP server explicitly enabled
- No telemetry, no analytics
- Sandbox prevents access to non-indexed paths

---

## Limitations & Known Issues

| Limitation | Mitigation |
|------------|------------|
| **APFS only for instant indexing** | Folder indexing for HFS+/FAT/exFAT/network |
| **Requires helper tool (root)** | SMJobBless installation, notarized |
| **EndpointSecurity requires macOS 10.15+** | FSEvents fallback for 10.13-10.14 |
| **Encrypted volumes: content search needs unlock** | Index metadata only when locked |
| **Clones: shared space accounting complex** | Track via clonegroup tree |
| **Snapshots: read-only, no monitoring** | Index on demand |
| **FileProvider: online-only placeholders** | Distinguish with `onlineonly:` / `bsdflags:dataless` filters |
| **Case-insensitive by default** | `case:` modifier for exact match (requires `APFS_INCOMPAT_CASE_INSENSITIVE` volume) |
| **No USN Journal equivalent** | EndpointSecurity + FSEvents hybrid |
| **Hard links across volumes impossible** | APFS constraint |
| **File Reference URL volume ID != volfs volume ID** | Maintain separate mapping tables |
| **st_dev is 32-bit in EndpointSecurity** | Use dev_t (64-bit) from stat() for full compatibility |
| **APFS timestamps: separate sec + nsec fields** | Store both for nanosecond precision |

---

## Comparison: Windows Everything vs macOS APFS Everything

| Aspect | Windows (NTFS) | macOS (APFS) |
|--------|----------------|--------------|
| **Primary Index Source** | MFT (Master File Table) | FS-Tree (File System Tree) |
| **File ID** | FRN (64-bit) | Inode (64-bit) + st_dev (32-bit) |
| **Change Monitoring** | USN Change Journal | EndpointSecurity + FSEvents |
| **File ID Stability** | Stable across moves/renames | Stable (es_file_id_t) |
| **Clones/Hard Links** | Hard links, no clones | Hard links + APFS clones |
| **Snapshots** | VSS (Volume Shadow Copy) | APFS native snapshots |
| **Compression** | NTFS compression | DECMPFS (transparent) |
| **Encryption** | BitLocker (volume) | FileVault (volume) + per-file |
| **Network Volumes** | Folder indexing + ETP | Folder indexing + FileProvider |
| **Content Search** | iFilter (slow) | Spotlight (CoreSpotlight) |
| **Privilege Separation** | Service (SYSTEM) + User | XPC Helper (root) + User |
| **IPC** | WM_COPYDATA | XPC / Mach messages |
| **Database** | Everything.db (BZIP2) | Everything.db (LZ4/ZSTD) |
| **Timestamp Precision** | 100ns intervals (FILETIME) | Seconds + nanoseconds (st_*time + st_*time_nsec) |
| **Volume ID Mapping** | Single (drive letter) | Triple (APFS UUID, volfs ID, fileref ID) |

---

## Implementation Roadmap

### Phase 1: Core Indexing (MVP)
- [ ] Privileged helper (XPC) with SMJobBless
- [ ] APFS FS-Tree enumeration via raw device
- [ ] In-memory index with name/path prefix search
- [ ] Basic UI: search box, results list, open/reveal
- [ ] Database persistence (LZ4)

### Phase 2: Real-Time Updates
- [ ] EndpointSecurity subscription
- [ ] FSEvents fallback
- [ ] Incremental index updates
- [ ] Menu bar / hotkey integration

### Phase 3: Advanced Features
- [ ] Fast-sort indexes (size, dates)
- [ ] Clone/hard link detection
- [ ] Snapshot browsing
- [ ] FileReferenceURL support
- [ ] Command-line tool (`everything`)

### Phase 4: Network & Cloud
- [ ] Folder indexing (getattrlistbulk)
- [ ] FileProvider integration
- [ ] ETP/HTTP server plugins
- [ ] Everything Server equivalent (TLS + index sync)

### Phase 5: Polish
- [ ] Thumbnails/preview (QuickLook)
- [ ] Bookmarks, filters, run history
- [ ] Advanced search syntax
- [ ] Plugin SDK
- [ ] Localization

---

## File Locations

| File | Location |
|------|----------|
| Everything.app | `/Applications/Everything.app` |
| Helper tool | `/Library/PrivilegedHelperTools/com.everything.helper` |
| LaunchDaemon | `/Library/LaunchDaemons/com.everything.helper.plist` |
| Database | `~/Library/Application Support/Everything/Everything.db` |
| Config | `~/Library/Preferences/com.everything.Everything.plist` |
| Logs | `~/Library/Logs/Everything/` |
| Plugins | `~/Library/Application Support/Everything/Plugins/` |

---

## Conclusion

An "Everything for macOS" built on APFS internals would leverage:

1. **FS-Tree direct enumeration** — bypass VFS layer, read B-Tree nodes via Object Map
2. **EndpointSecurity** — file-level, low-latency, stable file identity monitoring
3. **In-memory bytecode search** — O(1) name lookup, O(log n) property filters
4. **APFS-native features** — clones, snapshots, encryption, compression, file reference URLs

This architecture achieves the same **instant search** experience as Windows Everything, while integrating deeply with macOS-specific filesystem capabilities (FileProvider, QuickLook, Spotlight metadata bridge, Time Machine snapshots).

The key difference from NTFS: **APFS uses inode-based identity (stable) + B-Tree enumeration** vs **NTFS uses FRN + MFT linear scan**. Both achieve the same goal: a complete filesystem metadata image in memory.
#ifndef EverythingAPFS_apfs_structs_h
#define EverythingAPFS_apfs_structs_h

#include <stdint.h>
#include <stdbool.h>
#include <uuid/uuid.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// APFS Constants (from Apple File System Reference & Joe Sylve's blog)
// ============================================================================

// Object types (high 4 bits of j_key_t.obj_id_and_type)
#define APFS_TYPE_SNAP_METADATA       1
#define APFS_TYPE_EXTENT              2
#define APFS_TYPE_INODE               3
#define APFS_TYPE_XATTR               4
#define APFS_TYPE_SIBLING_LINK        5
#define APFS_TYPE_DSTREAM_ID          6
#define APFS_TYPE_CRYPTO_STATE        7
#define APFS_TYPE_FILE_EXTENT         8
#define APFS_TYPE_DIR_REC             9
#define APFS_TYPE_DIR_STATS           10
#define APFS_TYPE_SNAP_NAME           11
#define APFS_TYPE_SIBLING_MAP         12
#define APFS_TYPE_FILE_INFO           13

// Object type mask/shift
#define OBJ_TYPE_SHIFT                60
#define OBJ_TYPE_MASK                 0xF000000000000000ULL
#define OBJ_ID_MASK                   0x0FFFFFFFFFFFFFFFULL

// Inode internal flags
#define INODE_IS_APFS_PRIVATE             0x00000001ULL
#define INODE_MAINTAIN_DIR_STATS          0x00000002ULL
#define INODE_DIR_STATS_ORIGIN            0x00000004ULL
#define INODE_PROT_CLASS_EXPLICIT         0x00000008ULL
#define INODE_WAS_CLONED                  0x00000010ULL
#define INODE_WAS_PURGED                  0x00000020ULL
#define INODE_HAS_SECURITY_EA             0x00000040ULL
#define INODE_BEING_TRUNCATED             0x00000080ULL
#define INODE_HAS_FINDER_INFO             0x00000100ULL
#define INODE_IS_SPARSE                   0x00000200ULL
#define INODE_WAS_EVER_CLONED             0x00000400ULL
#define INODE_ACTIVE_FILE_TRIMMED         0x00000800ULL
#define INODE_PINNED_TO_MAIN              0x00001000ULL
#define INODE_PINNED_TO_TIER2             0x00002000ULL
#define INODE_HAS_RSRC_FORK               0x00004000ULL
#define INODE_NO_RSRC_FORK                0x00008000ULL
#define INODE_ALLOCATION_SPILLEDOVER      0x00010000ULL
#define INODE_FAST_PROMOTE                0x00020000ULL
#define INODE_HAS_UNCOMPRESSED_SIZE       0x00040000ULL
#define INODE_IS_PURGEABLE                0x00080000ULL
#define INODE_WANTS_TO_BE_PURGEABLE       0x00100000ULL
#define INODE_IS_SYNC_ROOT                0x00200000ULL
#define INODE_SNAPSHOT_COW_EXEMPTION      0x00400000ULL
#define INODE_PROT_CLASS_UPGRADE_ROLLIP   0x00800000ULL
#define INODE_PURGEABLE_MARK_CHILDREN     0x02000000ULL
#define INODE_HAS_SOURCE_PURGE_ID         0x04000000ULL
#define INODE_HAS_ATTRIBUTION_TAG         0x10000000ULL
#define INODE_MAINTAIN_SPECULATIVE_TELEMETRY 0x20000000ULL
#define INODE_SPECULATIVE_TELEMETRY_ACTIVE 0x40000000ULL

// BSD flags (from sys/stat.h)
#define UF_NODUMP         0x00000001
#define UF_IMMUTABLE      0x00000002
#define UF_APPEND         0x00000004
#define UF_OPAQUE         0x00000008
#define UF_HIDDEN         0x00000010
#define UF_COMPRESSED     0x00000020
#define SF_ARCHIVED       0x00010000
#define SF_IMMUTABLE      0x00020000
#define SF_APPEND         0x00040000
#define SF_DATALESS       0x00100000

// Directory record types (low 4 bits of flags)
#define DT_UNKNOWN        0
#define DT_FIFO           1
#define DT_CHR            2
#define DT_DIR            4
#define DT_BLK            6
#define DT_REG            8
#define DT_LNK            10
#define DT_SOCK           12
#define DT_WHT            14

// Directory record key layout
#define J_DREC_LEN_MASK       0x000003FF
#define J_DREC_HASH_MASK      0xFFFFFC00
#define J_DREC_HASH_SHIFT     10

// Extended field types (inode)
#define INO_EXT_TYPE_SNAP_XID               1
#define INO_EXT_TYPE_DELTA_TREE_OID         2
#define INO_EXT_TYPE_DOCUMENT_ID            3
#define INO_EXT_TYPE_NAME                   4
#define INO_EXT_TYPE_PREV_FSIZE             5
#define INO_EXT_TYPE_FINDER_INFO            7
#define INO_EXT_TYPE_DSTREAM                8
#define INO_EXT_TYPE_DIR_STATS_KEY          10
#define INO_EXT_TYPE_FS_UUID                11
#define INO_EXT_TYPE_UNRAW_SIZE             12
#define INO_EXT_TYPE_SPARSE_BYTES           13
#define INO_EXT_TYPE_RDEV                   14
#define INO_EXT_TYPE_PURGEABLE_FLAGS        15
#define INO_EXT_TYPE_ORIG_SYNC_ROOT_ID      16
#define INO_EXT_TYPE_NLINK                  17
#define INO_EXT_TYPE_SOURCE_PURGE_ID        18
#define INO_EXT_TYPE_ATTRIBUTION_TAG_HASH   19
#define INO_EXT_TYPE_SPEC_TELEMETRY_STATE   20
#define INO_EXT_TYPE_CLONEGROUP_ID          21
#define INO_EXT_TYPE_SPEC_TELEMETRY_TRIGGER 22

// Extended field types (dir record)
#define DREC_EXT_TYPE_SIBLING_ID            1
#define DREC_EXT_TYPE_DIR_GEN_COUNT         2

// Extended field flags
#define XF_DATA_DEPENDENT   0x0001
#define XF_DO_NOT_COPY      0x0002
#define XF_BTREE_TRACKED    0x0004
#define XF_CHILDREN_INHERIT 0x0008
#define XF_USER_FIELD       0x0010
#define XF_SYSTEM_FIELD     0x0020

// Clonegroup flags
#define CLONEGROUP_FLAG_FULL_CLONE     0x10
#define CLONEGROUP_FLAG_PURGEABLE_MASK 0x0F

// DECMPFS
#define DECMPFS_MAGIC           0x636D7066  // 'cmpf'

// ============================================================================
// On-Disk Structures (packed, little-endian)
// ============================================================================

// Common key header
typedef struct __attribute__((packed)) {
    uint64_t obj_id_and_type;  // low 60 bits = object ID, high 4 bits = type
} j_key_t;

// Inode key (just the header)
typedef struct __attribute__((packed)) {
    j_key_t hdr;
} j_inode_key_t;

// Inode value (fixed portion, followed by extended fields)
typedef struct __attribute__((packed)) {
    uint64_t parent_id;                      // 0x00
    uint64_t private_id;                     // 0x08
    uint64_t create_time;                    // 0x10 - seconds since epoch
    uint64_t mod_time;                       // 0x18
    uint64_t change_time;                    // 0x20
    uint64_t access_time;                    // 0x28
    uint64_t internal_flags;                 // 0x30
    int32_t  nlink;                          // 0x38 - hard link count (or nchildren for dirs)
    uint32_t default_protection_class;       // 0x3C
    uint32_t write_generation_counter;       // 0x40
    uint32_t bsd_flags;                      // 0x44
    uint32_t owner;                          // 0x48
    uint32_t group;                          // 0x4C
    uint16_t mode;                           // 0x50
    uint16_t pad1;                           // 0x52
    uint64_t uncompressed_size;              // 0x54
    // uint8_t xfields[];                     // 0x5C - variable
} j_inode_val_t;

// Directory record key (hashed layout for case-insensitive volumes)
typedef struct __attribute__((packed)) {
    j_key_t hdr;                     // obj_id = parent inode, type = APFS_TYPE_DIR_REC
    uint32_t name_len_and_hash;      // 10 bits len | 22 bits CRC-32C hash
    // uint8_t name[];                // variable, null-terminated UTF-8
} j_drec_hashed_key_t;

// Directory record value (fixed portion)
typedef struct __attribute__((packed)) {
    uint64_t file_id;      // target inode number
    uint64_t date_added;   // when entry added to directory
    uint16_t flags;        // low 4 bits = DT_*
    // uint8_t xfields[];   // variable
} j_drec_val_t;

// File extent key
typedef struct __attribute__((packed)) {
    j_key_t hdr;
    uint64_t logical_addr;  // logical block address
} j_file_extent_key_t;

// File extent value
typedef struct __attribute__((packed)) {
    uint64_t phys_addr;     // physical block address
    uint64_t length;        // length in blocks
    uint32_t flags;
    uint32_t crypto_id;
} j_file_extent_val_t;

// Xattr key
typedef struct __attribute__((packed)) {
    j_key_t hdr;
    uint16_t name_len;
    // uint8_t name[];       // variable
} j_xattr_key_t;

// Xattr value
typedef struct __attribute__((packed)) {
    uint32_t size;
    uint32_t flags;
    // uint8_t data[];       // variable
} j_xattr_val_t;

// Sibling link key
typedef struct __attribute__((packed)) {
    j_key_t hdr;
    uint64_t sibling_id;    // sibling identifier
    uint64_t sibling_obj_id; // sibling object ID
} j_sibling_link_key_t;

// Sibling link value
typedef struct __attribute__((packed)) {
    uint64_t target_id;     // target inode
} j_sibling_link_val_t;

// Extended fields header
typedef struct __attribute__((packed)) {
    uint16_t xf_num_exts;   // number of extended fields
    uint16_t xf_used_data;  // bytes used
    // uint8_t xf_data[];    // x_field_t array + data
} xf_blob_t;

// Extended field descriptor
typedef struct __attribute__((packed)) {
    uint8_t x_type;
    uint8_t x_flags;
    uint16_t x_size;        // size of data (not including padding)
} x_field_t;

// Directory stats key
typedef struct __attribute__((packed)) {
    j_key_t hdr;   // obj_id = directory inode
} j_dir_stats_key_t;

// Directory stats value
typedef struct __attribute__((packed)) {
    uint64_t num_children;  // recursive count
    uint64_t total_size;    // recursive size
    uint64_t chained_key;   // parent directory object ID
    uint64_t gen_count;     // modification generation
} j_dir_stats_val_t;

// Clonegroup mapping key
typedef struct __attribute__((packed)) {
    uint64_t group_id;
    uint8_t  record_type;   // 1 = mapping, 2 = cookie
    uint64_t inode_id;
    uint64_t private_id;
} clonegroup_mapping_key_t;

// Clonegroup value
typedef struct __attribute__((packed)) {
    uint64_t physical_size;
    uint32_t flags;
    // uint8_t xfields[];
} clonegroup_val_t;

// Clonegroup cookie key
typedef struct __attribute__((packed)) {
    uint64_t group_id;
    uint8_t  record_type;   // always 2
    uint64_t cookie;
} clonegroup_cookie_key_t;

// DECMPFS header
typedef struct __attribute__((packed)) {
    uint32_t compression_magic;
    uint32_t compression_type;
    uint64_t uncompressed_size;
    // uint8_t attr_bytes[];
} decmpfs_disk_header_t;

// ============================================================================
// Helper Macros
// ============================================================================

// Little-endian read (host may be LE or BE)
static inline uint16_t APFS_READ_LE16(const void *ptr) {
    const uint8_t *p = (const uint8_t *)ptr;
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline uint32_t APFS_READ_LE32(const void *ptr) {
    const uint8_t *p = (const uint8_t *)ptr;
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline uint64_t APFS_READ_LE64(const void *ptr) {
    const uint8_t *p = (const uint8_t *)ptr;
    return (uint64_t)p[0] | ((uint64_t)p[1] << 8) | ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 24) |
           ((uint64_t)p[4] << 32) | ((uint64_t)p[5] << 40) | ((uint64_t)p[6] << 48) | ((uint64_t)p[7] << 56);
}

// Extract object ID and type from j_key_t
static inline uint64_t APFS_KEY_OBJ_ID(const j_key_t *key) {
    return key->obj_id_and_type & OBJ_ID_MASK;
}

static inline uint8_t APFS_KEY_TYPE(const j_key_t *key) {
    return (uint8_t)(key->obj_id_and_type >> OBJ_TYPE_SHIFT);
}

// Extract name length and hash from dir record key
static inline uint16_t APFS_DREC_NAME_LEN(const j_drec_hashed_key_t *key) {
    return key->name_len_and_hash & J_DREC_LEN_MASK;
}

static inline uint32_t APFS_DREC_NAME_HASH(const j_drec_hashed_key_t *key) {
    return (key->name_len_and_hash & J_DREC_HASH_MASK) >> J_DREC_HASH_SHIFT;
}

// ============================================================================
// Parsed Structures (host-endian, convenient for Swift)
// ============================================================================

typedef struct {
    uint64_t obj_id;
    uint8_t type;
} apfs_key_parsed_t;

typedef struct {
    uint64_t parent_id;
    uint64_t private_id;
    uint64_t create_time;
    uint64_t mod_time;
    uint64_t change_time;
    uint64_t access_time;
    uint64_t internal_flags;
    int32_t  nlink;
    uint32_t write_generation_counter;
    uint32_t bsd_flags;
    uint32_t owner;
    uint32_t group;
    uint16_t mode;
    uint64_t uncompressed_size;
} apfs_inode_parsed_t;

typedef struct {
    uint64_t parent_inode;
    uint64_t file_id;
    uint64_t date_added;
    uint16_t flags;  // DT_* in low 4 bits
    char *name;      // null-terminated UTF-8, caller must free
} apfs_drec_parsed_t;

typedef struct {
    uint64_t logical_addr;
    uint64_t phys_addr;
    uint64_t length;
    uint32_t flags;
    uint32_t crypto_id;
} apfs_file_extent_parsed_t;

typedef struct {
    uint8_t type;
    uint8_t flags;
    uint16_t size;
    void *data;      // caller must free
} apfs_xfield_parsed_t;

typedef struct {
    uint64_t group_id;
    uint8_t record_type;  // 1 or 2
    uint64_t inode_id;
    uint64_t private_id;
    uint64_t physical_size;
    uint32_t flags;
} apfs_clonegroup_parsed_t;

// ============================================================================
// OMAP / B-Tree Structures (simplified for traversal)
// ============================================================================

typedef struct {
    uint64_t oid;         // virtual object ID
    uint64_t phys_addr;   // physical block address
    uint32_t length;      // in blocks
} omap_entry_t;

typedef struct {
    uint64_t fstree_oid;  // from volume superblock
    // ... other fields
} apfs_volume_superblock_t;

// ============================================================================
// CRC-32C (Castagnoli) for directory record hashing
// ============================================================================

uint32_t apfs_crc32c(const uint8_t *data, size_t length, uint32_t crc);

// Compute directory record hash (NFD + casefold + UTF-32LE -> CRC32C -> complement -> low 22 bits)
uint32_t apfs_drec_compute_hash(const char *utf8_name);

#ifdef __cplusplus
}
#endif

#endif /* EverythingAPFS_apfs_structs_h */
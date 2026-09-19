# Everything by voidtools - Complete Technical Specification

## Overview

**Everything** is a file search engine for Windows developed by David Carpenter (voidtools). It provides instantaneous file search by building an in-memory index of the NTFS/ReFS Master File Table (MFT) and monitoring changes via the USN Change Journal.

**Key Characteristics:**
- **Speed**: Indexes millions of files in seconds; searches return results in milliseconds
- **Size**: ~1-2 MB installer; ~10-50 MB runtime memory (depending on indexed properties)
- **Architecture**: Windows-native C/C++ application; single-threaded UI with background indexing threads
- **License**: Freeware (commercial use requires license for Everything Server)
- **Platform**: Windows 2000/XP/Vista/7/8/10/11 (x86, x64, ARM, ARM64)

---

## Core Architecture

### 1. Initial Indexing: MFT Scanning

Everything achieves its speed by reading the **NTFS Master File Table (MFT)** directly rather than traversing the filesystem via Win32 APIs.

#### MFT Scan Process
```
1. Open volume with CreateFile("\\\\?\\X:", GENERIC_READ, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, 
                               NULL, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING|FILE_FLAG_SEQUENTIAL_SCAN, NULL)

2. Enumerate MFT records using FSCTL_ENUM_USN_DATA with MFT_ENUM_DATA:
   - StartFileReferenceNumber = 0 (start at $MFT)
   - LowUsn = 0, HighUsn = MAXUSN
   - MaxMajorVersion/MinMajorVersion from FSCTL_QUERY_USN_JOURNAL

3. For each USN_RECORD (V2/V3/V4):
   - Extract FileReferenceNumber (FRN) - 64-bit unique file identifier
   - Extract ParentFileReferenceNumber - FRN of parent directory
   - Extract FileNameOffset/Length - filename in record
   - Extract Reason flags - USN_REASON_* (FILE_CREATE, RENAME, DELETE, etc.)
   - Extract Timestamp - from $STANDARD_INFORMATION attribute

4. Build in-memory B-tree/index structures:
   - Folder table: drive(1 byte) | FRN(8 bytes) | ParentOffset(4 bytes) | FRNOffset(4 bytes) | name
   - File table: ParentOffset(4 bytes) | name
   - Both sorted lexicographically for fast prefix search

5. Persist to Everything.db (BZIP2 compressed, ~11:1 ratio)
```

#### MFT Record Version Handling
Everything handles multiple USN_RECORD versions:
- **USN_RECORD_V2**: Legacy (pre-Windows 8)
- **USN_RECORD_V3**: Standard (Windows 8+)
- **USN_RECORD_V4**: Extended with extents (Windows 10+)

```cpp
// Version detection from forum code example:
mft_enum_data.MaxMajorVersion = journal->MaxSupportedMajorVersion;
mft_enum_data.MinMajorVersion = journal->MinSupportedMajorVersion;

// Reading records:
if (mft_enum_data.MinMajorVersion == 4)
    read_record<USN_RECORD_V4>(...);
else
    read_record<USN_RECORD_V3>(...);
```

#### Timestamp Extraction
Timestamps come from the **$STANDARD_INFORMATION** attribute within each MFT record, not from the USN_RECORD itself (which has TimeStamp=0). Everything reads this during the initial MFT enumeration.

---

### 2. Real-Time Monitoring: USN Change Journal

After initial indexing, Everything monitors filesystem changes via the **USN (Update Sequence Number) Change Journal**.

#### USN Journal Monitoring
```
1. CreateFile on volume with FILE_FLAG_NO_BUFFERING
2. FSCTL_CREATE_USN_JOURNAL (if not exists) with MaxSize/AllocationDelta
3. FSCTL_QUERY_USN_JOURNAL to get UsnJournalID, FirstUsn, NextUsn, MaxUsn
4. Loop:
   - FSCTL_READ_USN_JOURNAL from NextUsn to MaxUsn
   - Parse USN_RECORDs for changes
   - Update in-memory index:
     * FILE_CREATE -> add new entry
     * FILE_DELETE -> mark deleted
     * RENAME_OLD_NAME/RENAME_NEW_NAME -> update name/path
     * DATA_OVERWRITE/EXTEND/TRUNCATION -> update size if indexed
     * BASIC_INFO_CHANGE -> update timestamps/attributes if indexed
     * HARD_LINK_CHANGE -> update hard link tracking
   - Update NextUsn
   - Sleep/Wait for more changes (monitor_update_delay INI setting)
```

#### USN Reason Filter (INI: `usn_record_filter`)
```
0x00000001  USN_REASON_DATA_OVERWRITE
0x00000002  USN_REASON_DATA_EXTEND
0x00000004  USN_REASON_DATA_TRUNCATION
0x00000010  USN_REASON_NAMED_DATA_OVERWRITE
0x00000020  USN_REASON_NAMED_DATA_EXTEND
0x00000040  USN_REASON_NAMED_DATA_TRUNCATION
0x00000100  USN_REASON_FILE_CREATE
0x00000200  USN_REASON_FILE_DELETE
0x00000400  USN_REASON_EA_CHANGE
0x00000800  USN_REASON_SECURITY_CHANGE
0x00001000  USN_REASON_RENAME_OLD_NAME
0x00002000  USN_REASON_RENAME_NEW_NAME
0x00004000  USN_REASON_INDEXABLE_CHANGE
0x00008000  USN_REASON_BASIC_INFO_CHANGE
0x00010000  USN_REASON_HARD_LINK_CHANGE
0x00020000  USN_REASON_COMPRESSION_CHANGE
0x00040000  USN_REASON_ENCRYPTION_CHANGE
0x00080000  USN_REASON_OBJECT_ID_CHANGE
0x00100000  USN_REASON_REPARSE_POINT_CHANGE
0x00200000  USN_REASON_STREAM_CHANGE
0x80000000  USN_REASON_CLOSE
```

---

### 3. Database Format (Everything.db)

The database is a **memory-mapped cache of the MFT** with optional property indexes.

#### Header
```
Offset  Size  Description
0x00    4     Magic: 0x42445A45 ("EZDB") or 0x455A4442 ("BDZE" byte-swapped)
0x04    4     Version: 0x01060006 (major.minor.revision)
0x08    4     Flags: 0x02=exclude hidden, 0x04=exclude system
0x0C    4     Folder count
0x10    4     File count
0x14    4     Folder decode size (bytes)
0x18    4     File decode size (bytes)
```

#### Volume Monitoring Status (26 entries - one per drive letter)
```
Per-volume (repeated 26 times):
0x00    1     Included flag (0=no data, 1=has data)
0x01    4     Volume serial number
0x05    8     USN Journal ID
0x0D    8     Next USN
```

#### Exclude List
```
0x00    4     Exclude item count
Per-item:
0x00    1     Exclude type
0x01    4     String length
0x05    N     Exclude string (path or wildcard)
```

#### Folder Table (sorted by name for prefix search)
```
Per-folder:
0x00    1     Drive index (0-25)
0x01    8     FRN (File Reference Number)
0x09    4     Parent folder offset (0xFFFFFFFF = root)
0x0D    4     FRN offset (for hard links)
0x11    1     Code length (0 = same name as previous)
0x12    1     Code offset
0x13    N     Name code (delta-encoded)
```

#### File Table (sorted by name within parent)
```
Per-file:
0x00    4     Parent folder offset
0x04    1     Code length (0 = same name as previous)
0x05    1     Code offset
0x06    N     Name code (delta-encoded)
```

#### Optional Property Indexes (when enabled)
- **Size index**: 8 bytes per file (fast sort)
- **Date indexes**: 8 bytes per file (FILETIME)
- **Attribute index**: 4 bytes per file
- **Folder size index**: 8 bytes per folder
- **Fast sort indexes**: Additional B-tree structures for instant sorting

---

### 4. Folder Indexing (Non-NTFS)

For FAT32, exFAT, network shares, and other filesystems:

```
1. Recursive FindFirstFile/FindNextFile traversal
2. Build same in-memory structures as NTFS
3. Polling-based change detection (configurable interval)
4. ReadDirectoryChangesW for real-time monitoring (if supported)
5. Rescan-on-full-buffer option for high-change volumes
```

**Update Scheduling** (INI):
- `folder_update_types`: 0=never, 1=interval, 2=scheduled day
- `folder_update_intervals`: minutes/hours
- `folder_update_days`: 0=everyday, 1-7=Sun-Sat
- `folder_update_ats`: hour 0-23
- `folder_buffer_size_list`: change buffer size per folder
- `folder_rescan_if_full_list`: rescan when buffer overflows

---

### 5. ReFS Support

ReFS (Resilient File System) uses similar concepts:
- **File ID** instead of FRN (128-bit vs 64-bit)
- **Change tracking** via directory enumeration + USN-like journal
- Separate volume tables in INI: `refs_volume_guids`, `refs_volume_paths`, `refs_volume_includes`, etc.

---

## Search Engine

### Query Processing Pipeline

```
1. Parse search string into AST
2. Compile to bytecode (EVERYTHING_IPC_QUERY structure)
3. Execute bytecode against in-memory indexes:
   - Name/Path: Prefix B-tree traversal
   - Size/Date: Fast-sort index binary search (if enabled)
   - Content: On-demand file read (slow)
   - Properties: Index lookup or on-demand shell property handler
4. Apply filters (AND/OR/NOT, grouping)
5. Sort results (using fast-sort index or on-demand gather)
6. Return top N results (max_results parameter)
```

### Search Syntax

**Operators:**
- ` ` (space) = AND
- `|` = OR
- `!` = NOT
- `< >` = Grouping
- `"` = Literal quotes

**Modifiers (prefix):**
- `case:` / `nocase:` - Case sensitivity
- `diacritics:` / `nodiacritics:` - Diacritics matching
- `wholeword:` / `nowholeword:` - Whole word
- `path:` / `nopath:` - Full path match
- `regex:` / `noregex:` - Regular expression
- `prefix:` / `noprefix:` - Prefix match
- `suffix:` / `nosuffix:` - Suffix match

**Functions (property:value):**
- `size:`, `size-on-disk:` - File size (supports KB/MB/GB, ranges `..`, comparisons `> <`)
- `date-modified:`, `dm:` - Modified date (relative: `today`, `10mins`, `2days`)
- `date-created:`, `dc:` - Created date
- `date-accessed:`, `da:` - Accessed date
- `date-recently-changed:`, `rc:` - Index change date
- `ext:`, `extension:` - File extension
- `name:`, `stem:` - Filename / name without extension
- `parent:`, `location:` - Parent path
- `file-id:`, `frn:` - NTFS File Reference Number
- `run-count:` - Run history count
- `content:` - File content search (slow, uses iFilter)
- `dupe:`, `distinct:`, `unique:` - Duplicate detection
- `width:`, `height:`, `dimensions:` - Image/video dimensions
- `length:`, `duration:` - Media duration
- `crc32:`, `md5:`, `sha1:`, `sha256:` - File hashes
- `attributes:` - File attributes
- `folder:`, `file:` - Type filter

**Macros:** `audio:`, `doc:`, `exe:`, `image:`, `video:`, `zip:`

---

## Inter-Process Communication (IPC/SDK)

Everything exposes a **WM_COPYDATA** based IPC interface for external applications.

### Window Class
- Class name: `EVERYTHING_IPC_WNDCLASS`
- Find with: `FindWindow(EVERYTHING_IPC_WNDCLASS, 0)`

### Query Message
```c
#define EVERYTHING_IPC_COPYDATAQUERY   0x4001
#define EVERYTHING_IPC_WM_COPYDATA     WM_COPYDATA

typedef struct {
    DWORD max_results;
    DWORD offset;
    DWORD reply_copydata_message;
    DWORD search_flags;  // REGEX|MATCHCASE|MATCHWHOLEWORD|MATCHPATH
    HWND reply_hwnd;
    WCHAR search_string[1];  // Variable length
} EVERYTHING_IPC_QUERY;

Search flags:
- EVERYTHING_IPC_REGEX        0x0001
- EVERYTHING_IPC_MATCHCASE    0x0002
- EVERYTHING_IPC_MATCHWHOLEWORD 0x0004
- EVERYTHING_IPC_MATCHPATH    0x0008
```

### Result Message
```c
typedef struct {
    DWORD numitems;
    // Variable: EVERYTHING_IPC_ITEM items[numitems]
} EVERYTHING_IPC_LIST;

typedef struct {
    DWORD file_attribute;
    FILETIME creation_time;
    FILETIME last_access_time;
    FILETIME last_write_time;
    ULONGLONG file_size;
    DWORD parent_folder_offset;
    DWORD file_name_offset;
} EVERYTHING_IPC_ITEM;

// Path/name retrieval macros:
EVERYTHING_IPC_ITEMPATH(list, item)   -> WCHAR*
EVERYTHING_IPC_ITEMFILENAME(list, item) -> WCHAR*
```

### Additional IPC Commands
- `EVERYTHING_IPC_IS_RUNNING` - Check if Everything running
- `EVERYTHING_IPC_GET_VERSION` - Get version
- `EVERYTHING_IPC_OPEN` - Open file/folder
- `EVERYTHING_IPC_COPYDATA_FOLDER` - Folder operations
- `EVERYTHING_IPC_REGISTER` - Register for notifications

---

## ETP (Everything Transfer Protocol)

ETP = **FTP + SITE EVERYTHING extension**. Allows remote Everything clients to search a server's index.

### Protocol Flow
```
1. Standard FTP connection (port 21 default)
2. Client authenticates (USER/PASS)
3. Client sends SITE EVERYTHING commands:
   SITE EVERYTHING SEARCH "query"
   SITE EVERYTHING CASE 1
   SITE EVERYTHING COUNT 100
   SITE EVERYTHING PATH_COLUMN 1
   SITE EVERYTHING QUERY
4. Server responds with FTP-style listing (MLST/MLSD)
5. Client downloads files via RETR (if allowed)
```

### SITE EVERYTHING Commands
| Command | Description |
|---------|-------------|
| `SITE EVERYTHING CASE x` | Match case (x=1/0) |
| `SITE EVERYTHING WHOLE_WORD x` | Whole word match |
| `SITE EVERYTHING PATH x` | Full path match |
| `SITE EVERYTHING DIACRITICS x` | Diacritics match |
| `SITE EVERYTHING REGEX x` | Regex enable |
| `SITE EVERYTHING SEARCH text` | Set search query |
| `SITE EVERYTHING FILTER_SEARCH text` | Secondary filter |
| `SITE EVERYTHING SORT name` | Sort order (NAME_ASCENDING, SIZE_DESCENDING, etc.) |
| `SITE EVERYTHING OFFSET n` | Pagination offset |
| `SITE EVERYTHING COUNT n` | Max results |
| `SITE EVERYTHING *_COLUMN x` | Include column (SIZE, DATE_CREATED, etc.) |
| `SITE EVERYTHING QUERY` | Execute search |

### Link Types (Client-Side Path Mapping)
| Type | Description |
|------|-------------|
| `C:` | Direct path (same paths on client/server) |
| `\\Server\C` | Windows shares (default) |
| `\\Server\C$` | Admin shares |
| `ftp://host/C:` | FTP download links |

---

## Everything Server (New in 1.5)

Modern replacement for ETP with:
- **Encrypted connections** (AES)
- **Centralized index sharing** (server holds index, clients sync)
- **Path remapping** (server path → client mount point)
- **User authentication/authorization** (per-user path access)
- **Port 14630** default
- **Index snapshots** with caching (`index_snapshot_cache_timeout`, `index_snapshot_max_count`)

### Server Setup
1. Enable Journal (32768 KB recommended for servers)
2. Disable auto-include volumes
3. Enable Everything Server plugin
4. Add users with `Include only` path restrictions
5. Set `Remap to` for each path (server local path → network share)

### Client Setup
1. Add Network Index → host/username/password
2. Optional: Limit/remap paths with `Include only` + `Mount as`

---

## HTTP Server Plugin

Web-based search interface:
- REST-like endpoints
- JSON results
- Thumbnail/image preview
- File download
- Customizable templates (`http_server_strings` INI)

---

## Plugin Architecture (1.5+)

Everything 1.5 uses a **plugin DLL** architecture:
- Plugins in `C:\Program Files\Everything\plugins\`
- Official plugins: `http_server.dll`, `etp_server.dll`, `everything_server.dll`
- Settings in `%APPDATA%\Everything\Plugins.ini`
- Third-party plugins require manual enable in Options → Plugins
- SDK available for custom plugins (C/C++)

---

## Configuration System

### INI File Locations
- `%LOCALAPPDATA%\Everything\Everything.ini` (default)
- Same folder as Everything.exe (if `store_settings_and_data_in_appdata_everything=0`)
- Portable: alongside Everything.exe

### Key INI Sections

#### General
```
allow_multiple_instances=0
instance_name=
max_threads=0
reuse_threads=1
debug=0
debug_log=0
```

#### Indexing
```
auto_include_fixed_volumes=1
auto_include_removable_volumes=0
auto_remove_offline_ntfs_volumes=1
index_size=1
fast_size_sort=1
index_date_created=0
fast_date_created_sort=0
index_date_modified=1
fast_date_modified_sort=1
index_date_accessed=0
fast_date_accessed_sort=0
index_attributes=0
fast_attributes_sort=0
index_folder_size=0
index_recent_changes=1
extended_information_cache_monitor=1
db_location=%LOCALAPPDATA%\Everything\Everything.db
db_compress=1
```

#### NTFS Volumes (parallel arrays)
```
ntfs_volume_guids=...
ntfs_volume_paths=...
ntfs_volume_roots=...
ntfs_volume_includes=...
ntfs_volume_load_recent_changes=...
ntfs_volume_include_onlys=...
ntfs_volume_monitors=...
```

#### Exclude
```
exclude_list_enabled=1
exclude_hidden_files_and_folders=1
exclude_system_files_and_folders=1
include_only_files=
exclude_files=thumbs.db;desktop.ini;*.tmp
exclude_folders=
```

#### Monitoring
```
monitor_thread_mode_background=1
monitor_retry_delay=10000
monitor_update_delay=1000
monitor_pause=0
```

#### ETP Server
```
etp_server_enabled=0
etp_server_port=21
etp_server_bindings=
etp_server_username=
etp_server_password=
etp_server_allow_file_download=1
```

#### HTTP Server
```
http_server_enabled=0
http_server_port=80
http_server_username=
http_server_password=
http_server_allow_file_download=1
```

---

## Command Line Interface

```
Everything.exe [filename] [-switches]

Search Control:
  -s, -search <text>           Set search
  -path <path>                 Search within path
  -parent <path>               Search direct children only
  -case, -no-case              Case sensitivity
  -regex, -no-regex            Regex mode
  -whole-word, -no-whole-word  Whole word
  -diacritics, -no-diacritics  Diacritics
  -filter <name>               Activate filter
  -bookmark <name>             Open bookmark

Results:
  -sort <property>             Sort by property
  -sort-ascending / -sort-descending
  -details / -thumbnails       View mode
  -columns <props>             Set columns

Window:
  -new-window / -no-new-window
  -new-tab / -no-new-tab
  -toggle-window
  -maximize / -minimize / -fullscreen
  -on-top / -no-on-top
  -x <x> -y <y> -width <w> -height <h>

Database:
  -db <filename>               Custom database
  -read-only                   Open read-only
  -reindex                     Force rebuild
  -rescan <path>               Rescan folder
  -monitor-pause / -monitor-resume
  -save-db / -save-db-now

Installation:
  -install-service / -uninstall-service
  -start-service / -stop-service
  -install-run-on-system-startup
  -enable-index-as-admin
  -startup                     Background only

ETP:
  -connect <host>              Connect to ETP server
  -ftp-links / -drive-links    Link type

File Lists:
  -create-file-list <efu> <path>
  -filelist <efu>              Open file list
```

---

## File Lists (EFU Format)

**Everything File List (.efu)** - portable offline index snapshots.

### Format (CSV)
```
Filename,Size,Date Modified,Date Created,Attributes,File List Filename
"C:\file.txt",1024,2024-01-15 10:30:00,2024-01-10 08:00:00,32,"mylist.efu"
```

### Creation
```
Everything.exe -create-file-list "list.efu" "C:\path" -create-file-list-include-only-files "*.jpg;*.png"
```

### Use Cases
- Offline media (CDs, DVDs, external drives)
- Network share snapshots
- Cross-machine file transfer

---

## Run History

Tracks files opened from Everything results:
- `run_count` - incremented on open
- `date_run` - last opened timestamp
- Used for "most run" sorting and Enter-key behavior

---

## Index Journal

Records all index changes for:
- Debugging/auditing
- Recovery
- Recent changes search (`date-recently-changed:` / `rc:`)

---

## Multiple Instances

Run isolated Everything instances:
```
-instance <name>              Named instance
-first-instance               Run only if not running
-no-first-instance            Run only if already running
```

Each instance has separate:
- Database (Everything-<name>.db)
- INI (Everything-<name>.ini)
- Window state
- Tray icon

---

## Service Architecture

### Everything Service (System Service)
- Runs as SYSTEM
- Provides NTFS indexing for non-admin Everything process
- Installed via `-install-service`
- Communicates via named pipe: `\\.\pipe\Everything Service`

### Client Service
- Runs Everything as Windows Service (for ETP/HTTP/Everything Server)
- `-install-client-service`
- No UI, background only

---

## Performance Characteristics

| Metric | Typical Value |
|--------|---------------|
| Initial index (1M files, NTFS) | 2-5 seconds |
| Initial index (8M files) | ~2 minutes |
| Search latency (name only) | < 10 ms |
| Search latency (with size/date) | < 50 ms |
| Memory (name only, 1M files) | ~50 MB |
| Memory (all props, 1M files) | ~200 MB |
| Database size (1M files) | ~20 MB (compressed) |
| USN processing latency | < 100 ms per 1000 changes |

### Memory Optimization
Disable unused indexes:
```
index_size=0
index_folder_size=0
index_date_created=0
index_date_modified=0
index_date_accessed=0
index_attributes=0
index_recent_changes=0
fast_path_sort=0
fast_extension_sort=0
```

---

## Security Model

### Privilege Separation
- **Standard user process**: UI, search, folder indexing
- **Service process (SYSTEM)**: NTFS MFT reading, USN journal access
- **IPC**: Named pipe with security descriptor

### Access Control
- ETP/HTTP/Everything Server: Username/password authentication
- Everything Server: Per-user path restrictions (`Include only`)
- File download: Can be disabled per server
- No telemetry, no network connections (unless servers enabled)

---

## Limitations & Known Issues

1. **NTFS/ReFS only for instant indexing** - FAT/exFAT/network require folder indexing (slower)
2. **Hard links** - Only first hard link tracked; changes to other links missed (improved in 1.5)
3. **Junctions/symlinks** - Not followed during NTFS indexing
4. **Content search** - Slow (uses iFilter, no full-text index)
5. **Date accessed** - Not updated by default (Windows disables last access updates)
6. **Case sensitivity** - NTFS is case-preserving but case-insensitive; Everything matches this
7. **Maximum path** - 260 chars (Win32) or 32767 (\\?\) - Everything uses extended paths

---

## Version History Highlights

| Version | Key Features |
|---------|--------------|
| 1.0-1.2 | Basic MFT indexing, USN monitoring |
| 1.3 | Fast sort indexes, folder indexing, file lists |
| 1.4 | ReFS support, ETP/FTP server, HTTP server, multiple instances, plugins |
| 1.5 | Everything Server, plugin architecture, improved hard links, new UI, bookmarks, filters, thumbnails, preview, advanced search functions, distinct/dupe/unique |

---

## Extending Everything

### 1. External Tools via IPC
- Send queries via WM_COPYDATA
- Receive results via callback window
- C/C#/Python examples in SDK

### 2. Command Line Automation
- Script searches, exports, indexing control
- Batch file processing with `-rename`, `-copyto`, `-moveto`

### 3. File Lists
- Generate .efu for offline/portable indexes
- `db2efu.exe` tool to convert Everything.db → .efu

### 4. Plugins (1.5+)
- Custom DLL plugins
- Access to index, search, UI events
- HTTP/ETP/Everything Server are plugins

### 5. URL Protocol
- `es:search_term?case=1&sort=date-modified-descending`
- Register with `-install-url-protocol`

---

## File Locations Summary

| File | Location |
|------|----------|
| Everything.exe | `%PROGRAMFILES%\Everything\` or portable folder |
| Everything.db | `%LOCALAPPDATA%\Everything\Everything.db` |
| Everything.ini | `%APPDATA%\Everything\Everything.ini` |
| Plugins.ini | `%APPDATA%\Everything\Plugins.ini` |
| Plugins | `%PROGRAMFILES%\Everything\plugins\` |
| Debug log | `%TEMP%\Everything Debug Log.txt` |
| ETP logs | `%APPDATA%\Everything\ETP_FTP_Server.log` |
| HTTP logs | `%APPDATA%\Everything\HTTP_Server.log` |

---

## Conclusion

Everything's architecture is built on three pillars:

1. **MFT Direct Access** - Bypasses filesystem layer for raw metadata
2. **USN Journal Monitoring** - Incremental updates without rescanning
3. **In-Memory Index with Bytecode Search** - Zero-copy, allocation-free query execution

This design achieves **O(1) search latency** for name/path queries and **O(log n)** for property searches, making it uniquely fast among Windows search tools. The plugin architecture (1.5+) and IPC/SDK enable integration into build systems, IDEs, and custom workflows.
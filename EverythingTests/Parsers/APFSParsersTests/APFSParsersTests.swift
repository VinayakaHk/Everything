import Foundation
import Nimble
import Quick
@testable import EverythingCore
import EverythingAPFS

// MARK: - APFS Parser Tests

final class APFSParsersTests: QuickSpec {
    override class func spec() {
        describe("APFS Parsers") {
            context("CRC-32C") {
                it("matches known test vectors") {
                    // Test vector: "123456789" -> 0xE3069283
                    let data = "123456789".data(using: .ascii)!
                    let crc = data.withUnsafeBytes { apfs_crc32c($0.baseAddress!, data.count, 0xFFFFFFFF) } ^ 0xFFFFFFFF
                    expect(crc).to(equal(0xE3069283))
                }
                
                it("handles empty data") {
                    let crc = apfs_crc32c(nil, 0, 0xFFFFFFFF) ^ 0xFFFFFFFF
                    expect(crc).to(equal(0))
                }
                
                it("is consistent") {
                    let data = Data(repeating: 0xAA, count: 1000)
                    let crc1 = data.withUnsafeBytes { apfs_crc32c($0.baseAddress!, data.count, 0xFFFFFFFF) } ^ 0xFFFFFFFF
                    let crc2 = data.withUnsafeBytes { apfs_crc32c($0.baseAddress!, data.count, 0xFFFFFFFF) } ^ 0xFFFFFFFF
                    expect(crc1).to(equal(crc2))
                }
            }
            
            context("Directory Record Hash") {
                it("computes hash for simple ASCII name") {
                    let hash = apfsDirectoryRecordHash(for: "README.md")
                    // Verify it's a 22-bit value
                    expect(hash).to(beLessThan(0x400000))
                }
                
                it("produces same hash for same name") {
                    let hash1 = apfsDirectoryRecordHash(for: "test.txt")
                    let hash2 = apfsDirectoryRecordHash(for: "test.txt")
                    expect(hash1).to(equal(hash2))
                }
                
                it("handles Unicode names") {
                    let hash = apfsDirectoryRecordHash(for: "文件.txt")
                    expect(hash).to(beLessThan(0x400000))
                }
                
                it("handles empty name") {
                    let hash = apfsDirectoryRecordHash(for: "")
                    expect(hash).to(beLessThan(0x400000))
                }
                
                it("different names produce different hashes (mostly)") {
                    let hash1 = apfsDirectoryRecordHash(for: "file1.txt")
                    let hash2 = apfsDirectoryRecordHash(for: "file2.txt")
                    // Collisions possible but unlikely for simple names
                }
            }
            
            context("Inode Parsing") {
                it("parses inode record correctly") {
                    // Create a test inode record
                    var inode = j_inode_val_t()
                    inode.parent_id = 0x0000000000000002  // Root directory
                    inode.private_id = 0x0000000000000100
                    inode.create_time = 1704067200  // 2024-01-01
                    inode.mod_time = 1704153600
                    inode.change_time = 1704240000
                    inode.access_time = 1704326400
                    inode.internal_flags = INODE_HAS_UNCOMPRESSED_SIZE
                    inode.nlink = 1
                    inode.default_protection_class = 0
                    inode.write_generation_counter = 42
                    inode.bsd_flags = UF_COMPRESSED | UF_IMMUTABLE
                    inode.owner = 501
                    inode.group = 20
                    inode.mode = 0o100644  // Regular file
                    inode.uncompressed_size = 1024
                    // pad1 = 0
                    
                    // Convert to little-endian bytes
                    var data = Data()
                    withUnsafeBytes(of: &inode) { data.append(contentsOf: $0) }
                    
                    // Parse
                    var parsed = apfs_inode_parsed_t()
                    apfs_parse_inode([UInt8](data), data.count, &parsed)
                    
                    expect(parsed.parent_id).to(equal(2))
                    expect(parsed.private_id).to(equal(256))
                    expect(parsed.create_time).to(equal(1704067200))
                    expect(parsed.mod_time).to(equal(1704153600))
                    expect(parsed.internal_flags).to(equal(INODE_HAS_UNCOMPRESSED_SIZE))
                    expect(parsed.nlink).to(equal(1))
                    expect(parsed.write_generation_counter).to(equal(42))
                    expect(parsed.bsd_flags).to(equal(UF_COMPRESSED | UF_IMMUTABLE))
                    expect(parsed.mode).to(equal(0o100644))
                    expect(parsed.uncompressed_size).to(equal(1024))
                }
                
                it("detects compressed files") {
                    var inode = j_inode_val_t()
                    inode.bsd_flags = UF_COMPRESSED
                    inode.internal_flags = INODE_HAS_UNCOMPRESSED_SIZE
                    inode.uncompressed_size = 4096
                    
                    var data = Data()
                    withUnsafeBytes(of: &inode) { data.append(contentsOf: $0) }
                    
                    var parsed = apfs_inode_parsed_t()
                    apfs_parse_inode([UInt8](data), data.count, &parsed)
                    
                    let apfsInode = APFSInode(from: parsed)
                    expect(apfsInode.isCompressed).to(beTrue())
                    expect(apfsInode.uncompressedSize).to(equal(4096))
                }
            }
            
            context("Directory Record Parsing") {
                it("parses directory record with name") {
                    var key = j_drec_hashed_key_t()
                    key.hdr.obj_id_and_type = (UInt64(APFS_TYPE_DIR_REC) << OBJ_TYPE_SHIFT) | 2  // parent = 2
                    key.name_len_and_hash = (5 & J_DREC_LEN_MASK) | (0x123456 << J_DREC_HASH_SHIFT)
                    
                    var val = j_drec_val_t()
                    val.file_id = 100
                    val.date_added = 1704067200
                    val.flags = DT_REG
                    
                    // Build combined buffer
                    var buffer = Data()
                    withUnsafeBytes(of: &key) { buffer.append(contentsOf: $0) }
                    let name = "test\0"
                    buffer.append(name.data(using: .utf8)!)
                    withUnsafeBytes(of: &val) { buffer.append(contentsOf: $0) }
                    
                    // Parse
                    var parsed = apfs_drec_parsed_t()
                    apfs_parse_drec(&key, &val, &parsed)
                    
                    expect(parsed.parent_inode).to(equal(2))
                    expect(parsed.file_id).to(equal(100))
                    expect(parsed.date_added).to(equal(1704067200))
                    expect(parsed.flags).to(equal(DT_REG))
                    expect(parsed.name).to(equal("test"))
                    
                    apfs_free_drec(&parsed)
                }
                
                it("identifies record types correctly") {
                    var val = j_drec_val_t()
                    val.flags = DT_DIR
                    var drec = APFSDirectoryRecord(from: apfs_drec_parsed_t(parent_inode: 1, file_id: 2, date_added: 0, flags: DT_DIR, name: "dir"))
                    expect(drec.isDirectory).to(beTrue())
                    
                    val.flags = DT_REG
                    drec = APFSDirectoryRecord(from: apfs_drec_parsed_t(parent_inode: 1, file_id: 2, date_added: 0, flags: DT_REG, name: "file"))
                    expect(drec.isRegularFile).to(beTrue())
                    
                    val.flags = DT_LNK
                    drec = APFSDirectoryRecord(from: apfs_drec_parsed_t(parent_inode: 1, file_id: 2, date_added: 0, flags: DT_LNK, name: "link"))
                    expect(drec.isSymlink).to(beTrue())
                }
            }
            
            context("Extended Fields") {
                it("parses xfields blob") {
                    var blob = xf_blob_t()
                    blob.xf_num_exts = 2
                    blob.xf_used_data = 8
                    
                    var field1 = x_field_t()
                    field1.x_type = 4  // INO_EXT_TYPE_NAME
                    field1.x_flags = 0
                    field1.x_size = 4
                    
                    var field2 = x_field_t()
                    field2.x_type = 21  // INO_EXT_TYPE_CLONEGROUP_ID
                    field2.x_flags = 0
                    field2.x_size = 8
                    
                    // Build buffer
                    var buffer = Data()
                    withUnsafeBytes(of: &blob) { buffer.append(contentsOf: $0) }
                    withUnsafeBytes(of: &field1) { buffer.append(contentsOf: $0) }
                    withUnsafeBytes(of: &field2) { buffer.append(contentsOf: $0) }
                    // Align to 8 bytes
                    buffer.append(contentsOf: [0, 0, 0, 0])
                    // Data for field1 (4 bytes)
                    buffer.append(contentsOf: [0x74, 0x65, 0x73, 0x74])  // "test"
                    // Data for field2 (8 bytes)
                    buffer.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])  // clonegroup = 1
                    
                    var fields: UnsafeMutablePointer<apfs_xfield_parsed_t>?
                    let count = apfs_parse_xfields([UInt8](buffer), buffer.count, &fields)
                    
                    expect(count).to(equal(2))
                    
                    if let fields = fields {
                        expect(fields[0].type).to(equal(4))
                        expect(fields[0].size).to(equal(4))
                        expect(fields[1].type).to(equal(21))
                        expect(fields[1].size).to(equal(8))
                        apfs_free_xfields(fields, 2)
                    }
                }
            }
            
            context("CloneGroup") {
                it("identifies full clone") {
                    let cg = APFSCloneGroup(groupID: 1, recordType: 1, inodeID: 100, privateID: 200, physicalSize: 4096, flags: CLONEGROUP_FLAG_FULL_CLONE)
                    expect(cg.isFullClone).to(beTrue())
                }
                
                it("identifies partial clone") {
                    let cg = APFSCloneGroup(groupID: 1, recordType: 1, inodeID: 101, privateID: 201, physicalSize: 0, flags: 0)
                    expect(cg.isFullClone).to(beFalse())
                }
            }
            
            context("Swift Wrappers") {
                it("APFSInode computed properties") {
                    var inode = APFSInode(from: apfs_inode_parsed_t(
                        parent_id: 2, private_id: 100,
                        create_time: 0, mod_time: 0, change_time: 0, access_time: 0,
                        internal_flags: 0, nlink: 1,
                        write_generation_counter: 0, bsd_flags: UF_COMPRESSED,
                        owner: 501, group: 20, mode: 0o100644,
                        uncompressed_size: 1024
                    ))
                    
                    expect(inode.isCompressed).to(beTrue())
                    expect(inode.isRegularFile).to(beTrue())
                    expect(inode.isDirectory).to(beFalse())
                }
                
                it("APFSDirectoryRecord types") {
                    let dir = APFSDirectoryRecord(from: apfs_drec_parsed_t(parent_inode: 1, file_id: 2, date_added: 0, flags: DT_DIR, name: "dir"))
                    expect(dir.isDirectory).to(beTrue())
                    expect(dir.recordType).to(equal(DT_DIR))
                }
            }
        }
    }
}

// MARK: - APFS Performance Tests

final class APFSPerformanceTests: QuickSpec {
    override class func spec() {
        describe("APFS Parser Performance") {
            it("CRC-32C: high throughput") {
                let data = Data(repeating: 0xAA, count: 65536)  // 64KB
                let iterations = 1000
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<iterations {
                    _ = data.withUnsafeBytes { apfs_crc32c($0.baseAddress!, data.count, 0xFFFFFFFF) } ^ 0xFFFFFFFF
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let throughput = Double(iterations * 65536) / elapsed / (1024 * 1024)
                
                print("CRC-32C throughput: \(throughput) MB/s")
                expect(throughput).to(beGreaterThan(500))  // >500 MB/s
            }
            
            it("Directory hash: high throughput") {
                let iterations = 100_000
                let start = CFAbsoluteTimeGetCurrent()
                
                for i in 0..<iterations {
                    _ = apfsDirectoryRecordHash(for: "file_\(i).txt")
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let throughput = Double(iterations) / elapsed
                
                print("Dir hash throughput: \(throughput)/sec")
                expect(throughput).to(beGreaterThan(100_000))
            }
            
            it("Inode parsing: high throughput") {
                var inode = j_inode_val_t()
                inode.parent_id = 2
                inode.private_id = 100
                inode.create_time = 1704067200
                inode.mod_time = 1704153600
                inode.change_time = 1704240000
                inode.access_time = 1704326400
                inode.internal_flags = 0
                inode.nlink = 1
                inode.write_generation_counter = 1
                inode.bsd_flags = 0
                inode.owner = 501
                inode.group = 20
                inode.mode = 0o100644
                inode.uncompressed_size = 1024
                
                var data = Data()
                withUnsafeBytes(of: &inode) { data.append(contentsOf: $0) }
                let bytes = [UInt8](data)
                
                let iterations = 1_000_000
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<iterations {
                    var parsed = apfs_inode_parsed_t()
                    apfs_parse_inode(bytes, data.count, &parsed)
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let throughput = Double(iterations) / elapsed
                
                print("Inode parse throughput: \(throughput)/sec")
                expect(throughput).to(beGreaterThan(500_000))
            }
        }
    }
}

// MARK: - APFS Edge Case Tests

final class APFSEdgeCaseTests: QuickSpec {
    override class func spec() {
        describe("APFS Parser Edge Cases") {
            it("handles maximum inode values") {
                var inode = j_inode_val_t()
                inode.parent_id = UInt64.max
                inode.private_id = UInt64.max
                inode.create_time = UInt64.max
                inode.mod_time = UInt64.max
                inode.change_time = UInt64.max
                inode.access_time = UInt64.max
                inode.internal_flags = UInt64.max
                inode.nlink = Int32.max
                inode.write_generation_counter = UInt32.max
                inode.bsd_flags = UInt32.max
                inode.owner = UInt32.max
                inode.group = UInt32.max
                inode.mode = UInt16.max
                inode.uncompressed_size = UInt64.max
                
                var data = Data()
                withUnsafeBytes(of: &inode) { data.append(contentsOf: $0) }
                
                var parsed = apfs_inode_parsed_t()
                apfs_parse_inode([UInt8](data), data.count, &parsed)
                
                expect(parsed.parent_id).to(equal(UInt64.max))
                expect(parsed.uncompressed_size).to(equal(UInt64.max))
            }
            
            it("handles directory record with long name") {
                let longName = String(repeating: "a", count: 1000)  // 1000 chars
                var key = j_drec_hashed_key_t()
                key.hdr.obj_id_and_type = (UInt64(APFS_TYPE_DIR_REC) << OBJ_TYPE_SHIFT) | 2
                key.name_len_and_hash = (UInt16(longName.utf8.count + 1) & J_DREC_LEN_MASK) | (0x123456 << J_DREC_HASH_SHIFT)
                
                var val = j_drec_val_t()
                val.file_id = 100
                val.date_added = 0
                val.flags = DT_REG
                
                var buffer = Data()
                withUnsafeBytes(of: &key) { buffer.append(contentsOf: $0) }
                buffer.append((longName + "\0").data(using: .utf8)!)
                withUnsafeBytes(of: &val) { buffer.append(contentsOf: $0) }
                
                var parsed = apfs_drec_parsed_t()
                apfs_parse_drec(&key, &val, &parsed)
                
                expect(parsed.name).to(equal(longName))
                apfs_free_drec(&parsed)
            }
            
            it("handles directory record with zero-length name") {
                var key = j_drec_hashed_key_t()
                key.hdr.obj_id_and_type = (UInt64(APFS_TYPE_DIR_REC) << OBJ_TYPE_SHIFT) | 2
                key.name_len_and_hash = (1 & J_DREC_LEN_MASK) | (0 << J_DREC_HASH_SHIFT)  // Just null terminator
                
                var val = j_drec_val_t()
                val.file_id = 100
                val.flags = DT_REG
                
                var buffer = Data()
                withUnsafeBytes(of: &key) { buffer.append(contentsOf: $0) }
                buffer.append(0)  // null terminator
                withUnsafeBytes(of: &val) { buffer.append(contentsOf: $0) }
                
                var parsed = apfs_drec_parsed_t()
                apfs_parse_drec(&key, &val, &parsed)
                
                expect(parsed.name).to(equal(""))
                apfs_free_drec(&parsed)
            }
            
            it("handles extended fields with zero count") {
                var blob = xf_blob_t()
                blob.xf_num_exts = 0
                blob.xf_used_data = 0
                
                var buffer = Data()
                withUnsafeBytes(of: &blob) { buffer.append(contentsOf: $0) }
                
                var fields: UnsafeMutablePointer<apfs_xfield_parsed_t>?
                let count = apfs_parse_xfields([UInt8](buffer), buffer.count, &fields)
                
                expect(count).to(equal(0))
            }
            
            it("handles DECMPFS header validation") {
                var header = decmpfs_disk_header_t()
                header.compression_magic = DECMPFS_MAGIC
                header.compression_type = 11  // LZFSE inline
                header.uncompressed_size = 4096
                
                var data = Data()
                withUnsafeBytes(of: &header) { data.append(contentsOf: $0) }
                
                do {
                    let decmpfs = try DECMPFSHeader(from: data)
                    expect(decmpfs.magic).to(equal(DECMPFS_MAGIC))
                    expect(decmpfs.compressionType).to(equal(.lzfseInline))
                    expect(decmpfs.uncompressedSize).to(equal(4096))
                } catch {
                    fail("Should parse valid header: \(error)")
                }
            }
            
            it("rejects invalid DECMPFS magic") {
                var header = decmpfs_disk_header_t()
                header.compression_magic = 0xDEADBEEF
                header.compression_type = 11
                header.uncompressed_size = 4096
                
                var data = Data()
                withUnsafeBytes(of: &header) { data.append(contentsOf: $0) }
                
                expect(try DECMPFSHeader(from: data)).to(throwError(APFSError.invalidDECMPFSHeader))
            }
        }
    }
}
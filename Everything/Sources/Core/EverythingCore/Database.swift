import Foundation
import Compression

// MARK: - Database Errors

public enum DatabaseError: Error, LocalizedError {
    case invalidMagic
    case versionMismatch(expected: UInt32, found: UInt32)
    case checksumMismatch
    case truncatedFile
    case invalidCompression
    case writeFailed(String)
    case readFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidMagic: return "Invalid database magic number"
        case .versionMismatch(let expected, let found): return "Version mismatch: expected \(expected), found \(found)"
        case .checksumMismatch: return "Checksum mismatch - file may be corrupted"
        case .truncatedFile: return "Database file is truncated"
        case .invalidCompression: return "Invalid compression data"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        }
    }

// MARK: - Database Header

struct DatabaseHeader {
    static let magic: UInt32 = 0x45565259  // "EVRY" in little-endian
    static let version: UInt32 = 0x01000001  // 1.0.0.1
    
    let magic: UInt32 = DatabaseHeader.magic
    let version: UInt32 = DatabaseHeader.version
    let flags: UInt32 = 0
    let volumeCount: UInt32 = 0
    let nodeCount: UInt32 = 0
    let creationTime: UInt64 = UInt64(Date().timeIntervalSince1970)
    let volumeTableOffset: UInt64 = 0
    let excludeListOffset: UInt64 = 0
    let nodeTableOffset: UInt64 = 0
    let propertyIndexesOffset: UInt64 = 0
    let stringTableOffset: UInt64 = 0
    let checksum: UInt64 = 0
    
    static let size = 88  // bytes
    
    func toData() -> Data {
        var data = Data()
        data.append(withUnsafeBytes(of: magic) { Data($0) })
        data.append(withUnsafeBytes(of: version) { Data($0) })
        data.append(withUnsafeBytes(of: flags) { Data($0) })
        data.append(withUnsafeBytes(of: volumeCount) { Data($0) })
        data.append(withUnsafeBytes(of: nodeCount) { Data($0) })
        data.append(withUnsafeBytes(of: creationTime) { Data($0) })
        data.append(withUnsafeBytes(of: volumeTableOffset) { Data($0) })
        data.append(withUnsafeBytes(of: excludeListOffset) { Data($0) })
        data.append(withUnsafeBytes(of: nodeTableOffset) { Data($0) })
        data.append(withUnsafeBytes(of: propertyIndexesOffset) { Data($0) })
        data.append(withUnsafeBytes(of: stringTableOffset) { Data($0) })
        data.append(withUnsafeBytes(of: checksum) { Data($0) })
        return data
    }
    
    static func from(data: Data) throws -> DatabaseHeader {
        guard data.count >= DatabaseHeader.size else { throw DatabaseError.truncatedFile }
        
        var header = DatabaseHeader()
        let bytes = [UInt8](data)
        
        header.magic = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard header.magic == DatabaseHeader.magic else { throw DatabaseError.invalidMagic }
        
        header.version = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard header.version == DatabaseHeader.version else {
            throw DatabaseError.versionMismatch(expected: DatabaseHeader.version, found: header.version)
        }
        
        header.flags = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        header.volumeCount = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
        header.nodeCount = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        header.creationTime = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt64.self) }
        header.volumeTableOffset = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt64.self) }
        header.excludeListOffset = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: UInt64.self) }
        header.nodeTableOffset = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44, as: UInt64.self) }
        header.propertyIndexesOffset = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 52, as: UInt64.self) }
        header.stringTableOffset = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 60, as: UInt64.self) }
        header.checksum = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 68, as: UInt64.self) }
        
        return header
    }

// MARK: - Database Writer

public final class DatabaseWriter {
    public let url: URL
    private let compressionAlgorithm: compression_algorithm = COMPRESSION_LZ4
    private let compressionLevel: Int = 4
    
    public init(url: URL) {
        self.url = url
    }
    
    public func write(_ snapshot: IndexSnapshot) throws {
        let tempURL = url.appendingPathExtension("tmp")
        
        // Ensure directory exists
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // Serialize snapshot
        let data = try serialize(snapshot)
        
        // Compress
        let compressed = try compress(data)
        
        // Compute checksum
        let checksum = xxHash64(compressed)
        
        // Build final data with header
        var finalData = Data()
        
        // Header (with placeholder checksum)
        var header = DatabaseHeader()
        header.nodeCount = UInt32(snapshot.totalNodes)
        header.volumeCount = UInt32(snapshot.volumeCount)
        header.nodeTableOffset = UInt64(DatabaseHeader.size)
        header.checksum = 0  // Will be filled after
        
        // Write header
        finalData.append(header.toData())
        
        // Write compressed data
        finalData.append(compressed)
        
        // Compute and update checksum
        let fullChecksum = xxHash64(finalData)
        var finalHeader = DatabaseHeader()
        finalHeader.nodeCount = UInt32(snapshot.totalNodes)
        finalHeader.volumeCount = UInt32(snapshot.volumeCount)
        finalHeader.nodeTableOffset = UInt64(DatabaseHeader.size)
        finalHeader.checksum = xxHash64(finalData.dropFirst(DatabaseHeader.size))  // Checksum of payload only
        
        // Rebuild final data with correct checksum
        finalData = Data()
        finalData.append(try buildHeader(nodeCount: UInt32(snapshot.totalNodes), volumeCount: UInt32(snapshot.volumeCount), payloadChecksum: xxHash64(compressed)))
        finalData.append(compressed)
        
        // Atomic write
        try finalData.write(to: tempURL, options: .atomic)
        try FileManager.default.moveItem(at: tempURL, to: url)
        
        Logger.shared.info("Database written", subsystem: "db", category: "write",
                          metadata: ["nodes": "\(snapshot.totalNodes)", "size": "\(finalData.count)", "checksum": String(format: "%016llx", xxHash64(finalData))])
        
        MetricsRegistry.shared.dbWritesTotal.inc()
    }
    
    private func buildHeader(nodeCount: UInt32, volumeCount: UInt32, payloadChecksum: UInt64) throws -> Data {
        var header = DatabaseHeader()
        header.nodeCount = nodeCount
        header.volumeCount = volumeCount
        header.checksum = payloadChecksum
        return header.toData()
    }
    
    private func serialize(_ snapshot: IndexSnapshot) throws -> Data {
        var data = Data()
        
        // Write volumes table
        // Simplified - would write actual volume info
        
        // Write exclude list (empty for now)
        
        // Write nodes
        for node in snapshot.nodes {
            try writeNode(node, to: &data)
        }
        
        // Write string table
        // Would build string table with prefix compression
        
        return data
    }
    
    private func writeNode(_ node: FSNode, to data: inout Data) throws {
        // Write fixed-size fields
        data.append(withUnsafeBytes(of: node.inodeID) { Data($0) })
        data.append(withUnsafeBytes(of: node.parentID) { Data($0) })
        data.append(withUnsafeBytes(of: node.privateID) { Data($0) })
        data.append(withUnsafeBytes(of: node.createTime) { Data($0) })
        data.append(withUnsafeBytes(of: node.createTimeNsec) { Data($0) })
        data.append(withUnsafeBytes(of: node.modTime) { Data($0) })
        data.append(withUnsafeBytes(of: node.modTimeNsec) { Data($0) })
        data.append(withUnsafeBytes(of: node.changeTime) { Data($0) })
        data.append(withUnsafeBytes(of: node.changeTimeNsec) { Data($0) })
        data.append(withUnsafeBytes(of: node.accessTime) { Data($0) })
        data.append(withUnsafeBytes(of: node.accessTimeNsec) { Data($0) })
        data.append(withUnsafeBytes(of: node.fileSize) { Data($0) })
        data.append(withUnsafeBytes(of: node.uncompressedSize) { Data($0) })
        data.append(withUnsafeBytes(of: node.mode) { Data($0) })
        data.append(withUnsafeBytes(of: node.flags) { Data($0) })
        data.append(withUnsafeBytes(of: node.bsdFlags) { Data($0) })
        data.append(withUnsafeBytes(of: node.owner) { Data($0) })
        data.append(withUnsafeBytes(of: node.group) { Data($0) })
        data.append(withUnsafeBytes(of: node.writeGen) { Data($0) })
        data.append(withUnsafeBytes(of: node.cloneGroupID ?? 0) { Data($0) })
        data.append(withUnsafeBytes(of: node.hardLinkCount) { Data($0) })
        data.append(withUnsafeBytes(of: node.volumeID) { Data($0) })
        
        // Write strings (name and path) with length prefix
        writeString(node.name, to: &data)
        writeString(node.path, to: &data)
        writeUUID(node.apfsVolumeUUID, to: &data)
        
        // Optional fields
        writeOptionalUInt32(node.volfsVolumeID, to: &data)
        writeOptionalUInt32(node.filerefVolumeID, to: &data)
    }
    
    private func writeString(_ string: String, to data: inout Data) {
        let utf8 = string.data(using: .utf8)!
        data.append(withUnsafeBytes(of: UInt32(utf8.count)) { Data($0) })
        data.append(utf8)
    }
    
    private func writeUUID(_ uuid: UUID, to data: inout Data) {
        var uuidBytes = uuid.uuid
        data.append(withUnsafeBytes(of: &uuidBytes) { Data($0) })
    }
    
    private func writeOptionalUInt32(_ value: UInt32?, to data: inout Data) {
        let hasValue = value != nil ? UInt8(1) : UInt8(0)
        data.append(withUnsafeBytes(of: hasValue) { Data($0) })
        if let value = value {
            data.append(withUnsafeBytes(of: value) { Data($0) })
        }
    }
    
    private func compress(_ data: Data) throws -> Data {
        guard data.count > 0 else { return Data() }
        
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        defer { destinationBuffer.deallocate() }
        
        let compressedSize = data.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Int in
            compression_encode_buffer(
                destinationBuffer, data.count,
                sourceBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                nil, compressionAlgorithm
            )
        }
        
        guard compressedSize > 0 else {
            throw DatabaseError.invalidCompression
        }
        
        return Data(bytes: destinationBuffer, count: compressedSize)
    }
}

// MARK: - Database Reader

public final class DatabaseReader {
    public let url: URL
    private var mappedData: Data?
    private var header: DatabaseHeader?
    
    public init(url: URL) {
        self.url = url
    }
    
    public func read() throws -> IndexSnapshot {
        let data = try Data(contentsOf: url)
        
        // Verify checksum
        let header = try DatabaseHeader.from(data: data)
        let payload = data.dropFirst(DatabaseHeader.size)
        let payloadChecksum = xxHash64(payload)
        
        guard header.checksum == xxHash64(payload) else {
            throw DatabaseError.checksumMismatch
        }
        
        // Decompress payload
        let decompressed = try decompress(payload)
        
        // Deserialize
        return try deserialize(decompressed)
    }
    
    private func decompress(_ data: Data) throws -> Data {
        guard data.count > 0 else { return Data() }
        
        // Estimate decompressed size (use 4x as upper bound for LZ4)
        let estimatedSize = data.count * 4
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: estimatedSize)
        defer { destinationBuffer.deallocate() }
        
        let decompressedSize = data.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Int in
            compression_decode_buffer(
                destinationBuffer, estimatedSize,
                sourceBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_LZ4
            )
        }
        
        guard decompressedSize > 0 else {
            throw DatabaseError.invalidCompression
        }
        
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
    
    private func deserialize(_ data: Data) throws -> IndexSnapshot {
        var offset = 0
        let bytes = [UInt8](data)
        
        // Read header info
        // For now, return empty - full implementation would parse all nodes
        return IndexSnapshot.empty()
    }
}

// MARK: - xxHash64

private func xxHash64(_ data: Data) -> UInt64 {
    // Simplified xxHash64 - in production use a proper implementation
    var hash: UInt64 = 0
    for byte in data {
        hash = hash &* 31 &+ UInt64(byte)
    }
    return hash
}

// MARK: - Metrics (re-export)

import EverythingCore
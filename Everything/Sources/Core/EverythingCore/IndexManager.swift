import Foundation

// MARK: - Index Manager

public final class IndexManager {
    public static let shared = IndexManager()
    
    private var currentSnapshot: IndexSnapshot
    private let snapshotQueue = DispatchQueue(label: "index.snapshot", attributes: .concurrent)
    private let writeQueue = DispatchQueue(label: "index.writer", qos: .utility)
    
    // Fast-sort index flags
    private var fastSortEnabled: Set<FastSortProperty> = []
    
    private init() {
        self.currentSnapshot = IndexSnapshot.empty()
    }
    
    // MARK: - Index Building
    
    public func buildIndex(_ nodes: [FSNode]) {
        let snapshot = IndexSnapshot(nodes: nodes, fastSortEnabled: fastSortEnabled)
        
        snapshotQueue.async(flags: .barrier) {
            self.currentSnapshot = snapshot
        }
        
        Logger.shared.info("Index built", subsystem: "index", category: "build",
                          metadata: ["nodes": "\(nodes.count)", "memory": "\(snapshot.estimatedMemoryBytes)"])
        
        MetricsRegistry.shared.indexNodeCount.set(Double(snapshot.totalNodes))
        MetricsRegistry.shared.indexMemoryBytes.set(Double(snapshot.estimatedMemoryBytes))
    }
    
    public func enableFastSort(_ properties: [FastSortProperty]) {
        fastSortEnabled.formUnion(properties)
    }
    
    public func disableFastSort(_ properties: [FastSortProperty]) {
        fastSortEnabled.subtract(properties)
    }
    
    // MARK: - Snapshot Access
    
    public var currentSnapshot: IndexSnapshot {
        snapshotQueue.sync {
            currentSnapshot
        }
    }
    
    // MARK: - Delta Application
    
    public func apply(_ delta: IndexDelta, to snapshot: IndexSnapshot? = nil) -> IndexSnapshot {
        let base = snapshot ?? currentSnapshot
        return writeQueue.sync {
            var newNodes = base.nodes
            
            switch delta {
            case .insert(let node):
                newNodes.append(node)
                
            case .remove(let inodeID, let volumeID):
                newNodes.removeAll { $0.inodeID == inodeID && $0.volumeID == volumeID }
                
            case .move(let inodeID, let volumeID, let newParentID, let newName):
                if let idx = newNodes.firstIndex(where: { $0.inodeID == inodeID && $0.volumeID == volumeID }) {
                    var node = newNodes[idx]
                    // Create updated node with new parent and name
                    let updated = FSNode(
                        inodeID: node.inodeID,
                        parentID: newParentID,
                        privateID: node.privateID,
                        name: newName,
                        createTime: node.createTime,
                        createTimeNsec: node.createTimeNsec,
                        modTime: node.modTime,
                        modTimeNsec: node.modTimeNsec,
                        changeTime: Date().timeIntervalSince1970,
                        changeTimeNsec: 0,
                        accessTime: node.accessTime,
                        accessTimeNsec: node.accessTimeNsec,
                        fileSize: node.fileSize,
                        uncompressedSize: node.uncompressedSize,
                        mode: node.mode,
                        flags: node.flags,
                        bsdFlags: node.bsdFlags,
                        owner: node.owner,
                        group: node.group,
                        writeGen: node.writeGen + 1,
                        cloneGroupID: node.cloneGroupID,
                        hardLinkCount: node.hardLinkCount,
                        volumeID: node.volumeID,
                        apfsVolumeUUID: node.apfsVolumeUUID,
                        volfsVolumeID: node.volfsVolumeID,
                        filerefVolumeID: node.filerefVolumeID,
                        path: computeNewPath(node: node, newParentID: newParentID, newName: newName, snapshot: currentSnapshot),
                        depth: node.depth + 1 // Simplified
                    )
                    newNodes[idx] = updated
                }
                
            case .updateSize(let inodeID, let volumeID, let newSize):
                if let idx = newNodes.firstIndex(where: { $0.inodeID == inodeID && $0.volumeID == volumeID }) {
                    var node = newNodes[idx]
                    newNodes[idx] = FSNode(
                        inodeID: node.inodeID,
                        parentID: node.parentID,
                        privateID: node.privateID,
                        name: node.name,
                        createTime: node.createTime,
                        createTimeNsec: node.createTimeNsec,
                        modTime: Date().timeIntervalSince1970,
                        modTimeNsec: 0,
                        changeTime: node.changeTime,
                        changeTimeNsec: node.changeTimeNsec,
                        accessTime: node.accessTime,
                        accessTimeNsec: node.accessTimeNsec,
                        fileSize: newSize,
                        uncompressedSize: node.uncompressedSize,
                        mode: node.mode,
                        flags: node.flags,
                        bsdFlags: node.bsdFlags,
                        owner: node.owner,
                        group: node.group,
                        writeGen: node.writeGen + 1,
                        cloneGroupID: node.cloneGroupID,
                        hardLinkCount: node.hardLinkCount,
                        volumeID: node.volumeID,
                        apfsVolumeUUID: node.apfsVolumeUUID,
                        volfsVolumeID: node.volfsVolumeID,
                        filerefVolumeID: node.filerefVolumeID,
                        path: node.path,
                        depth: node.depth
                    )
                }
                
            case .updateAttrs(let inodeID, let volumeID, let bsdFlags, let modTime, let modTimeNsec):
                if let idx = newNodes.firstIndex(where: { $0.inodeID == inodeID && $0.volumeID == volumeID }) {
                    var node = newNodes[idx]
                    newNodes[idx] = FSNode(
                        inodeID: node.inodeID,
                        parentID: node.parentID,
                        privateID: node.privateID,
                        name: node.name,
                        createTime: node.createTime,
                        createTimeNsec: node.createTimeNsec,
                        modTime: modTime,
                        modTimeNsec: modTimeNsec,
                        changeTime: Date().timeIntervalSince1970,
                        changeTimeNsec: 0,
                        accessTime: node.accessTime,
                        accessTimeNsec: node.accessTimeNsec,
                        fileSize: node.fileSize,
                        uncompressedSize: node.uncompressedSize,
                        mode: node.mode,
                        flags: node.flags,
                        bsdFlags: bsdFlags,
                        owner: node.owner,
                        group: node.group,
                        writeGen: node.writeGen + 1,
                        cloneGroupID: node.cloneGroupID,
                        hardLinkCount: node.hardLinkCount,
                        volumeID: node.volumeID,
                        apfsVolumeUUID: node.apfsVolumeUUID,
                        volfsVolumeID: node.volfsVolumeID,
                        filerefVolumeID: node.filerefVolumeID,
                        path: node.path,
                        depth: node.depth
                    )
                }
                
            case .updateCloneGroup(let inodeID, let volumeID, let cloneGroupID):
                if let idx = newNodes.firstIndex(where: { $0.inodeID == inodeID && $0.volumeID == volumeID }) {
                    var node = newNodes[idx]
                    newNodes[idx] = FSNode(
                        inodeID: node.inodeID,
                        parentID: node.parentID,
                        privateID: node.privateID,
                        name: node.name,
                        createTime: node.createTime,
                        createTimeNsec: node.createTimeNsec,
                        modTime: node.modTime,
                        modTimeNsec: node.modTimeNsec,
                        changeTime: Date().timeIntervalSince1970,
                        changeTimeNsec: 0,
                        accessTime: node.accessTime,
                        accessTimeNsec: node.accessTimeNsec,
                        fileSize: node.fileSize,
                        uncompressedSize: node.uncompressedSize,
                        mode: node.mode,
                        flags: node.flags,
                        bsdFlags: node.bsdFlags,
                        owner: node.owner,
                        group: node.group,
                        writeGen: node.writeGen + 1,
                        cloneGroupID: cloneGroupID,
                        hardLinkCount: node.hardLinkCount,
                        volumeID: node.volumeID,
                        apfsVolumeUUID: node.apfsVolumeUUID,
                        volfsVolumeID: node.volfsVolumeID,
                        filerefVolumeID: node.filerefVolumeID,
                        path: node.path,
                        depth: node.depth
                    )
                }
                
            case .updateHardLinks(let inodeID, let volumeID, let count):
                if let idx = newNodes.firstIndex(where: { $0.inodeID == inodeID && $0.volumeID == volumeID }) {
                    var node = newNodes[idx]
                    newNodes[idx] = FSNode(
                        inodeID: node.inodeID,
                        parentID: node.parentID,
                        privateID: node.privateID,
                        name: node.name,
                        createTime: node.createTime,
                        createTimeNsec: node.createTimeNsec,
                        modTime: node.modTime,
                        modTimeNsec: node.modTimeNsec,
                        changeTime: node.changeTime,
                        changeTimeNsec: node.changeTimeNsec,
                        accessTime: node.accessTime,
                        accessTimeNsec: node.accessTimeNsec,
                        fileSize: node.fileSize,
                        uncompressedSize: node.uncompressedSize,
                        mode: node.mode,
                        flags: node.flags,
                        bsdFlags: node.bsdFlags,
                        owner: node.owner,
                        group: node.group,
                        writeGen: node.writeGen,
                        cloneGroupID: node.cloneGroupID,
                        hardLinkCount: count,
                        volumeID: node.volumeID,
                        apfsVolumeUUID: node.apfsVolumeUUID,
                        volfsVolumeID: node.volfsVolumeID,
                        filerefVolumeID: node.filerefVolumeID,
                        path: node.path,
                        depth: node.depth
                    )
                }
                
            case .volumeMounted(let volume):
                // Add volume to tracked volumes
                break
                
            case .volumeUnmounted(let volumeUUID):
                // Remove nodes from this volume
                newNodes.removeAll { $0.apfsVolumeUUID == volumeUUID }
            }
            
            // Rebuild snapshot with new nodes
            let newSnapshot = IndexSnapshot(nodes: newNodes, fastSortEnabled: fastSortEnabled)
            
            // Update current snapshot
            snapshotQueue.async(flags: .barrier) {
                self.currentSnapshot = newSnapshot
            }
            
            // Update metrics
            MetricsRegistry.shared.indexNodeCount.set(Double(newSnapshot.totalNodes))
            MetricsRegistry.shared.indexMemoryBytes.set(Double(newSnapshot.estimatedMemoryBytes))
            MetricsRegistry.shared.indexUpdatesTotal.inc()
            
            return newSnapshot
        }
    }
    
    public func applyBatch(_ deltas: [IndexDelta], to snapshot: IndexSnapshot? = nil) -> IndexSnapshot {
        let base = snapshot ?? currentSnapshot
        return writeQueue.sync {
            var newNodes = base.nodes
            
            for delta in deltas {
                // Apply each delta (simplified - real impl would be more efficient)
                let intermediateSnapshot = IndexSnapshot(nodes: newNodes, fastSortEnabled: fastSortEnabled)
                let resultSnapshot = apply(delta, to: intermediateSnapshot)
                newNodes = resultSnapshot.nodes
            }
            
            let newSnapshot = IndexSnapshot(nodes: newNodes, fastSortEnabled: fastSortEnabled)
            snapshotQueue.async(flags: .barrier) {
                self.currentSnapshot = newSnapshot
            }
            
            return newSnapshot
        }
    }
    
    // MARK: - Helpers
    
    private func computeNewPath(node: FSNode, newParentID: UInt64, newName: String, snapshot: IndexSnapshot) -> String {
        if let parent = snapshot.nodesByInode[CompositeKey(deviceID: node.volumeID, inodeID: newParentID)] {
            return parent.path + "/" + newName
        }
        return "/" + newName
    }
}

// MARK: - Fast Sort Properties

public enum FastSortProperty: Hashable {
    case size
    case modTime
    case createTime
    case extension
    case path
}

// MARK: - Index Snapshot

public struct IndexSnapshot {
    public let nodes: [FSNode]
    public let totalNodes: Int
    public let volumeCount: Int
    public let lastUpdateTime: UInt64
    public let estimatedMemoryBytes: UInt64
    
    // Primary indexes
    public let nodesByName: SortedArray<FSNode>
    public let nodesByPath: SortedArray<FSNode>
    public let nodesByInode: [CompositeKey: FSNode]
    public let nodesByParent: [CompositeKey: [FSNode]]
    
    // Fast-sort indexes (optional)
    public let nodesBySize: SortedArray<FSNode>?
    public let nodesByModTime: SortedArray<FSNode>?
    public let nodesByCreateTime: SortedArray<FSNode>?
    public let nodesByExtension: SortedArray<FSNode>?
    
    public static func empty() -> IndexSnapshot {
        return IndexSnapshot(
            nodes: [],
            totalNodes: 0,
            volumeCount: 0,
            lastUpdateTime: UInt64(Date().timeIntervalSince1970),
            estimatedMemoryBytes: 0,
            nodesByName: SortedArray([]),
            nodesByPath: SortedArray([]),
            nodesByInode: [:],
            nodesByParent: [:],
            nodesBySize: nil,
            nodesByModTime: nil,
            nodesByCreateTime: nil,
            nodesByExtension: nil
        )
    }
    
    init(nodes: [FSNode], fastSortEnabled: Set<FastSortProperty>) {
        self.nodes = nodes
        self.totalNodes = nodes.count
        
        // Compute volumes
        let volumeUUIDs = Set(nodes.map { $0.apfsVolumeUUID })
        self.volumeCount = volumeUUIDs.count
        
        // Last update time
        self.lastUpdateTime = UInt64(Date().timeIntervalSince1970)
        
        // Estimate memory
        self.estimatedMemoryBytes = nodes.reduce(0) { $0 + UInt64(MemoryLayout<FSNode>.stride) }
        
        // Build primary indexes
        let nameSorted = nodes.sorted { $0.name < $1.name }
        self.nodesByName = SortedArray(nameSorted)
        
        let pathSorted = nodes.sorted { $0.path < $1.path }
        self.nodesByPath = SortedArray(pathSorted)
        
        var inodeMap: [CompositeKey: FSNode] = [:]
        var parentMap: [CompositeKey: [FSNode]] = [:]
        
        for node in nodes {
            let key = CompositeKey(deviceID: node.volumeID, inodeID: node.inodeID)
            inodeMap[key] = node
            
            let parentKey = CompositeKey(deviceID: node.volumeID, inodeID: node.parentID)
            parentMap[parentKey, default: []].append(node)
        }
        
        self.nodesByInode = inodeMap
        self.nodesByParent = parentMap
        
        // Build fast-sort indexes if enabled
        if fastSortEnabled.contains(.size) {
            self.nodesBySize = SortedArray(nodes.sorted { $0.fileSize < $1.fileSize })
        } else {
            self.nodesBySize = nil
        }
        
        if fastSortEnabled.contains(.modTime) {
            self.nodesByModTime = SortedArray(nodes.sorted { $0.modTime < $1.modTime })
        } else {
            self.nodesByModTime = nil
        }
        
        if fastSortEnabled.contains(.createTime) {
            self.nodesByCreateTime = SortedArray(nodes.sorted { $0.createTime < $1.createTime })
        } else {
            self.nodesByCreateTime = nil
        }
        
        if fastSortEnabled.contains(.extension) {
            self.nodesByExtension = SortedArray(nodes.sorted { $0.extension < $1.extension })
        } else {
            self.nodesByExtension = nil
        }
    }
}

// MARK: - Sorted Array with Binary Search

public struct SortedArray<Element: Comparable> {
    private let elements: [Element]
    
    public init(_ elements: [Element]) {
        self.elements = elements.sorted()
    }
    
    public var count: Int { elements.count }
    
    public var first: Element? { elements.first }
    
    public var last: Element? { elements.last }
    
    public func prefixRange(_ prefix: String) -> CandidateSet where Element == FSNode {
        // Binary search for prefix range
        let lower = prefix
        let upper = prefix + String(Character(UnicodeScalar(UInt32.max)!))
        
        let start = elements.partitioningIndex { $0.name < lower }
        let end = elements.partitioningIndex { $0.name < upper }
        
        return CandidateSet(elements: Array(elements[start..<end]))
    }
    
    public func range(_ range: ClosedRange<UInt64>) -> CandidateSet where Element == FSNode {
        let start = elements.partitioningIndex { $0.fileSize < range.lowerBound }
        let end = elements.partitioningIndex { $0.fileSize <= range.upperBound }
        
        return CandidateSet(elements: Array(elements[start..<end]))
    }
    
    public subscript(index: Int) -> Element {
        elements[index]
    }
}

extension Array where Element: Comparable {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

// MARK: - Candidate Set

public struct CandidateSet {
    let elements: [FSNode]
    
    public var count: Int { elements.count }
    public var first: FSNode? { elements.first }
    
    init(elements: [FSNode]) {
        self.elements = elements
    }
    
    static var empty: CandidateSet { CandidateSet(elements: []) }
    
    func filter(_ predicate: (FSNode) -> Bool) -> CandidateSet {
        CandidateSet(elements: elements.filter(predicate))
    }
    
    func intersect(_ other: CandidateSet) -> CandidateSet {
        let otherSet = Set(other.elements.map { $0.inodeID })
        return CandidateSet(elements: elements.filter { otherSet.contains($0.inodeID) })
    }
    
    func union(_ other: CandidateSet) -> CandidateSet {
        var seen = Set<UInt64>()
        var result: [FSNode] = []
        for element in elements + other.elements {
            if seen.insert(element.inodeID).inserted {
                result.append(element)
            }
        }
        return CandidateSet(elements: result)
    }
    
    func difference(_ other: CandidateSet) -> CandidateSet {
        let otherSet = Set(other.elements.map { $0.inodeID })
        return CandidateSet(elements: elements.filter { !otherSet.contains($0.inodeID) })
    }
}

// MARK: - Composite Key

public struct CompositeKey: Hashable, Equatable {
    public let deviceID: UInt32
    public let inodeID: UInt64
    
    public init(deviceID: UInt32, inodeID: UInt64) {
        self.deviceID = deviceID
        self.inodeID = inodeID
    }
}

// MARK: - Search Engine

public struct SearchEngine {
    public static let shared = SearchEngine()
    
    public static func compile(query: String, options: SearchOptions) throws -> [SearchOpcode] {
        // Parse query string into bytecode
        // This is a simplified implementation
        return [.namePrefix(query)]
    }
    
    public static func execute(_ query: SearchQuery, against snapshot: IndexSnapshot) async throws -> [SearchResult] {
        let vm = BytecodeVM()
        let candidates = vm.execute(query.bytecode, against: snapshot)
        
        var results: [SearchResult] = []
        for node in candidates.elements.prefix(query.limit) {
            results.append(SearchResult(
                path: node.path,
                name: node.name,
                fileSize: node.fileSize,
                modTime: node.modTime,
                modTimeNsec: node.modTimeNsec,
                createTime: node.createTime,
                createTimeNsec: node.createTimeNsec,
                isDirectory: node.isDirectory,
                volumeID: node.volumeID,
                inodeID: node.inodeID
            ))
        }
        
        return results
    }
}

// MARK: - Search Query

public struct SearchQuery {
    public let bytecode: [SearchOpcode]
    public var limit: Int = 1000
    public var offset: Int = 0
    public var filters: [SearchFilter] = []
    public var sort: SortDescriptor?
    
    public init(bytecode: [SearchOpcode], limit: Int = 1000, offset: Int = 0) {
        self.bytecode = bytecode
        self.limit = limit
        self.offset = offset
    }
}

// MARK: - Search Result

public struct SearchResult: Codable {
    public let path: String
    public let name: String
    public let fileSize: UInt64
    public let modTime: UInt64
    public let modTimeNsec: UInt32
    public let createTime: UInt64
    public let createTimeNsec: UInt32
    public let isDirectory: Bool
    public let volumeID: UInt32
    public let inodeID: UInt64
}
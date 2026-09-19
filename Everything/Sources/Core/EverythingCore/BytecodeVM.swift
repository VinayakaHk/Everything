import Foundation

// MARK: - Search Opcodes

public enum SearchOpcode: Equatable {
    // Indexed filters (binary search on sorted arrays)
    case namePrefix(String)
    case pathPrefix(String)
    case extensionMatch(String)
    case sizeRange(ClosedRange<UInt64>)
    case modTimeRange(ClosedRange<UInt64>)
    case createTimeRange(ClosedRange<UInt64>)
    case cloneGroup(UInt64)
    case hardLinkCount(Int)
    case volumeFilter(UUID)
    case bsdFlags(UInt32)
    case cloneGroupID(UInt64)
    case fileType(FileType)
    
    // Non-indexed filters (linear scan)
    case regex(NSRegularExpression)
    case content(String)
    case attribute(String)
    case custom((FSNode) -> Bool)
    
    // Boolean logic
    case and
    case or
    case not
    
    // Control flow
    case groupStart
    case groupEnd
    case limit(Int)
    case offset(Int)
    
    // Output
    case sortBy(SearchProperty, ascending: Bool)
    case distinct(SearchProperty)
    
    public static func == (lhs: SearchOpcode, rhs: SearchOpcode) -> Bool {
        switch (lhs, rhs) {
        case (.namePrefix(let a), .namePrefix(let b)): return a == b
        case (.pathPrefix(let a), .pathPrefix(let b)): return a == b
        case (.extensionMatch(let a), .extensionMatch(let b)): return a == b
        case (.sizeRange(let a), .sizeRange(let b)): return a == b
        case (.modTimeRange(let a), .modTimeRange(let b)): return a == b
        case (.createTimeRange(let a), .createTimeRange(let b)): return a == b
        case (.cloneGroup(let a), .cloneGroup(let b)): return a == b
        case (.hardLinkCount(let a), .hardLinkCount(let b)): return a == b
        case (.volumeFilter(let a), .volumeFilter(let b)): return a == b
        case (.bsdFlags(let a), .bsdFlags(let b)): return a == b
        case (.cloneGroupID(let a), .cloneGroupID(let b)): return a == b
        case (.fileType(let a), .fileType(let b)): return a == b
        case (.and, .and), (.or, .or), (.not, .not): return true
        case (.groupStart, .groupStart), (.groupEnd, .groupEnd): return true
        case (.limit(let a), .limit(let b)): return a == b
        case (.offset(let a), .offset(let b)): return a == b
        case (.sortBy(let a, let b), .sortBy(let c, let d)): return a == c && b == d
        case (.distinct(let a), .distinct(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - File Type

public enum FileType: UInt16, Codable, CaseIterable {
    case regular = 0o100000
    case directory = 0o040000
    case symlink = 0o120000
    case characterDevice = 0o020000
    case blockDevice = 0o060000
    case fifo = 0o010000
    case socket = 0o140000
    case whiteout = 0o160000
    
    public init?(mode: UInt16) {
        let type = mode & 0o170000
        self.init(rawValue: type)
    }
}

// MARK: - Bytecode VM

public final class BytecodeVM {
    public init() {}
    
    public func execute(_ bytecode: [SearchOpcode], against snapshot: IndexSnapshot, context: SearchContext = SearchContext()) -> SearchResults {
        var stack: [CandidateSet] = []
        var groupStack: [GroupFrame] = []
        var currentCandidates = CandidateSet.all(snapshot)
        
        for (index, opcode) in bytecode.enumerated() {
            do {
                switch opcode {
                // Indexed filters
                case .namePrefix(let prefix):
                    currentCandidates = currentCandidates.intersect(snapshot.nodesByName.prefixRange(prefix))
                    
                case .pathPrefix(let prefix):
                    currentCandidates = currentCandidates.intersect(snapshot.nodesByPath.prefixRange(prefix))
                    
                case .extensionMatch(let ext):
                    if let extIndex = snapshot.nodesByExtension {
                        currentCandidates = currentCandidates.intersect(extIndex.prefixRange(ext))
                    } else {
                        currentCandidates = currentCandidates.filter { $0.extension == ext }
                    }
                    
                case .sizeRange(let range):
                    if let sizeIndex = snapshot.nodesBySize {
                        currentCandidates = currentCandidates.intersect(sizeIndex.range(range))
                    } else {
                        currentCandidates = currentCandidates.filter { range.contains($0.fileSize) }
                    }
                    
                case .modTimeRange(let range):
                    if let timeIndex = snapshot.nodesByModTime {
                        currentCandidates = currentCandidates.intersect(timeIndex.range(range))
                    } else {
                        currentCandidates = currentCandidates.filter { range.contains($0.modTime) }
                    }
                    
                case .createTimeRange(let range):
                    if let timeIndex = snapshot.nodesByCreateTime {
                        currentCandidates = currentCandidates.intersect(timeIndex.range(range))
                    } else {
                        currentCandidates = currentCandidates.filter { range.contains($0.createTime) }
                    }
                    
                case .cloneGroup(let groupID):
                    currentCandidates = currentCandidates.filter { $0.cloneGroupID == groupID }
                    
                case .hardLinkCount(let count):
                    currentCandidates = currentCandidates.filter { $0.hardLinkCount >= count }
                    
                case .volumeFilter(let uuid):
                    currentCandidates = currentCandidates.filter { $0.apfsVolumeUUID == uuid }
                    
                case .bsdFlags(let flags):
                    currentCandidates = currentCandidates.filter { ($0.bsdFlags & flags) == flags }
                    
                case .cloneGroupID(let groupID):
                    currentCandidates = currentCandidates.filter { $0.cloneGroupID == groupID }
                    
                case .fileType(let type):
                    currentCandidates = currentCandidates.filter { FileType(mode: $0.mode) == type }
                    
                // Non-indexed filters
                case .regex(let regex):
                    currentCandidates = currentCandidates.filter { regex.firstMatch(in: $0.name, options: [], range: NSRange(location: 0, length: $0.name.utf16.count)) != nil }
                    
                case .content(let query):
                    // Delegate to Spotlight/mdfind - placeholder
                    currentCandidates = currentCandidates.filter { _ in false }
                    
                case .attribute(let attrName):
                    // Check extended attributes - placeholder
                    currentCandidates = currentCandidates.filter { _ in false }
                    
                case .custom(let predicate):
                    currentCandidates = currentCandidates.filter(predicate)
                    
                // Boolean logic
                case .and:
                    guard stack.count >= 2 else { throw VMError.stackUnderflow("AND requires 2 operands") }
                    let rhs = stack.removeLast()
                    let lhs = stack.removeLast()
                    stack.append(lhs.intersect(rhs))
                    
                case .or:
                    guard stack.count >= 2 else { throw VMError.stackUnderflow("OR requires 2 operands") }
                    let rhs = stack.removeLast()
                    let lhs = stack.removeLast()
                    stack.append(lhs.union(rhs))
                    
                case .not:
                    guard stack.count >= 1 else { throw VMError.stackUnderflow("NOT requires 1 operand") }
                    let operand = stack.removeLast()
                    stack.append(CandidateSet.all(currentSnapshot: currentSnapshot).difference(operand))
                
                // Control flow
                case .groupStart:
                    groupStack.append(GroupFrame(stackCount: stack.count))
                    
                case .groupEnd:
                    guard let frame = groupStack.popLast() else { throw VMError.groupMismatch("Unmatched groupEnd") }
                    // Group just manages stack frame, results stay on stack
                
                case .limit(let n):
                    // Applied at end
                    groupStack.append(GroupFrame(limit: n))
                    
                case .offset(let n):
                    groupStack.append(GroupFrame(offset: n))
                    
                // Output
                case .sortBy(let property, let ascending):
                    // Sorting applied at end
                    groupStack.append(GroupFrame(sortBy: property, ascending: ascending))
                    
                case .distinct(let property):
                    groupStack.append(GroupFrame(distinctBy: property))
                }
            } catch {
                Logger.shared.error("VM error at opcode \(index): \(error)", subsystem: "vm", category: "execution")
                // Continue with empty results
                currentCandidates = CandidateSet.empty
            }
        }
        
        // Apply post-processing from group stack
        var finalCandidates = currentCandidates
        
        // Collect post-processing operations
        var limit: Int?
        var offset: Int?
        var sorts: [(SearchProperty, Bool)] = []
        var distinctBy: SearchProperty?
        
        for frame in groupStack {
            if let l = frame.limit { limit = l }
            if let o = frame.offset { offset = o }
            if let (prop, asc) = frame.sortBy { sorts.append((prop, asc)) }
            if let d = frame.distinctBy { distinctBy = d }
        }
        
        // Apply distinct
        if let distinctBy = distinctBy {
            var seen = Set<UInt64>()
            var unique: [FSNode] = []
            for node in finalCandidates.elements {
                let key = distinctKey(for: node, property: distinctBy)
                if seen.insert(key).inserted {
                    unique.append(node)
                }
            }
            finalCandidates = CandidateSet(elements: unique)
        }
        
        // Apply sorts (last sort wins for primary, but we'd implement multi-level sort)
        for (property, ascending) in sorts.reversed() {
            finalCandidates = finalCandidates.sorted { a, b in
                let cmp = compareNodes(a, b, by: property)
                return ascending ? cmp < 0 : cmp > 0
            }
        }
        
        // Apply offset
        if let offset = offset, offset > 0 {
            if offset < finalCandidates.count {
                finalCandidates = CandidateSet(elements: Array(finalCandidates.elements.dropFirst(offset)))
            } else {
                finalCandidates = CandidateSet.empty
            }
        }
        
        // Apply limit
        if let limit = limit {
            if limit < finalCandidates.count {
                finalCandidates = CandidateSet(elements: Array(finalCandidates.elements.prefix(limit)))
            }
        }
        
        return SearchResults(candidates: finalCandidates, totalCount: finalCandidates.count)
    }
    
    private func distinctKey(for node: FSNode, property: SearchProperty) -> UInt64 {
        switch property {
        case .name: return node.name.hashValue
        case .size: return node.fileSize
        case .modified: return node.modTime
        case .created: return node.createTime
        case .accessed: return node.accessTime
        case .changed: return node.changeTime
        case .extension: return node.extension.hashValue
        case .writeGen: return UInt64(node.writeGen)
        default: return node.inodeID
        }
    }
    
    private func compareNodes(_ a: FSNode, _ b: FSNode, by property: SearchProperty) -> Int {
        switch property {
        case .name:
            return a.name.compare(b.name).rawValue
        case .size:
            return a.fileSize < b.fileSize ? -1 : (a.fileSize > b.fileSize ? 1 : 0)
        case .modified:
            return a.modTime < b.modTime ? -1 : (a.modTime > b.modTime ? 1 : 0)
        case .created:
            return a.createTime < b.createTime ? -1 : (a.createTime > b.createTime ? 1 : 0)
        case .accessed:
            return a.accessTime < b.accessTime ? -1 : (a.accessTime > b.accessTime ? 1 : 0)
        case .changed:
            return a.changeTime < b.changeTime ? -1 : (a.changeTime > b.changeTime ? 1 : 0)
        case .extension:
            return a.extension.compare(b.extension).rawValue
        case .writeGen:
            return a.writeGen < b.writeGen ? -1 : (a.writeGen > b.writeGen ? 1 : 0)
        }
    }
}

// MARK: - Supporting Types

struct SearchContext {
    let timestamp = Date()
    let correlationID = UUID().uuidString
}

struct GroupFrame {
    let stackCount: Int?
    let limit: Int?
    let offset: Int?
    let sortBy: (SearchProperty, Bool)?
    let distinctBy: SearchProperty?
    
    init(stackCount: Int) {
        self.stackCount = stackCount
        self.limit = nil
        self.offset = nil
        self.sortBy = nil
        self.distinctBy = nil
    }
    
    init(limit: Int) {
        self.stackCount = nil
        self.limit = limit
        self.offset = nil
        self.sortBy = nil
        self.distinctBy = nil
    }
    
    init(offset: Int) {
        self.stackCount = nil
        self.limit = nil
        self.offset = offset
        self.sortBy = nil
        self.distinctBy = nil
    }
    
    init(sortBy: SearchProperty, ascending: Bool) {
        self.stackCount = nil
        self.limit = nil
        self.offset = nil
        self.sortBy = (sortBy, ascending)
        self.distinctBy = nil
    }
    
    init(distinctBy: SearchProperty) {
        self.stackCount = nil
        self.limit = nil
        self.offset = nil
        self.sortBy = nil
        self.distinctBy = distinctBy
    }
}

enum VMError: Error, CustomStringConvertible {
    case stackUnderflow(String)
    case groupMismatch(String)
    case invalidOpcode(String)
    
    var description: String {
        switch self {
        case .stackUnderflow(let msg): return "Stack underflow: \(msg)"
        case .groupMismatch(let msg): return "Group mismatch: \(msg)"
        case .invalidOpcode(let msg): return "Invalid opcode: \(msg)"
        }
    }
}

extension CandidateSet {
    static func all(_ snapshot: IndexSnapshot) -> CandidateSet {
        CandidateSet(elements: snapshot.nodes)
    }
    
    func sorted(by areInIncreasingOrder: (FSNode, FSNode) -> Bool) -> CandidateSet {
        CandidateSet(elements: elements.sorted(by: areInIncreasingOrder))
    }
}
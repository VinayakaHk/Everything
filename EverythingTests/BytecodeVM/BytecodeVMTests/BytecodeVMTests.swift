import Foundation
import Nimble
import Quick
import SwiftCheck
@testable import EverythingCore

// MARK: - Bytecode VM Tests

final class BytecodeVMTests: QuickSpec {
    override class func spec() {
        describe("BytecodeVM") {
            var vm: BytecodeVM!
            var testIndex: IndexSnapshot!
            
            beforeEach {
                vm = BytecodeVM()
                testIndex = createTestIndex()
            }
            
            context("Opcode Execution") {
                it("executes name prefix filter") {
                    let bytecode: [SearchOpcode] = [.namePrefix("test")]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    expect(results.count).to(beGreaterThan(0))
                    for node in results {
                        expect(node.name).to(beginWith("test"))
                    }
                }
                
                it("executes exact name match") {
                    let bytecode: [SearchOpcode] = [.namePrefix("exact_match")]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    expect(results.count).to(equal(1))
                    expect(results.first?.name).to(equal("exact_match"))
                }
                
                it("executes size range filter") {
                    let bytecode: [SearchOpcode] = [.sizeRange(1000...2000)]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for node in results {
                        expect(node.fileSize).to(beGreaterThanOrEqualTo(1000))
                        expect(node.fileSize).to(beLessThanOrEqualTo(2000))
                    }
                }
                
                it("executes time range filter") {
                    let now = UInt64(Date().timeIntervalSince1970)
                    let bytecode: [SearchOpcode] = [.modTimeRange(now-3600...now)]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for node in results {
                        expect(node.modTime).to(beGreaterThanOrEqualTo(now-3600))
                        expect(node.modTime).to(beLessThanOrEqualTo(now))
                    }
                }
                
                it("executes AND logic") {
                    let bytecode: [SearchOpcode] = [
                        .namePrefix("test"),
                        .sizeRange(500...1500),
                        .and
                    ]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for node in results {
                        expect(node.name).to(beginWith("test"))
                        expect(node.fileSize).to(beGreaterThanOrEqualTo(500))
                        expect(node.fileSize).to(beLessThanOrEqualTo(1500))
                    }
                }
                
                it("executes OR logic") {
                    let bytecode: [SearchOpcode] = [
                        .namePrefix("apple"),
                        .namePrefix("banana"),
                        .or
                    ]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for node in results {
                        expect(node.name).to(satisfyAnyOf(
                            beginWith("apple"),
                            beginWith("banana")
                        ))
                    }
                }
                
                it("executes NOT logic") {
                    let bytecode: [SearchOpcode] = [
                        .namePrefix("test"),
                        .sizeRange(0...100),
                        .not
                    ]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for node in results {
                        expect(node.fileSize).to(beGreaterThan(100))
                    }
                }
                
                it("executes grouping") {
                    let bytecode: [SearchOpcode] = [
                        .namePrefix("a"),
                        .namePrefix("b"),
                        .or,
                        .sizeRange(100...200),
                        .and
                    ]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for node in results {
                        expect(node.name).to(satisfyAnyOf(
                            beginWith("a"),
                            beginWith("b")
                        ))
                        expect(node.fileSize).to(beGreaterThanOrEqualTo(100))
                        expect(node.fileSize).to(beLessThanOrEqualTo(200))
                    }
                }
                
                it("applies limit and offset") {
                    let bytecode: [SearchOpcode] = [
                        .namePrefix("test"),
                        .limit(5),
                        .offset(2)
                    ]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    expect(results.count).to(beLessThanOrEqualTo(5))
                }
                
                it("applies sort") {
                    let bytecode: [SearchOpcode] = [
                        .namePrefix("test"),
                        .sortBy(.size, ascending: false)
                    ]
                    let results = vm.execute(bytecode, against: testIndex)
                    
                    for i in 1..<results.count {
                        expect(results[i-1].fileSize).to(beGreaterThanOrEqualTo(results[i].fileSize))
                    }
                }
            }
            
            context("CandidateSet Operations") {
                it("intersects two sets") {
                    let set1 = testIndex.nodesByName.prefixRange("test")
                    let set2 = testIndex.nodesBySize?.range(1000...2000) ?? CandidateSet.empty
                    let intersected = set1.intersect(set2)
                    
                    expect(intersected.count).to(beLessThanOrEqualTo(set1.count))
                    expect(intersected.count).to(beLessThanOrEqualTo(set2.count))
                }
                
                it("unions two sets") {
                    let set1 = testIndex.nodesByName.prefixRange("apple")
                    let set2 = testIndex.nodesByName.prefixRange("banana")
                    let union = set1.union(set2)
                    
                    expect(union.count).to(beGreaterThanOrEqualTo(max(set1.count, set2.count)))
                    expect(union.count).to(beLessThanOrEqualTo(set1.count + set2.count))
                }
                
                it("differences two sets") {
                    let set1 = testIndex.nodesByName.prefixRange("test")
                    let set2 = testIndex.nodesByName.prefixRange("test_small")
                    let diff = set1.difference(set2)
                    
                    expect(diff.count).to(beLessThanOrEqualTo(set1.count))
                }
            }
        }
    }
}

// MARK: - Property-Based Tests for BytecodeVM

final class BytecodeVMPropertyTests: QuickSpec {
    override class func spec() {
        describe("BytecodeVM Property Tests") {
            let vm = BytecodeVM()
            let testIndex = createTestIndex()
            
            it("name prefix filter is monotonic") {
                property("prefix filter monotonic") <- forAll { (prefix1: String, prefix2: String) in
                    let longer = prefix1.count >= prefix2.count ? prefix1 : prefix2
                    let shorter = prefix1.count >= prefix2.count ? prefix2 : prefix1
                    
                    let longerResults = vm.execute([.namePrefix(longer)], against: testIndex)
                    let shorterResults = vm.execute([.namePrefix(shorter)], against: testIndex)
                    
                    return longerResults.count <= shorterResults.count
                }
            }
            
            it("size range filter is monotonic") {
                property("size range monotonic") <- forAll { (min1: UInt64, max1: UInt64, min2: UInt64, max2: UInt64) in
                    let min1b = min(min1, max1)
                    let max1b = max(min1, max1)
                    let min2b = min(min2, max2)
                    let max2b = max(min2, max2)
                    
                    // If range1 contains range2, range1 should have >= results
                    let contains = min1b <= min2b && max2b <= max1b
                    
                    let r1 = vm.execute([.sizeRange(min1b...max1b)], against: testIndex)
                    let r2 = vm.execute([.sizeRange(min2b...max2b)], against: testIndex)
                    
                    return !contains || r1.count >= r2.count
                }
            }
            
            it("AND is commutative") {
                property("AND commutative") <- forAll { (prefix: String, minSize: UInt64) in
                    let bytecode1: [SearchOpcode] = [.namePrefix(prefix), .sizeRange(0...10000), .and]
                    let bytecode2: [SearchOpcode] = [.sizeRange(0...10000), .namePrefix(prefix), .and]
                    
                    let r1 = vm.execute(bytecode1, against: testIndex)
                    let r2 = vm.execute(bytecode2, against: testIndex)
                    
                    return r1.count == r2.count
                }
            }
            
            it("OR is commutative") {
                property("OR commutative") <- forAll { (prefix1: String, prefix2: String) in
                    let bytecode1: [SearchOpcode] = [.namePrefix(prefix1), .namePrefix(prefix2), .or]
                    let bytecode2: [SearchOpcode] = [.namePrefix(prefix2), .namePrefix(prefix1), .or]
                    
                    let r1 = vm.execute(bytecode1, against: testIndex)
                    let r2 = vm.execute(bytecode2, against: testIndex)
                    
                    return r1.count == r2.count
                }
            }
            
            it("NOT is idempotent") {
                property("NOT idempotent") <- forAll { (prefix: String) in
                    let bytecode1: [SearchOpcode] = [.namePrefix(prefix), .not, .not]
                    let bytecode2: [SearchOpcode] = [.namePrefix(prefix)]
                    
                    let r1 = vm.execute(bytecode1, against: testIndex)
                    let r2 = vm.execute(bytecode2, against: testIndex)
                    
                    return r1.count == r2.count
                }
            }
        }
    }
}

// MARK: - Bytecode VM Performance Tests

final class BytecodeVMPerformanceTests: QuickSpec {
    override class func spec() {
        describe("BytecodeVM Performance") {
            let vm = BytecodeVM()
            let testIndex = createTestIndex()
            
            it("executes simple query fast") {
                let bytecode: [SearchOpcode] = [.namePrefix("test")]
                let iterations = 10000
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<iterations {
                    _ = vm.execute(bytecode, against: testIndex)
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let perQuery = elapsed / Double(iterations) * 1_000_000  // microseconds
                
                print("Query latency: \(perQuery) µs")
                expect(perQuery).to(beLessThan(50))  // < 50 µs
            }
            
            it("executes complex query fast") {
                let bytecode: [SearchOpcode] = [
                    .namePrefix("test"),
                    .sizeRange(1000...100000),
                    .modTimeRange(1704067200...1735689600),
                    .and,
                    .sortBy(.size, ascending: false),
                    .limit(100)
                ]
                let iterations = 1000
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<iterations {
                    _ = vm.execute(bytecode, against: testIndex)
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let perQuery = elapsed / Double(iterations) * 1_000_000
                
                print("Complex query latency: \(perQuery) µs")
                expect(perQuery).to(beLessThan(500))  // < 500 µs
            }
            
            it("handles large result sets") {
                let bytecode: [SearchOpcode] = [.namePrefix("")]
                let results = vm.execute(bytecode, against: testIndex)
                
                // Should return all nodes efficiently
                expect(results.count).to(equal(testIndex.totalNodes))
            }
        }
    }
}

// MARK: - Bytecode VM Edge Case Tests

final class BytecodeVMEdgeCaseTests: QuickSpec {
    override class func spec() {
        describe("BytecodeVM Edge Cases") {
            let vm = BytecodeVM()
            let testIndex = createTestIndex()
            
            it("handles empty query") {
                let results = vm.execute([], against: testIndex)
                expect(results.count).to(equal(testIndex.totalNodes))
            }
            
            it("handles non-existent prefix") {
                let bytecode: [SearchOpcode] = [.namePrefix("nonexistent_xyz_123")]
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).to(equal(0))
            }
            
            it("handles empty size range") {
                let bytecode: [SearchOpcode] = [.sizeRange(1000...500)]  // Invalid range
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).to(equal(0))
            }
            
            it("handles very large size range") {
                let bytecode: [SearchOpcode] = [.sizeRange(0...UInt64.max)]
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).to(equal(testIndex.totalNodes))
            }
            
            it("handles time range spanning full range") {
                let bytecode: [SearchOpcode] = [.modTimeRange(0...UInt64.max)]
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).to(equal(testIndex.totalNodes))
            }
            
            it("handles multiple NOTs") {
                let bytecode: [SearchOpcode] = [.namePrefix("test"), .not, .not, .not]
                let results = vm.execute(bytecode, against: testIndex)
                // Triple NOT = single NOT
                let singleNot = vm.execute([.namePrefix("test"), .not], against: testIndex)
                expect(results.count).to(equal(singleNot.count))
            }
            
            it("handles deeply nested groups") {
                let bytecode: [SearchOpcode] = [
                    .namePrefix("a"), .groupStart,
                        .namePrefix("b"), .groupStart,
                            .namePrefix("c"), .and,
                        .groupEnd, .or,
                    .groupEnd
                ]
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).toNot(beNil())
            }
            
            it("handles limit larger than results") {
                let bytecode: [SearchOpcode] = [.namePrefix("test"), .limit(1000000)]
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).to(beLessThanOrEqualTo(testIndex.nodesByName.prefixRange("test").count))
            }
            
            it("handles offset larger than results") {
                let bytecode: [SearchOpcode] = [.namePrefix("test"), .offset(1000000)]
                let results = vm.execute(bytecode, against: testIndex)
                expect(results.count).to(equal(0))
            }
            
            it("handles sort on non-indexed property") {
                let bytecode: [SearchOpcode] = [.namePrefix("test"), .sortBy(.modTime, ascending: true)]
                let results = vm.execute(bytecode, against: testIndex)
                
                for i in 1..<results.count {
                    expect(results[i-1].modTime).to(beLessThanOrEqualTo(results[i].modTime))
                }
            }
            
            it("handles regex filter") {
                let bytecode: [SearchOpcode] = [.matchRegex(try! NSRegularExpression(pattern: "test.*\\.txt"))]
                let results = vm.execute(bytecode, against: testIndex)
                
                for node in results {
                    expect(node.name).to(match("test.*\\.txt"))
                }
            }
        }
    }
}

// MARK: - Test Helpers

func createTestIndex() -> IndexSnapshot {
    var nodes: [FSNode] = []
    let now = UInt64(Date().timeIntervalSince1970)
    
    // Create test nodes
    for i in 0..<1000 {
        let name: String
        let size: UInt64
        
        switch i % 10 {
        case 0: name = "test_file_\(i).txt"; size = 1000 + UInt64(i * 100)
        case 1: name = "apple_\(i).txt"; size = 500 + UInt64(i * 50)
        case 2: name = "banana_\(i).md"; size = 2000 + UInt64(i * 200)
        case 3: name = "test_small_\(i).txt"; size = 50 + UInt64(i)
        case 4: name = "document_\(i).pdf"; size = 10000 + UInt64(i * 1000)
        case 5: name = "image_\(i).jpg"; size = 50000 + UInt64(i * 5000)
        case 6: name = "video_\(i).mp4"; size = 100_000_000 + UInt64(i * 1_000_000)
        case 7: name = "test_exact.txt"; size = 2048
        case 8: name = "config_\(i).json"; size = 200 + UInt64(i * 10)
        default: name = "other_\(i).dat"; size = 100 + UInt64(i)
        }
        
        let node = FSNode(
            inodeID: UInt64(i + 1000),
            parentID: 2,
            privateID: UInt64(i + 1000),
            name: name,
            createTime: UInt64(Date().timeIntervalSince1970) - 86400 * UInt64(i % 365),
            createTimeNsec: 0,
            modTime: UInt64(Date().timeIntervalSince1970) - 3600 * UInt64(i % 24),
            modTimeNsec: 0,
            changeTime: now,
            changeTimeNsec: 0,
            accessTime: now,
            accessTimeNsec: 0,
            fileSize: size,
            uncompressedSize: size,
            mode: 0o100644,
            flags: 0,
            bsdFlags: 0,
            owner: 501,
            group: 20,
            writeGen: UInt64(i),
            cloneGroupID: nil,
            hardLinkCount: 1,
            volumeID: 1,
            apfsVolumeUUID: UUID(),
            volfsVolumeID: nil,
            filerefVolumeID: nil,
            path: "/test/\(name)",
            depth: 1
        )
        nodes.append(node)
    }
    
    return IndexSnapshot(nodes: nodes)
}
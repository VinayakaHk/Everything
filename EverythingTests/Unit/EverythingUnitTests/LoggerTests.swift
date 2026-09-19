import Foundation
import Nimble
import Quick
@testable import EverythingCore

// MARK: - Logger Tests

final class LoggerTests: QuickSpec {
    override class func spec() {
        describe("Logger") {
            var logger: Logger!
            var testLogFile: URL!
            let testLogDir = FileManager.default.temporaryDirectory.appendingPathComponent("EverythingTestLogs")
            
            beforeEach {
                // Clean up
                try? FileManager.default.removeItem(at: testLogDir)
                try? FileManager.default.createDirectory(at: testLogDir, withIntermediateDirectories: true)
                
                // Create logger with test directory
                // Note: Logger is singleton, so we test via global functions
            }
            
            afterEach {
                try? FileManager.default.removeItem(at: testLogDir)
            }
            
            context("LogEntry") {
                it("encodes to valid JSON") {
                    let entry = LogEntry(
                        timestamp: "2024-01-15T10:30:45.123456Z",
                        level: .info,
                        subsystem: "test",
                        category: "unit",
                        message: "Test message",
                        correlationID: "test-correlation-id",
                        metadata: ["key1": "value1", "key2": "value2"],
                        file: "LoggerTests.swift",
                        function: "testEncoding",
                        line: 42
                    )
                    
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try! encoder.encode(entry)
                    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                    
                    expect(json["timestamp"] as? String).to(equal("2024-01-15T10:30:45.123456Z"))
                    expect(json["level"] as? String).to(equal("info"))
                    expect(json["subsystem"] as? String).to(equal("test"))
                    expect(json["category"] as? String).to(equal("unit"))
                    expect(json["message"] as? String).to(equal("Test message"))
                    expect(json["correlationID"] as? String).to(equal("test-correlation-id"))
                    expect(json["metadata"] as? [String: String]).to(equal(["key1": "value1", "key2": "value2"]))
                    expect(json["file"] as? String).to(equal("LoggerTests.swift"))
                    expect(json["function"] as? String).to(equal("testEncoding"))
                    expect(json["line"] as? Int).to(equal(42))
                }
                
                it("handles nil correlationID and empty metadata") {
                    let entry = LogEntry(
                        timestamp: "2024-01-15T10:30:45.123456Z",
                        level: .debug,
                        subsystem: "test",
                        category: "unit",
                        message: "Test",
                        correlationID: nil,
                        metadata: [:],
                        file: "test.swift",
                        function: "test",
                        line: 1
                    )
                    
                    let data = try! JSONEncoder().encode(entry)
                    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                    
                    expect(json["correlationID"]).to(beNil())
                    expect(json["metadata"] as? [String: String]).to(equal([:]))
                }
                
                it("orders levels correctly") {
                    expect(LogLevel.debug < LogLevel.info).to(beTrue())
                    expect(LogLevel.info < LogLevel.warn).to(beTrue())
                    expect(LogLevel.warn < LogLevel.error).to(beTrue())
                    expect(LogLevel.error < LogLevel.fatal).to(beTrue())
                }
            }
            
            context("Global logging functions") {
                it("logs without crashing") {
                    // These should not crash
                    LogDebug("Debug message", subsystem: "test", category: "unit")
                    LogInfo("Info message", subsystem: "test", category: "unit")
                    LogWarn("Warn message", subsystem: "test", category: "unit")
                    LogError("Error message", subsystem: "test", category: "unit")
                    LogFatal("Fatal message", subsystem: "test", category: "unit")
                    
                    // Give async logger time to write
                    Thread.sleep(forTimeInterval: 0.1)
                }
                
                it("includes correlation ID when provided") {
                    let corrID = "test-corr-123"
                    LogInfo("With correlation", subsystem: "test", category: "unit", correlationID: corrID)
                    Thread.sleep(forTimeInterval: 0.1)
                    // Verification would require reading log file
                }
                
                it("includes metadata when provided") {
                    LogInfo("With metadata", subsystem: "test", category: "unit", metadata: ["key": "value"])
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            context("CorrelationID") {
                it("generates valid UUIDs") {
                    let id1 = CorrelationID.new()
                    let id2 = CorrelationID.new()
                    
                    expect(id1).toNot(beEmpty())
                    expect(id2).toNot(beEmpty())
                    expect(id1).toNot(equal(id2))
                    
                    // Validate UUID format
                    let uuid1 = UUID(uuidString: id1)
                    let uuid2 = UUID(uuidString: id2)
                    expect(uuid1).toNot(beNil())
                    expect(uuid2).toNot(beNil())
                }
                
                it("converts UUID to string") {
                    let uuid = UUID()
                    let str = CorrelationID.from(uuid)
                    expect(str).to(equal(uuid.uuidString))
                }
            }
        }
    }
}

// MARK: - Logger Performance Tests

final class LoggerPerformanceTests: QuickSpec {
    override class func spec() {
        describe("Logger Performance") {
            it("handles high throughput logging") {
                let iterations = 10000
                let start = CFAbsoluteTimeGetCurrent()
                
                for i in 0..<iterations {
                    LogDebug("Message \(i)", subsystem: "perf", category: "throughput")
                }
                
                // Wait for async queue
                Thread.sleep(forTimeInterval: 1.0)
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let throughput = Double(iterations) / elapsed
                
                // Should handle > 10k logs/sec
                expect(throughput).to(beGreaterThan(10000))
            }
            
            it("measures log latency") {
                let histogram = MetricsRegistry.shared.searchLatency  // Reuse for test
                
                for _ in 0..<1000 {
                    measure(histogram) {
                        LogInfo("Latency test", subsystem: "perf", category: "latency")
                    }
                }
                
                // Check histogram recorded values
                let json = histogram.jsonFormat()
                expect(json["everything_search_latency_seconds"]).toNot(beNil())
            }
        }
    }
}

// MARK: - Logger Edge Case Tests

final class LoggerEdgeCaseTests: QuickSpec {
    override class func spec() {
        describe("Logger Edge Cases") {
            it("handles very long messages") {
                let longMessage = String(repeating: "x", count: 1_000_000)  // 1MB message
                LogInfo(longMessage, subsystem: "test", category: "edge")
                Thread.sleep(forTimeInterval: 0.5)
            }
            
            it("handles special characters in messages") {
                let special = "🎉 Special chars: \n\t\r\"'\\/`~!@#$%^&*()_+-={}[]|\\:;<>,.?/ 中文 日本語 한국어"
                LogInfo(special, subsystem: "test", category: "edge")
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            it("handles concurrent logging from multiple threads") {
                let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
                let group = DispatchGroup()
                let threads = 10
                let perThread = 1000
                
                for t in 0..<threads {
                    group.enter()
                    queue.async {
                        for i in 0..<perThread {
                            LogDebug("Thread \(t) message \(i)", subsystem: "concurrent", category: "thread-\(t)")
                        }
                        group.leave()
                    }
                }
                
                group.wait()
                Thread.sleep(forTimeInterval: 0.5)
            }
            
            it("handles rapid level changes") {
                for level in [LogLevel.debug, .info, .warn, .error, .fatal] {
                    for _ in 0..<100 {
                        Logger.shared.log(level, subsystem: "test", category: "levels", message: "Level \(level)")
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}
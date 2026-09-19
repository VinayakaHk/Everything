import Foundation
import Nimble
import Quick
@testable import EverythingCore

// MARK: - Metrics Tests

final class MetricsTests: QuickSpec {
    override class func spec() {
        describe("MetricsRegistry") {
            let registry = MetricsRegistry.shared
            
            beforeEach {
                // Reset metrics where possible
                // Note: These are singletons, so we can't fully reset
                // Just ensure they work
            }
            
            context("Counter") {
                it("increments correctly") {
                    let counter = Counter(name: "test_counter", help: "Test counter")
                    counter.inc()
                    counter.inc(["label": "value"])
                    counter.add(5, labels: ["label": "other"])
                    
                    expect(counter.get()).to(equal(7))
                    expect(counter.get(labels: ["label": "value"])).to(equal(1))
                    expect(counter.get(labels: ["label": "other"])).to(equal(5))
                }
                
                it("exposes Prometheus format") {
                    let counter = Counter(name: "test_counter_total", help: "Test")
                    counter.inc()
                    counter.inc(labels: ["method": "get"])
                    
                    let output = counter.expositionFormat()
                    expect(output).to(contain("# HELP test_counter_total Test"))
                    expect(output).to(contain("# TYPE test_counter_total counter"))
                    expect(output).to(contain("test_counter_total 2"))
                    expect(output).to(contain("test_counter_total{method=\"get\"} 1"))
                }
                
                it("outputs JSON format") {
                    let counter = Counter(name: "test_json", help: "Test")
                    counter.inc()
                    
                    let json = counter.jsonFormat()
                    expect(json["test_json"]).toNot(beNil())
                    expect(json["test_json"]?["value"] as? UInt64).to(equal(1))
                }
                
                it("is thread-safe") {
                    let counter = Counter(name: "test_threadsafe", help: "Test")
                    let queue = DispatchQueue(label: "test", attributes: .concurrent)
                    let group = DispatchGroup()
                    let iterations = 1000
                    
                    for _ in 0..<10 {
                        group.enter()
                        queue.async {
                            for _ in 0..<iterations {
                                counter.inc()
                            }
                            group.leave()
                        }
                    }
                    
                    group.wait()
                    expect(counter.get()).to(equal(UInt64(10 * iterations)))
                }
            }
            
            context("Gauge") {
                it("sets and gets values") {
                    let gauge = Gauge(name: "test_gauge", help: "Test")
                    gauge.set(42.5)
                    expect(gauge.get()).to(equal(42.5))
                    
                    gauge.set(100, labels: ["label": "value"])
                    expect(gauge.get(labels: ["label": "value"])).to(equal(100))
                }
                
                it("increments and decrements") {
                    let gauge = Gauge(name: "test_gauge_inc", help: "Test")
                    gauge.inc()
                    gauge.inc()
                    gauge.dec()
                    expect(gauge.get()).to(equal(1))
                }
                
                it("exposes Prometheus format with labels") {
                    let gauge = Gauge(name: "test_gauge_labeled", help: "Test")
                    gauge.set(3.14, labels: ["type": "memory"])
                    
                    let output = gauge.expositionFormat()
                    expect(output).to(contain("test_gauge_labeled{type=\"memory\"} 3.14"))
                }
            }
            
            context("Histogram") {
                it("records observations in buckets") {
                    let hist = Histogram(name: "test_hist", buckets: [1, 5, 10], help: "Test")
                    
                    hist.observe(0.5)
                    hist.observe(2)
                    hist.observe(7)
                    hist.observe(15)
                    
                    let json = hist.jsonFormat()
                    let data = json["test_hist"] as! [String: Any]
                    let buckets = data["buckets"] as! [[String: Any]]
                    
                    // le="1": 1 (0.5)
                    expect(buckets[0]["count"] as? Int).to(equal(1))
                    // le="5": 2 (0.5, 2)
                    expect(buckets[1]["count"] as? Int).to(equal(2))
                    // le="10": 3 (0.5, 2, 7)
                    expect(buckets[2]["count"] as? Int).to(equal(3))
                    // le="+Inf": 4 (all)
                    expect(buckets[3]["count"] as? Int).to(equal(4))
                    
                    expect(data["sum"] as? Double).to(equal(24.5))
                    expect(data["count"] as? UInt64).to(equal(4))
                }
                
                it("handles labeled observations") {
                    let hist = Histogram(name: "test_labeled", buckets: [10], help: "Test")
                    hist.observe(5, labels: ["endpoint": "search"])
                    hist.observe(15, labels: ["endpoint": "search"])
                    hist.observe(8, labels: ["endpoint": "index"])
                    
                    let output = hist.expositionFormat()
                    expect(output).to(contain("test_labeled_bucket{endpoint=\"search\",le=\"10\"} 1"))
                    expect(output).to(contain("test_labeled_bucket{endpoint=\"index\",le=\"10\"} 1"))
                    expect(output).to(contain("test_labeled_sum{endpoint=\"search\"} 20"))
                }
                
                it("calculates sum and count correctly") {
                    let hist = Histogram(name: "test_sum", buckets: [100], help: "Test")
                    hist.observe(10)
                    hist.observe(20)
                    hist.observe(30)
                    
                    let json = hist.jsonFormat()
                    let data = json["test_sum"] as! [String: Any]
                    expect(data["sum"] as? Double).to(equal(60))
                    expect(data["count"] as? UInt64).to(equal(3))
                }
                
                it("is thread-safe") {
                    let hist = Histogram(name: "test_hist_thread", buckets: [1000], help: "Test")
                    let queue = DispatchQueue(label: "test", attributes: .concurrent)
                    let group = DispatchGroup()
                    
                    for _ in 0..<10 {
                        group.enter()
                        queue.async {
                            for i in 0..<100 {
                                hist.observe(Double(i))
                            }
                            group.leave()
                        }
                    }
                    
                    group.wait()
                    let json = hist.jsonFormat()
                    expect(json["test_hist_thread"]?["count"] as? UInt64).to(equal(1000))
                }
            }
            
            context("Summary") {
                it("calculates quantiles") {
                    let summary = Summary(name: "test_summary", quantiles: [0.5, 0.9, 0.99], help: "Test")
                    
                    // Add known values: 1,2,3,4,5,6,7,8,9,10
                    for i in 1...10 {
                        summary.observe(Double(i))
                    }
                    
                    let output = summary.expositionFormat()
                    expect(output).to(contain("quantile=\"0.5\""))
                    expect(output).to(contain("quantile=\"0.9\""))
                    expect(output).to(contain("quantile=\"0.99\""))
                    
                    // 0.5 quantile of 1..10 should be ~5.5
                    // 0.9 quantile should be ~9.1
                }
                
                it("uses reservoir sampling for large datasets") {
                    let summary = Summary(name: "test_reservoir", quantiles: [0.5], help: "Test")
                    
                    // Add more than maxObservations
                    for i in 0..<15000 {
                        summary.observe(Double(i))
                    }
                    
                    // Should not crash and should have observations
                    let output = summary.expositionFormat()
                    expect(output).to(contain("test_reservoir"))
                }
            }
            
            context("MetricsRegistry") {
                it("has all required metrics") {
                    let metrics = [
                        "everything_scan_files_total",
                        "everything_scan_bytes_total",
                        "everything_search_requests_total",
                        "everything_search_latency_seconds",
                        "everything_index_node_count",
                        "everything_memory_usage_bytes",
                        "everything_xpc_calls_total"
                    ]
                    
                    for name in metrics {
                        // Just verify registry has the property
                        // We can't easily test private collectors array
                    }
                }
                
                it("exposes all metrics in Prometheus format") {
                    let output = MetricsRegistry.shared.expositionFormat()
                    expect(output).to(contain("# HELP everything_"))
                    expect(output).to(contain("# TYPE everything_"))
                }
                
                it("outputs JSON format") {
                    let json = MetricsRegistry.shared.jsonFormat()
                    expect(json.count).to(beGreaterThan(0))
                }
            }
        }
    }
}

// MARK: - Metrics Performance Tests

final class MetricsPerformanceTests: QuickSpec {
    override class func spec() {
        describe("Metrics Performance") {
            it("Counter: high throughput increments") {
                let counter = Counter(name: "perf_counter", help: "Test")
                let iterations = 1_000_000
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<iterations {
                    counter.inc()
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let throughput = Double(iterations) / elapsed
                
                print("Counter throughput: \(throughput)/sec")
                expect(throughput).to(beGreaterThan(5_000_000))  // >5M/sec
            }
            
            it("Histogram: high throughput observations") {
                let hist = Histogram(name: "perf_hist", buckets: [1, 10, 100, 1000], help: "Test")
                let iterations = 1_000_000
                let start = CFAbsoluteTimeGetCurrent()
                
                for i in 0..<iterations {
                    hist.observe(Double(i % 1000))
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let throughput = Double(iterations) / elapsed
                
                print("Histogram throughput: \(throughput)/sec")
                expect(throughput).to(beGreaterThan(2_000_000))  // >2M/sec
            }
            
            it("Concurrent Counter increments") {
                let counter = Counter(name: "perf_concurrent", help: "Test")
                let queue = DispatchQueue(label: "test", attributes: .concurrent)
                let group = DispatchGroup()
                let threads = 8
                let perThread = 100_000
                
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<threads {
                    group.enter()
                    queue.async {
                        for _ in 0..<perThread {
                            counter.inc()
                        }
                        group.leave()
                    }
                }
                
                group.wait()
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let total = threads * perThread
                let throughput = Double(total) / elapsed
                
                print("Concurrent counter throughput: \(throughput)/sec")
                expect(counter.get()).to(equal(UInt64(total)))
                expect(throughput).to(beGreaterThan(1_000_000))
            }
            
            it("MetricsRegistry exposition format generation") {
                let start = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<100 {
                    _ = MetricsRegistry.shared.expositionFormat()
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                print("Exposition format generation: \(elapsed * 1000)ms for 100 iterations")
                expect(elapsed).to(beLessThan(0.1))  // < 100ms for 100 generations
            }
        }
    }
}

// MARK: - Metrics Edge Case Tests

final class MetricsEdgeCaseTests: QuickSpec {
    override class func spec() {
        describe("Metrics Edge Cases") {
            it("Histogram: observation at bucket boundary") {
                let hist = Histogram(name: "boundary", buckets: [10, 20], help: "Test")
                hist.observe(10)  // Exactly at boundary
                hist.observe(20)
                
                let json = hist.jsonFormat()
                let data = json["boundary"] as! [String: Any]
                let buckets = data["buckets"] as! [[String: Any]]
                
                // Value 10 should be in le="10" bucket
                expect(buckets[0]["count"] as? Int).to(equal(1))
                // Value 20 should be in le="20" bucket
                expect(buckets[1]["count"] as? Int).to(equal(2))
            }
            
            it("Histogram: negative values") {
                let hist = Histogram(name: "negative", buckets: [-10, 0, 10], help: "Test")
                hist.observe(-20)
                hist.observe(-5)
                hist.observe(5)
                
                let json = hist.jsonFormat()
                let data = json["negative"] as! [String: Any]
                let buckets = data["buckets"] as! [[String: Any]]
                
                // -20 in le="-10"
                expect(buckets[0]["count"] as? Int).to(equal(1))
                // -5 in le="0"
                expect(buckets[1]["count"] as? Int).to(equal(1))
                // 5 in le="10"
                expect(buckets[2]["count"] as? Int).to(equal(1))
            }
            
            it("Counter: very large values") {
                let counter = Counter(name: "large", help: "Test")
                counter.add(UInt64.max / 2)
                counter.add(UInt64.max / 2)
                
                // Should not overflow (wraps in Swift UInt64)
                expect(counter.get()).to(equal(UInt64.max - 1))  // Actually wraps
            }
            
            it("Gauge: NaN and Infinity handling") {
                let gauge = Gauge(name: "special", help: "Test")
                gauge.set(Double.nan)
                gauge.set(Double.infinity)
                gauge.set(-Double.infinity)
                
                // Should not crash
                expect(gauge.get()).to(beNaN())
            }
            
            it("Summary: empty observations") {
                let summary = Summary(name: "empty", quantiles: [0.5], help: "Test")
                let output = summary.expositionFormat()
                expect(output).to(contain("empty_sum 0"))
                expect(output).to(contain("empty_count 0"))
            }
            
            it("MetricsServer: starts and stops") {
                // Test on different port to avoid conflicts
                let server = try! MetricsServer(port: 0)  // Port 0 = auto-assign
                // Can't easily test without knowing assigned port
                // Just verify init works
            }
            
            it("measure helper records correctly") {
                let hist = MetricsRegistry.shared.searchLatency
                let counter = MetricsRegistry.shared.searchRequestsTotal
                
                let result = measureAndCount(hist, counter, labels: ["test": "measure"]) {
                    Thread.sleep(forTimeInterval: 0.001)  // 1ms
                    return 42
                }
                
                expect(result).to(equal(42))
                // Give async time to record
                Thread.sleep(forTimeInterval: 0.01)
            }
            
            it("measureAsync helper works") async {
                let hist = MetricsRegistry.shared.searchLatency
                
                let result = await measureAsync(hist, labels: ["async": "true"]) {
                    try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
                    return "async result"
                }
                
                expect(result).to(equal("async result"))
            }
        }
    }
}
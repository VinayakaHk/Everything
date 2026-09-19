import Foundation

// MARK: - Metrics Registry (Prometheus-style)

public final class MetricsRegistry {
    public static let shared = MetricsRegistry()
    
    // Counters
    public let scanFilesTotal = Counter(name: "everything_scan_files_total", help: "Total files scanned")
    public let scanBytesTotal = Counter(name: "everything_scan_bytes_total", help: "Total bytes scanned")
    public let scanErrorsTotal = Counter(name: "everything_scan_errors_total", help: "Scan errors by type")
    public let searchRequestsTotal = Counter(name: "everything_search_requests_total", help: "Total search requests")
    public let searchErrorsTotal = Counter(name: "everything_search_errors_total", help: "Search errors by type")
    public let indexUpdatesTotal = Counter(name: "everything_index_updates_total", help: "Index updates applied")
    public let indexInsertsTotal = Counter(name: "everything_index_inserts_total", help: "Index inserts")
    public let indexRemovesTotal = Counter(name: "everything_index_removes_total", help: "Index removes")
    public let indexMovesTotal = Counter(name: "everything_index_moves_total", help: "Index moves")
    public let esEventsTotal = Counter(name: "everything_es_events_total", help: "EndpointSecurity events received")
    public let fsEventsTotal = Counter(name: "everything_fsevents_total", help: "FSEvents received")
    public let xpcCallsTotal = Counter(name: "everything_xpc_calls_total", help: "XPC calls made")
    public let xpcErrorsTotal = Counter(name: "everything_xpc_errors_total", help: "XPC errors by type")
    public let dbWritesTotal = Counter(name: "everything_db_writes_total", help: "Database writes")
    public let dbReadsTotal = Counter(name: "everything_db_reads_total", help: "Database reads")
    public let helperInstallsTotal = Counter(name: "everything_helper_installs_total", help: "Helper installations")
    public let helperUninstallsTotal = Counter(name: "everything_helper_uninstalls_total", help: "Helper uninstalls")
    
    // Gauges
    public let memoryUsageBytes = Gauge(name: "everything_memory_usage_bytes", help: "Process memory usage")
    public let indexNodeCount = Gauge(name: "everything_index_node_count", help: "Nodes in index")
    public let indexMemoryBytes = Gauge(name: "everything_index_memory_bytes", help: "Index memory usage")
    public let dbSizeBytes = Gauge(name: "everything_db_size_bytes", help: "Database file size")
    public let volumesIndexed = Gauge(name: "everything_volumes_indexed", help: "Volumes currently indexed")
    public let volumesDegraded = Gauge(name: "everything_volumes_degraded", help: "Volumes with errors")
    public let activeSearches = Gauge(name: "everything_active_searches", help: "Concurrent searches")
    public let activeScans = Gauge(name: "everything_active_scans", help: "Concurrent scans")
    public let xpcConnected = Gauge(name: "everything_xpc_connected", help: "XPC connection status (1=connected)")
    public let helperRunning = Gauge(name: "everything_helper_running", help: "Helper process running (1=yes)")
    public let esSubscriptions = Gauge(name: "everything_es_subscriptions", help: "Active ES subscriptions")
    
    // Histograms (latency in seconds)
    public let scanDuration = Histogram(name: "everything_scan_duration_seconds",
                                         buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60, 120, 300],
                                         help: "Full scan duration")
    public let scanFilesPerSecond = Histogram(name: "everything_scan_files_per_second",
                                               buckets: [1000, 5000, 10000, 25000, 50000, 100000, 250000, 500000],
                                               help: "Scan throughput")
    public let searchLatency = Histogram(name: "everything_search_latency_seconds",
                                          buckets: [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
                                          help: "Search latency")
    public let searchResultsCount = Histogram(name: "everything_search_results_count",
                                               buckets: [1, 10, 50, 100, 500, 1000, 5000, 10000, 50000],
                                               help: "Results returned per search")
    public let indexUpdateLatency = Histogram(name: "everything_index_update_latency_seconds",
                                               buckets: [0.00005, 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1],
                                               help: "Index update latency")
    public let xpcCallLatency = Histogram(name: "everything_xpc_call_latency_seconds",
                                           buckets: [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
                                           help: "XPC call latency")
    public let dbWriteLatency = Histogram(name: "everything_db_write_latency_seconds",
                                           buckets: [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
                                           help: "Database write latency")
    public let dbReadLatency = Histogram(name: "everything_db_read_latency_seconds",
                                          buckets: [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1],
                                          help: "Database read latency")
    public let helperStartLatency = Histogram(name: "everything_helper_start_latency_seconds",
                                               buckets: [0.1, 0.25, 0.5, 1, 2, 5, 10],
                                               help: "Helper startup time")
    
    // Summary (quantiles)
    public let scanDurationSummary = Summary(name: "everything_scan_duration_summary",
                                              quantiles: [0.5, 0.9, 0.95, 0.99, 0.999],
                                              help: "Scan duration quantiles")
    public let searchLatencySummary = Summary(name: "everything_search_latency_summary",
                                               quantiles: [0.5, 0.9, 0.95, 0.99, 0.999],
                                               help: "Search latency quantiles")
    
    private var collectors: [MetricCollector] = []
    private let lock = NSLock()
    
    private init() {
        registerAll()
        startPeriodicCollection()
    }
    
    private func registerAll() {
        let all: [MetricCollector] = [
            scanFilesTotal, scanBytesTotal, scanErrorsTotal,
            searchRequestsTotal, searchErrorsTotal,
            indexUpdatesTotal, indexInsertsTotal, indexRemovesTotal, indexMovesTotal,
            esEventsTotal, fsEventsTotal,
            xpcCallsTotal, xpcErrorsTotal,
            dbWritesTotal, dbReadsTotal,
            helperInstallsTotal, helperUninstallsTotal,
            memoryUsageBytes, indexNodeCount, indexMemoryBytes, dbSizeBytes,
            volumesIndexed, volumesDegraded, activeSearches, activeScans,
            xpcConnected, helperRunning, esSubscriptions,
            scanDuration, scanFilesPerSecond,
            searchLatency, searchResultsCount,
            indexUpdateLatency, xpcCallLatency, dbWriteLatency, dbReadLatency, helperStartLatency,
            scanDurationSummary, searchLatencySummary
        ]
        collectors = all
    }
    
    private func startPeriodicCollection() {
        // Update system metrics every 10 seconds
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.collectSystemMetrics()
        }
    }
    
    private func collectSystemMetrics() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            memoryUsageBytes.set(Double(info.resident_size))
        }
    }
    
    // Prometheus exposition format
    public func expositionFormat() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        var output = ""
        for collector in collectors {
            output += collector.expositionFormat()
        }
        return output
    }
    
    // JSON format for debugging
    public func jsonFormat() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        
        var dict: [String: Any] = [:]
        for collector in collectors {
            dict.merge(collector.jsonFormat()) { _, new in new }
        }
        return dict
    }
}

// MARK: - Metric Protocols

public protocol MetricCollector {
    var name: String { get }
    var help: String { get }
    var type: String { get }  // counter, gauge, histogram, summary
    func expositionFormat() -> String
    func jsonFormat() -> [String: Any]
}

// MARK: - Counter

public final class Counter: MetricCollector {
    public let name: String
    public let help: String
    public let type = "counter"
    private var value: UInt64 = 0
    private var labels: [String: UInt64] = [:]
    private let lock = NSLock()
    
    public init(name: String, help: String) {
        self.name = name
        self.help = help
    }
    
    public func inc(_ labels: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        let key = labelsKey(labels)
        labels[key, default: 0] += 1
    }
    
    public func add(_ n: UInt64, labels: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        value += n
        let key = labelsKey(labels)
        labels[key, default: 0] += n
    }
    
    public func get(labels: [String: String] = [:]) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if labels.isEmpty { return value }
        return labels[labelsKey(labels)] ?? 0
    }
    
    public func expositionFormat() -> String {
        lock.lock()
        defer { lock.unlock() }
        var out = "# HELP \(name) \(help)\n# TYPE \(name) counter\n"
        out += "\(name) \(value)\n"
        for (key, val) in labels {
            let labelStr = labelsFromKey(key)
            out += "\(name){\(labelStr)} \(val)\n"
        }
        return out
    }
    
    public func jsonFormat() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var dict: [String: Any] = ["value": value]
        var labeled: [String: UInt64] = [:]
        for (key, val) in labels {
            labeled[labelsFromKey(key)] = val
        }
        dict["labels"] = labeled
        return [name: dict]
    }
    
    private func labelsKey(_ labels: [String: String]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ",")
    }
    
    private func labelsFromKey(_ key: String) -> String {
        key
    }
}

// MARK: - Gauge

public final class Gauge: MetricCollector {
    public let name: String
    public let help: String
    public let type = "gauge"
    private var value: Double = 0
    private var labels: [String: Double] = [:]
    private let lock = NSLock()
    
    public init(name: String, help: String) {
        self.name = name
        self.help = help
    }
    
    public func set(_ val: Double, labels: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        if labels.isEmpty {
            value = val
        } else {
            labels[labelsKey(labels)] = val
        }
    }
    
    public func inc(_ labels: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        if labels.isEmpty {
            value += 1
        } else {
            let key = labelsKey(labels)
            labels[key, default: 0] += 1
        }
    }
    
    public func dec(_ labels: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        if labels.isEmpty {
            value -= 1
        } else {
            let key = labelsKey(labels)
            labels[key, default: 0] -= 1
        }
    }
    
    public func get(labels: [String: String] = [:]) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if labels.isEmpty { return value }
        return labels[labelsKey(labels)] ?? 0
    }
    
    public func expositionFormat() -> String {
        lock.lock()
        defer { lock.unlock() }
        var out = "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
        out += "\(name) \(value)\n"
        for (key, val) in labels {
            out += "\(name){\(key)} \(val)\n"
        }
        return out
    }
    
    public func jsonFormat() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var dict: [String: Any] = ["value": value]
        dict["labels"] = labels
        return [name: dict]
    }
    
    private func labelsKey(_ labels: [String: String]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ",")
    }
}

// MARK: - Histogram

public final class Histogram: MetricCollector {
    public let name: String
    public let help: String
    public let type = "histogram"
    public let buckets: [Double]
    private var counts: [Int]
    private var sum: Double = 0
    private var count: UInt64 = 0
    private var labelBuckets: [String: [Int]] = [:]
    private var labelSums: [String: Double] = [:]
    private var labelCounts: [String: UInt64] = [:]
    private let lock = NSLock()
    
    public init(name: String, buckets: [Double], help: String) {
        self.name = name
        self.buckets = buckets.sorted()
        self.counts = Array(repeating: 0, count: buckets.count + 1)  // +1 for +Inf
        self.help = help
    }
    
    public func observe(_ value: Double, labels: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        
        sum += value
        count += 1
        
        // Global buckets
        for (i, bucket) in buckets.enumerated() {
            if value <= bucket {
                counts[i] += 1
            }
        }
        counts[buckets.count] += 1  // +Inf
        
        // Labeled buckets
        if !labels.isEmpty {
            let key = labelsKey(labels)
            var b = labelBuckets[key] ?? Array(repeating: 0, count: buckets.count + 1)
            for (i, bucket) in buckets.enumerated() {
                if value <= bucket { b[i] += 1 }
            }
            b[buckets.count] += 1
            labelBuckets[key] = b
            labelSums[key, default: 0] += value
            labelCounts[key, default: 0] += 1
        }
    }
    
    public func expositionFormat() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        var out = "# HELP \(name) \(help)\n# TYPE \(name) histogram\n"
        
        // Global
        for (i, bucket) in buckets.enumerated() {
            out += "\(name)_bucket{le=\"\(bucket)\"} \(counts[i])\n"
        }
        out += "\(name)_bucket{le=\"+Inf\"} \(counts[buckets.count])\n"
        out += "\(name)_sum \(sum)\n"
        out += "\(name)_count \(count)\n"
        
        // Labeled
        for (key, b) in labelBuckets {
            for (i, bucket) in buckets.enumerated() {
                out += "\(name)_bucket{\(key),le=\"\(bucket)\"} \(b[i])\n"
            }
            out += "\(name)_bucket{\(key),le=\"+Inf\"} \(b[buckets.count])\n"
            out += "\(name)_sum{\(key)} \(labelSums[key] ?? 0)\n"
            out += "\(name)_count{\(key)} \(labelCounts[key] ?? 0)\n"
        }
        return out
    }
    
    public func jsonFormat() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        
        var bucketsDict: [[String: Any]] = []
        for (i, bucket) in buckets.enumerated() {
            bucketsDict.append(["le": bucket, "count": counts[i]])
        }
        bucketsDict.append(["le": "+Inf", "count": counts[buckets.count]])
        
        var dict: [String: Any] = [
            "buckets": bucketsDict,
            "sum": sum,
            "count": count
        ]
        
        if !labelBuckets.isEmpty {
            var labeled: [String: Any] = [:]
            for (key, b) in labelBuckets {
                var lb: [[String: Any]] = []
                for (i, bucket) in buckets.enumerated() {
                    lb.append(["le": bucket, "count": b[i]])
                }
                lb.append(["le": "+Inf", "count": b[buckets.count]])
                labeled[key] = ["buckets": lb, "sum": labelSums[key] ?? 0, "count": labelCounts[key] ?? 0]
            }
            dict["labels"] = labeled
        }
        return [name: dict]
    }
    
    private func labelsKey(_ labels: [String: String]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ",")
    }
}

// MARK: - Summary (Quantiles)

public final class Summary: MetricCollector {
    public let name: String
    public let help: String
    public let type = "summary"
    public let quantiles: [Double]
    private var observations: [Double] = []
    private var sum: Double = 0
    private var count: UInt64 = 0
    private let maxObservations = 10000
    private let lock = NSLock()
    
    public init(name: String, quantiles: [Double], help: String) {
        self.name = name
        self.quantiles = quantiles.sorted()
        self.help = help
    }
    
    public func observe(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        observations.append(value)
        sum += value
        count += 1
        
        // Reservoir sampling to keep maxObservations
        if observations.count > maxObservations {
            let idx = Int.random(in: 0..<maxObservations)
            observations[idx] = value
        }
    }
    
    private func quantile(_ q: Double) -> Double {
        guard !observations.isEmpty else { return 0 }
        let sorted = observations.sorted()
        let idx = min(Int(Double(sorted.count - 1) * q), sorted.count - 1)
        return sorted[idx]
    }
    
    public func expositionFormat() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        var out = "# HELP \(name) \(help)\n# TYPE \(name) summary\n"
        for q in quantiles {
            out += "\(name){quantile=\"\(q)\"} \(quantile(q))\n"
        }
        out += "\(name)_sum \(sum)\n"
        out += "\(name)_count \(count)\n"
        return out
    }
    
    public func jsonFormat() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        
        var qDict: [String: Double] = [:]
        for q in quantiles {
            qDict["\(q)"] = quantile(q)
        }
        return [name: ["quantiles": qDict, "sum": sum, "count": count]]
    }
}

// MARK: - Metrics HTTP Server

import Network

public final class MetricsServer {
    private let listener: NWListener
    private let port: UInt16
    
    public init(port: UInt16 = 9090) throws {
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
    }
    
    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        LogInfo("Metrics server started on port \(port)", subsystem: "metrics", category: "server")
    }
    
    public func stop() {
        listener.cancel()
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            // Simple HTTP GET /metrics
            let request = String(data: data, encoding: .utf8) ?? ""
            if request.contains("GET /metrics") || request.contains("GET /metrics ") {
                let metrics = MetricsRegistry.shared.expositionFormat()
                let response = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/plain; version=0.0.4; charset=utf-8\r
                    Content-Length: \(metrics.utf8.count)\r
                    \r
                    \(metrics)
                    """
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if request.contains("GET /metrics/json") {
                let json = MetricsRegistry.shared.jsonFormat()
                let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                let response = """
                    HTTP/1.1 200 OK\r
                    Content-Type: application/json\r
                    Content-Length: \(data.count)\r
                    \r
                    """
                connection.send(content: response.data(using: .utf8) + data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                let response = "HTTP/1.1 404 Not Found\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}

// MARK: - Measurement Helpers

/// Measure execution time and record to histogram
@discardableResult
public func measure<T>(_ histogram: Histogram, labels: [String: String] = [:], _ block: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        histogram.observe(elapsed, labels: labels)
    }
    return try block()
}

/// Async version
@discardableResult
public func measureAsync<T>(_ histogram: Histogram, labels: [String: String] = [:], _ block: () async throws -> T) async rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        histogram.observe(elapsed, labels: labels)
    }
    return try await block()
}

/// Measure and count
@discardableResult
public func measureAndCount<T>(_ histogram: Histogram, _ counter: Counter, labels: [String: String] = [:], _ block: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        histogram.observe(elapsed, labels: labels)
        counter.inc(labels)
    }
    return try block()
}
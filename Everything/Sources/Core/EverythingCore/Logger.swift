import Foundation
import os.log

// MARK: - Log Level

public enum LogLevel: String, Codable, Sendable, Comparable {
    case debug = "debug"
    case info = "info"
    case warn = "warn"
    case error = "error"
    case fatal = "fatal"
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warn, .error, .fatal]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Log Entry

public struct LogEntry: Codable, Sendable {
    public let timestamp: String
    public let level: LogLevel
    public let subsystem: String
    public let category: String
    public let message: String
    public let correlationID: String?
    public let metadata: [String: String]
    public let file: String
    public let function: String
    public let line: Int
    
    public init(timestamp: String, level: LogLevel, subsystem: String, category: String,
                message: String, correlationID: String?, metadata: [String: String],
                file: String, function: String, line: Int) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.correlationID = correlationID
        self.metadata = metadata
        self.file = file
        self.function = function
        self.line = line
    }
}

// MARK: - Logger

public final class Logger {
    public static let shared = Logger()
    
    private let queue = DispatchQueue(label: "com.everything.logger", qos: .utility, attributes: .concurrent)
    private let fileHandle: FileHandle
    private let consoleOutput: Bool
    private let minLevel: LogLevel
    private let dateFormatter: ISO8601DateFormatter
    private var currentLogFile: URL
    private let maxFileSize: UInt64 = 100 * 1024 * 1024  // 100MB
    private let maxFiles: Int = 7
    
    private init() {
        // Setup log directory
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Everything", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        // Create dated log file
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: Date())
        self.currentLogFile = logDir.appendingPathComponent("Everything_\(dateStr).log")
        
        // Open file handle
        if !FileManager.default.fileExists(atPath: currentLogFile.path) {
            FileManager.default.createFile(atPath: currentLogFile.path, contents: nil)
        }
        self.fileHandle = try! FileHandle(forWritingTo: currentLogFile)
        self.fileHandle.seekToEndOfFile()
        
        // Console output if env var set
        self.consoleOutput = ProcessInfo.processInfo.environment["EVERYTHING_DEBUG_CONSOLE"] == "1"
        self.minLevel = LogLevel(rawValue: ProcessInfo.processInfo.environment["EVERYTHING_LOG_LEVEL"] ?? "debug") ?? .debug
        
        // ISO8601 with microseconds
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // Rotate daily at midnight
        scheduleRotation()
    }
    
    private func scheduleRotation() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let midnight = calendar.startOfDay(for: tomorrow)
        let interval = midnight.timeIntervalSinceNow
        
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.rotateLog()
            self?.scheduleRotation()
        }
    }
    
    private func rotateLog() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Close current
            try? self.fileHandle.close()
            
            // Create new dated file
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let dateStr = formatter.string(from: Date())
            let logDir = self.currentLogFile.deletingLastPathComponent()
            self.currentLogFile = logDir.appendingPathComponent("Everything_\(dateStr).log")
            
            if !FileManager.default.fileExists(atPath: self.currentLogFile.path) {
                FileManager.default.createFile(atPath: self.currentLogFile.path, contents: nil)
            }
            self.fileHandle = try! FileHandle(forWritingTo: self.currentLogFile)
            
            // Clean old logs
            self.cleanOldLogs(in: logDir)
        }
    }
    
    private func cleanOldLogs(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let logFiles = files.filter { $0.lastPathComponent.hasPrefix("Everything_") && $0.pathExtension == "log" }
            .sorted { ($0.creationDate ?? Date.distantPast) < ($1.creationDate ?? Date.distantPast) }
        
        while logFiles.count > maxFiles {
            try? FileManager.default.removeItem(at: logFiles.removeFirst())
        }
    }
    
    public func log(_ level: LogLevel, subsystem: String, category: String,
                    message: String, correlationID: String? = nil, metadata: [String: String] = [:],
                    file: String = #file, function: String = #function, line: Int = #line) {
        guard level >= minLevel else { return }
        
        let entry = LogEntry(
            timestamp: dateFormatter.string(from: Date()),
            level: level,
            subsystem: subsystem,
            category: category,
            message: message,
            correlationID: correlationID,
            metadata: metadata,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line
        )
        
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(entry)
                self.fileHandle.write(data + Data("\n".utf8))
                
                // Check rotation
                if self.fileHandle.offsetInFile > self.maxFileSize {
                    self.rotateLog()
                }
                
                if self.consoleOutput || level >= .warn {
                    FileHandle.standardError.write(data + Data("\n".utf8))
                }
            } catch {
                // Fallback: write raw
                let fallback = "\(entry.timestamp) [\(entry.level.rawValue)] \(entry.subsystem)/\(entry.category): \(entry.message)\n"
                FileHandle.standardError.write(fallback.data(using: .utf8)!)
            }
        }
    }
    
    // Convenience methods
    public func debug(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) {
        log(.debug, subsystem: subsystem, category: category, message: msg, correlationID: corr, metadata: meta)
    }
    
    public func info(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) {
        log(.info, subsystem: subsystem, category: category, message: msg, correlationID: corr, metadata: meta)
    }
    
    public func warn(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) {
        log(.warn, subsystem: subsystem, category: category, message: msg, correlationID: corr, metadata: meta)
    }
    
    public func error(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) {
        log(.error, subsystem: subsystem, category: category, message: msg, correlationID: corr, metadata: meta)
    }
    
    public func fatal(_ msg: String, subsystem: String, category: String, corr: String? = nil, meta: [String: String] = [:]) {
        log(.fatal, subsystem: subsystem, category: category, message: msg, correlationID: corr, metadata: meta)
    }
}

// MARK: - Global Logging Functions

public func LogDebug(_ message: String, subsystem: String = "core", category: String = "general", correlationID: String? = nil, metadata: [String: String] = [:], file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.debug(message, subsystem: subsystem, category: category, corr: correlationID, meta: metadata)
}

public func LogInfo(_ message: String, subsystem: String = "core", category: String = "general", correlationID: String? = nil, metadata: [String: String] = [:], file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.info(message, subsystem: subsystem, category: category, corr: correlationID, meta: metadata)
}

public func LogWarn(_ message: String, subsystem: String = "core", category: String = "general", correlationID: String? = nil, metadata: [String: String] = [:], file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.warn(message, subsystem: subsystem, category: category, corr: correlationID, meta: metadata)
}

public func LogError(_ message: String, subsystem: String = "core", category: String = "general", correlationID: String? = nil, metadata: [String: String] = [:], file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.error(message, subsystem: subsystem, category: category, corr: correlationID, meta: metadata)
}

public func LogFatal(_ message: String, subsystem: String = "core", category: String = "general", correlationID: String? = nil, metadata: [String: String] = [:], file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.fatal(message, subsystem: subsystem, category: category, corr: correlationID, meta: metadata)
}

// MARK: - Correlation ID Helper

public struct CorrelationID {
    public static func new() -> String {
        return UUID().uuidString
    }
    
    public static func from(_ uuid: UUID) -> String {
        return uuid.uuidString
    }
}
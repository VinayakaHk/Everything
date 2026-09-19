import Foundation
import EverythingHelperCore
import EverythingXPC
import EndpointSecurity
import IOKit

// MARK: - Helper Main Entry Point

@main
struct EverythingHelper {
    static func main() async {
        do {
            // Initialize logging
            Logger.shared.info("EverythingHelper starting", subsystem: "helper", category: "startup")
            
            // Register signal handlers
            SignalHandler.register()
            
            // Create XPC listener
            let listener = NSXPCListener(machServiceName: "com.everything.helper")
            listener.delegate = HelperDelegate.shared
            listener.resume()
            
            Logger.shared.info("EverythingHelper ready", subsystem: "helper", category: "startup")
            
            // Keep running
            await withTaskCancellationHandler {
                try await Task.sleep(nanoseconds: UInt64.max)
            } onCancellation: {
                Logger.shared.info("EverythingHelper shutting down", subsystem: "helper", category: "shutdown")
            }
        } catch {
            Logger.shared.error("Fatal error: \(error)", subsystem: "helper", category: "fatal")
            exit(1)
        }
    }
}

// MARK: - Helper Delegate

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    static let shared = HelperDelegate()
    
    private let connectionQueue = DispatchQueue(label: "helper.xpc.connections", attributes: .concurrent)
    private var activeConnections: [NSXPCConnection] = []
    private let connectionsLock = NSLock()
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EverythingHelperProtocol.self)
        newConnection.exportedObject = HelperService.shared
        newConnection.invalidationHandler = { [weak self] in
            self?.removeConnection(newConnection)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.removeConnection(newConnection)
        }
        
        connectionsLock.lock()
        activeConnections.append(newConnection)
        connectionsLock.unlock()
        
        newConnection.resume()
        
        Logger.shared.info("XPC connection accepted", subsystem: "helper", category: "xpc",
                          metadata: ["pid": "\(newConnection.processIdentifier)"])
        
        return true
    }
    
    private func removeConnection(_ connection: NSXPCConnection) {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        activeConnections.removeAll { $0 === connection }
    }
}

// MARK: - Helper Service

final class HelperService: NSObject, EverythingHelperProtocol {
    static let shared = HelperService()
    
    private let volumeManager = VolumeManager()
    private let scanner = APFSScanner()
    private let esMonitor = EndpointSecurityMonitor()
    private let fsEventsMonitor = FSEventsMonitor()
    private let snapshotManager = SnapshotManager()
    private let fileResolver = FileResolver()
    
    private var activeScans: [UUID: ScanTask] = [:]
    private let scansLock = NSLock()
    
    private var subscriptions: [UUID: ESSubscription] = [:]
    private let subscriptionsLock = NSLock()
    
    override init() {
        super.init()
        Logger.shared.info("HelperService initialized", subsystem: "helper", category: "init")
    }
    
    // MARK: - Volume Management
    
    func enumerateVolumes() async throws -> [VolumeInfo] {
        Logger.shared.info("Enumerating volumes", subsystem: "helper", category: "volumes")
        return try await volumeManager.enumerateVolumes()
    }
    
    func getVolumeIdentity(deviceID: UInt32) async throws -> VolumeIdentity? {
        return try await volumeManager.getIdentity(for: deviceID)
    }
    
    // MARK: - Full Scan
    
    func startFullScan(volumeUUID: UUID) async throws -> AsyncThrowingStream<ScanProgress, Error> {
        Logger.shared.info("Starting full scan", subsystem: "helper", category: "scan",
                          metadata: ["volume": volumeUUID.uuidString])
        
        // Check if already scanning
        scansLock.lock()
        if activeScans[volumeUUID] != nil {
            scansLock.unlock()
            throw HelperError.scanFailed("Scan already in progress for volume")
        }
        scansLock.unlock()
        
        return AsyncThrowingStream { continuation in
            let task = ScanTask(volumeUUID: volumeUUID, continuation: continuation)
            
            scansLock.lock()
            activeScans[volumeUUID] = task
            scansLock.unlock()
            
            Task {
                do {
                    try await scanner.scanVolume(volumeUUID: volumeUUID) { progress in
                        continuation.yield(progress)
                    }
                    
                    scansLock.lock()
                    activeScans.removeValue(forKey: volumeUUID)
                    scansLock.unlock()
                    
                    continuation.finish()
                } catch {
                    scansLock.lock()
                    activeScans.removeValue(forKey: volumeUUID)
                    scansLock.unlock()
                    
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    func cancelScan(volumeUUID: UUID) async throws {
        scansLock.lock()
        let task = activeScans[volumeUUID]
        scansLock.unlock()
        
        task?.cancel()
    }
    
    // MARK: - Real-time Monitoring
    
    func subscribeToEvents(_ events: [ESEventType], volumeUUID: UUID) async throws -> SubscriptionToken {
        let token = SubscriptionToken(id: UUID(), volumeUUID: volumeUUID, eventTypes: events.map { $0.rawValue })
        
        subscriptionsLock.lock()
        subscriptions[token.id] = try await esMonitor.subscribe(
            events: events,
            volumeUUID: volumeUUID,
            token: token.id
        ) { [weak self] message in
            self?.handleESMessage(message, token: token.id)
        }
        subscriptionsLock.unlock()
        
        Logger.shared.info("Subscribed to ES events", subsystem: "helper", category: "es",
                          metadata: ["token": token.id.uuidString, "volume": volumeUUID.uuidString])
        
        return token
    }
    
    func unsubscribe(_ token: SubscriptionToken) async throws {
        subscriptionsLock.lock()
        let subscription = subscriptions.removeValue(forKey: token.id)
        subscriptionsLock.unlock()
        
        if let subscription = subscription {
            try await subscription.cancel()
        }
        
        Logger.shared.info("Unsubscribed from ES events", subsystem: "helper", category: "es",
                          metadata: ["token": token.id.uuidString])
    }
    
    private func handleESMessage(_ message: ESMessage, token: UUID) {
        // Forward to subscribers via XPC
        // In real implementation, would send via XPC connection
        Logger.shared.debug("ES event: \(message.eventType.rawValue)", subsystem: "helper", category: "es",
                           correlationID: token.uuidString)
    }
    
    // MARK: - File ID Resolution
    
    func resolvePath(deviceID: UInt32, inodeID: UInt64) async throws -> String? {
        return try await fileResolver.resolvePath(deviceID: deviceID, inodeID: inodeID)
    }
    
    func resolveFileRefURL(_ url: URL) async throws -> FSNode? {
        return try await fileResolver.resolveFileRefURL(url)
    }
    
    // MARK: - Snapshot Management
    
    func listSnapshots(volumeUUID: UUID) async throws -> [SnapshotInfo] {
        return try await snapshotManager.listSnapshots(volumeUUID: volumeUUID)
    }
    
    func mountSnapshot(volumeUUID: UUID, snapshotUUID: UUID, mountPoint: String) async throws {
        try await snapshotManager.mount(volumeUUID: volumeUUID, snapshotUUID: snapshotUUID, mountPoint: mountPoint)
    }
    
    func unmountSnapshot(mountPoint: String) async throws {
        try await snapshotManager.unmount(mountPoint: mountPoint)
    }
    
    // MARK: - Debug
    
    func getDebugInfo() async throws -> DebugInfo {
        let memory = getMemoryUsage()
        
        subscriptionsLock.lock()
        let activeSubscriptions = subscriptions.count
        let monitoredVolumes = Array(subscriptions.values.map { $0.volumeUUID })
        subscriptionsLock.unlock()
        
        scansLock.lock()
        let lastScan = activeScans.values.max(by: { $0.startTime < $1.startTime })
        let lastScanTime = lastScan?.startTime
        let lastScanDuration = lastScan?.duration
        let lastScanFiles = lastScan?.filesScanned
        scansLock.unlock()
        
        return DebugInfo(
            helperVersion: "1.0.0",
            uptime: ProcessInfo.processInfo.systemUptime,
            memoryUsage: memory,
            activeSubscriptions: activeSubscriptions,
            volumesMonitored: monitoredVolumes,
            lastScanTime: lastScanTime,
            lastScanDuration: lastScanDuration,
            lastScanFiles: lastScanFiles
        )
    }
    
    private func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

// MARK: - Scan Task

final class ScanTask {
    let volumeUUID: UUID
    let continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation
    let startTime = Date()
    var duration: TimeInterval { Date().timeIntervalSince(startTime) }
    var filesScanned: UInt64 = 0
    var cancelled = false
    
    init(volumeUUID: UUID, continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation) {
        self.volumeUUID = volumeUUID
        self.continuation = continuation
    }
    
    func cancel() {
        cancelled = true
        continuation.finish(throwing: HelperError.scanCancelled)
    }
}

// MARK: - ESSubscription

protocol ESSubscription {
    var volumeUUID: UUID { get }
    func cancel() async throws
}

// MARK: - Signal Handler

enum SignalHandler {
    static func register() {
        signal(SIGINT) { _ in
            Logger.shared.info("Received SIGINT", subsystem: "helper", category: "signal")
            exit(0)
        }
        signal(SIGTERM) { _ in
            Logger.shared.info("Received SIGTERM", subsystem: "helper", category: "signal")
            exit(0)
        }
    }
}

// MARK: - Helper Errors

enum HelperError: Error, LocalizedError {
    case scanFailed(String)
    case scanCancelled
    case subscriptionFailed(String)
    case notSubscribed(UUID)
    case invalidVolume(UUID)
    case permissionDenied(String)
    case deviceAccessFailed(String)
    case internalError(String)
    
    var errorDescription: String? {
        switch self {
        case .scanFailed(let msg): return "Scan failed: \(msg)"
        case .scanCancelled: return "Scan was cancelled"
        case .subscriptionFailed(let msg): return "Subscription failed: \(msg)"
        case .notSubscribed(let uuid): return "Not subscribed to volume: \(uuid)"
        case .invalidVolume(let uuid): return "Invalid volume: \(uuid)"
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .deviceAccessFailed(let msg): return "Device access failed: \(msg)"
        case .internalError(let msg): return "Internal error: \(msg)"
        }
    }
}

// MARK: - Component Stubs (would be fully implemented)

final class VolumeManager {
    func enumerateVolumes() async throws -> [VolumeInfo] {
        // Use IOKit to enumerate volumes
        return []
    }
    
    func getIdentity(for deviceID: UInt32) async throws -> VolumeIdentity? {
        return nil
    }
}

final class APFSScanner {
    func scanVolume(volumeUUID: UUID, progress: @escaping (ScanProgress) -> Void) async throws {
        // Real implementation would:
        // 1. Open /dev/diskXsY
        // 2. Read NX Superblock -> Container -> Volume Superblock
        // 3. Resolve FS-Tree OID via OMAP
        // 4. Iterate FS-Tree B-Tree
        // 5. Parse inode/dir/extent records
        // 6. Build FSNode array
        // 7. Report progress
    }
}

final class EndpointSecurityMonitor {
    func subscribe(events: [ESEventType], volumeUUID: UUID, token: UUID, handler: @escaping (ESMessage) -> Void) async throws -> ESSubscription {
        // Create ESClient and subscribe to events
        return DummySubscription(volumeUUID: volumeUUID)
    }
}

final class DummySubscription: ESSubscription {
    let volumeUUID: UUID
    init(volumeUUID: UUID) { self.volumeUUID = volumeUUID }
    func cancel() async throws {}
}

final class FSEventsMonitor {
    // FSEvents fallback for non-APFS volumes
}

final class SnapshotManager {
    func listSnapshots(volumeUUID: UUID) async throws -> [SnapshotInfo] { return [] }
    func mount(volumeUUID: UUID, snapshotUUID: UUID, mountPoint: String) async throws {}
    func unmount(mountPoint: String) async throws {}
}

final class FileResolver {
    func resolvePath(deviceID: UInt32, inodeID: UInt64) async throws -> String? { return nil }
    func resolveFileRefURL(_ url: URL) async throws -> FSNode? { return nil }
}

// MARK: - ESMessage (simplified)

struct ESMessage {
    let eventType: ESEventType
    let timestamp: Date
    let file: ESFile
    let process: ESProcess
}

struct ESFile {
    let path: String
    let inodeID: UInt64
    let deviceID: UInt32
}

struct ESProcess {
    let pid: pid_t
    let name: String
}
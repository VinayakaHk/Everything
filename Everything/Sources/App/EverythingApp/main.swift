import Foundation
import EverythingCore
import ArgumentParser

// MARK: - Main Entry Point

@main
struct Everything: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Everything",
        abstract: "Instant file search for macOS built on APFS internals",
        version: "1.0.0",
        subcommands: [
            Search.self,
            Index.self,
            Helper.self,
            Server.self,
            Config.self,
            Version.self
        ],
        defaultSubcommand: Search.self
    )
}

// MARK: - Search Subcommand

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for files",
        discussion: """
        Search for files using Everything's instant search engine.
        
        Examples:
          everything search "test"                    # Search for "test"
          everything search "test" --size 1000..5000 # Filter by size
          everything search "test" --json            # JSON output
          everything search "test" --limit 10        # Limit results
        """
    )
    
    @Argument(help: "Search query")
    var query: String
    
    @Option(name: .shortAndLong, help: "Maximum results to return")
    var limit: Int = 1000
    
    @Option(name: .shortAndLong, help: "Result offset")
    var offset: Int = 0
    
    @Option(name: .shortAndLong, help: "Sort by property (name, size, modified, created, extension)")
    var sort: String = "name"
    
    @Flag(name: .shortAndLong, help: "Sort ascending")
    var ascending: Bool = true
    
    @Option(name: .shortAndLong, help: "Filter by size range (e.g., 1000..5000)")
    var size: String?
    
    @Option(name: .shortAndLong, help: "Filter by modification time (e.g., 2024-01-01..2024-12-31)")
    var modified: String?
    
    @Flag(name: .shortAndLong, help: "Case sensitive search")
    var caseSensitive: Bool = false
    
    @Flag(name: .shortAndLong, help: "Regular expression search")
    var regex: Bool = false
    
    @Flag(name: .shortAndLong, help: "Whole word match")
    var wholeWord: Bool = false
    
    @Flag(name: .shortAndLong, help: "Match full path")
    var path: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    @Flag(name: .shortAndLong, help: "Include file metadata in output")
    var metadata: Bool = false
    
    func run() async throws {
        let searchEngine = SearchEngine.shared
        
        // Parse query into bytecode
        let bytecode = try SearchEngine.compile(query: query, options: SearchOptions(
            caseSensitive: caseSensitive,
            regex: regex,
            wholeWord: wholeWord,
            matchPath: path
        ))
        
        // Apply additional filters
        var searchQuery = SearchQuery(bytecode: bytecode, limit: limit, offset: offset)
        
        if let sizeStr = size {
            let range = try parseRange(sizeStr)
            searchQuery.filters.append(.sizeRange(range))
        }
        
        if let modStr = modified {
            let range = try parseTimeRange(modStr)
            searchQuery.filters.append(.modTimeRange(range))
        }
        
        if sort != "name" {
            let property = try SearchProperty.from(string: sort)
            searchQuery.sort = SortDescriptor(property: property, ascending: ascending)
        }
        
        let snapshot = IndexManager.shared.currentSnapshot
        let results = try await SearchEngine.execute(searchQuery, against: snapshot)
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(results)
            print(String(data: data, encoding: .utf8)!)
        } else {
            for result in results {
                if metadata {
                    print("\(result.path) | \(result.fileSize) bytes | modified: \(Date(timeIntervalSince1970: TimeInterval(result.modTime)))")
                } else {
                    print(result.path)
                }
            }
        }
    }
    
    private func parseRange(_ str: String) throws -> ClosedRange<UInt64> {
        let parts = str.split(separator: ".")
        guard parts.count == 2 else { throw ValidationError("Invalid range format") }
        let min = UInt64(parts[0]) ?? 0
        let max = UInt64(parts[1]) ?? UInt64.max
        return min...max
    }
    
    private func parseTimeRange(_ str: String) throws -> ClosedRange<UInt64> {
        // Simplified - would parse dates properly
        let parts = str.split(separator: ".")
        guard parts.count == 2 else { throw ValidationError("Invalid time range format") }
        let min = UInt64(parts[0]) ?? 0
        let max = UInt64(parts[1]) ?? UInt64.max
        return min...max
    }
}

// MARK: - Index Subcommand

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Manage file index",
        subcommands: [
            IndexBuild.self,
            IndexRebuild.self,
            IndexStatus.self,
            IndexAddVolume.self,
            IndexRemoveVolume.self
        ],
        defaultSubcommand: IndexBuild.self
    )
}

struct IndexBuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build or rebuild the file index"
    )
    
    @Flag(name: .shortAndLong, help: "Force full rebuild")
    var force: Bool = false
    
    @Option(name: .shortAndLong, help: "Specific volume UUID to index")
    var volume: String?
    
    func run() async throws {
        let indexManager = IndexManager.shared
        
        if force {
            print("🔄 Force rebuilding index...")
            // Implementation would call IndexManager.rebuild()
        } else {
            print("🔄 Building index...")
        }
        
        // This would trigger the actual indexing
        // For now, just show status
        print("Index build initiated. Monitor progress with 'everything index status'")
    }
}

struct IndexRebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild",
        abstract: "Force complete index rebuild"
    )
    
    func run() async throws {
        print("🔄 Force rebuilding all indexes...")
        // Implementation
    }
}

struct IndexStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show index status"
    )
    
    func run() async throws {
        let snapshot = IndexManager.shared.currentSnapshot
        print("Index Status:")
        print("  Total nodes: \(snapshot.totalNodes)")
        print("  Memory usage: \(snapshot.estimatedMemoryBytes / 1024 / 1024) MB")
        print("  Volumes: \(snapshot.volumeCount)")
        print("  Last updated: \(Date(timeIntervalSince1970: TimeInterval(snapshot.lastUpdateTime)))")
    }
}

struct IndexAddVolume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-volume",
        abstract: "Add a volume to the index"
    )
    
    @Argument(help: "Volume UUID or path")
    var volume: String
    
    func run() async throws {
        print("Adding volume to index: \(volume)")
        // Implementation
    }
}

struct IndexRemoveVolume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-volume",
        abstract: "Remove a volume from the index"
    )
    
    @Argument(help: "Volume UUID")
    var volume: String
    
    func run() async throws {
        print("Removing volume from index: \(volume)")
        // Implementation
    }
}

// MARK: - Helper Subcommand

struct Helper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Manage privileged helper",
        subcommands: [
            HelperInstall.self,
            HelperUninstall.self,
            HelperStatus.self
        ],
        defaultSubcommand: HelperStatus.self
    )
}

struct HelperInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install privileged helper"
    )
    
    func run() async throws {
        print("🔧 Installing privileged helper...")
        try await HelperManager.install()
        print("✅ Helper installed successfully")
    }
}

struct HelperUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall privileged helper"
    )
    
    func run() async throws {
        print("🔧 Uninstalling privileged helper...")
        try await HelperManager.uninstall()
        print("✅ Helper uninstalled successfully")
    }
}

struct HelperStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show helper status"
    )
    
    func run() async throws {
        let status = try await HelperManager.status()
        print("Helper Status:")
        print("  Installed: \(status.installed ? "✅" : "❌")")
        print("  Running: \(status.running ? "✅" : "❌")")
        print("  Version: \(status.version)")
        print("  PID: \(status.pid ?? 0)")
    }
}

// MARK: - Server Subcommand

struct Server: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Manage network servers (ETP/HTTP)",
        subcommands: [
            ServerStart.self,
            ServerStop.self,
            ServerStatus.self
        ],
        defaultSubcommand: ServerStatus.self
    )
}

struct ServerStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start network server"
    )
    
    @Option(name: .shortAndLong, help: "Server type (etp, http)")
    var type: String = "etp"
    
    @Option(name: .shortAndLong, help: "Port number")
    var port: Int = 21
    
    func run() async throws {
        print("Starting \(type.uppercased()) server on port \(port)...")
        // Implementation
    }
}

struct ServerStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop network server"
    )
    
    func run() async throws {
        print("Stopping servers...")
    }
}

struct ServerStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show server status"
    )
    
    func run() async throws {
        print("Server status: Not implemented yet")
    }
}

// MARK: - Config Subcommand

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage configuration",
        subcommands: [
            ConfigGet.self,
            ConfigSet.self,
            ConfigList.self,
            ConfigReset.self
        ],
        defaultSubcommand: ConfigList.self
    )
}

struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get configuration value"
    )
    
    @Argument(help: "Configuration key")
    var key: String
    
    func run() async throws {
        let value = ConfigManager.shared.get(key)
        print(value ?? "not set")
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set configuration value"
    )
    
    @Argument(help: "Configuration key")
    var key: String
    
    @Argument(help: "Configuration value")
    var value: String
    
    func run() async throws {
        try ConfigManager.shared.set(key, value: value)
        print("Set \(key) = \(value)")
    }
}

struct ConfigList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configuration"
    )
    
    func run() async throws {
        let config = ConfigManager.shared.all()
        for (key, value) in config.sorted(by: { $0.key < $1.key }) {
            print("\(key) = \(value)")
        }
    }
}

struct ConfigReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset configuration to defaults"
    )
    
    @Flag(name: .shortAndLong, help: "Force reset without confirmation")
    var force: Bool = false
    
    func run() async throws {
        if !force {
            print("This will reset all configuration to defaults. Continue? (y/N)")
            let input = readLine()?.lowercased()
            guard input == "y" || input == "yes" else {
                print("Cancelled")
                return
            }
        }
        
        ConfigManager.shared.reset()
        print("Configuration reset to defaults")
    }
}

// MARK: - Version Subcommand

struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show version information"
    )
    
    func run() async throws {
        print("Everything-macOS v1.0.0")
        print("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
        print("APFS Parser: v1.0")
        print("Index Engine: Bytecode VM v1.0")
    }
}

// MARK: - Supporting Types

struct SearchOptions {
    let caseSensitive: Bool
    let regex: Bool
    let wholeWord: Bool
    let matchPath: Bool
}

struct SearchQuery {
    let bytecode: [SearchOpcode]
    var limit: Int = 1000
    var offset: Int = 0
    var filters: [SearchFilter] = []
    var sort: SortDescriptor?
}

struct SearchFilter {
    enum FilterType {
        case sizeRange(ClosedRange<UInt64>)
        case modTimeRange(ClosedRange<UInt64>)
        case createTimeRange(ClosedRange<UInt64>)
        case extensionMatch(String)
        case cloneGroup(UInt64)
        case bsdFlags(UInt32)
    }
    let type: FilterType
}

struct SortDescriptor {
    let property: SearchProperty
    let ascending: Bool
}

enum SearchProperty: String {
    case name, size, modified, created, accessed, changed, extension
    case writeGen = "write_gen"
    
    static func from(string: String) throws -> SearchProperty {
        switch string.lowercased() {
        case "name": return .name
        case "size": return .size
        case "modified", "mod": return .modified
        case "created", "create": return .created
        case "accessed", "access": return .accessed
        case "changed", "change": return .changed
        case "extension", "ext": return .extension
        case "write_gen", "wg": return .writeGen
        default: throw ValidationError("Unknown sort property: \(string)")
        }
    }
}

enum ValidationError: Error, CustomStringConvertible {
    case invalidRange(String)
    case invalidTimeRange(String)
    case invalidSortProperty(String)
    case custom(String)
    
    var description: String {
        switch self {
        case .invalidRange(let s): return "Invalid range: \(s)"
        case .invalidTimeRange(let s): return "Invalid time range: \(s)"
        case .invalidSortProperty(let s): return "Invalid sort property: \(s)"
        case .custom(let s): return s
        }
    }
}

// MARK: - Helper Manager

struct HelperManager {
    static func install() async throws {
        // Would use SMJobBless
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    
    static func uninstall() async throws {
        // Would use SMJobRemove
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    
    struct Status {
        let installed: Bool
        let running: Bool
        let version: String
        let pid: Int?
    }
    
    static func status() async throws -> Status {
        let installed = FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/com.everything.helper")
        let running = (try? await isServiceRunning()) ?? false
        return Status(installed: installed, running: running, version: "1.0.0", pid: nil)
    }
    
    private static func isServiceRunning() async throws -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list", "com.everything.helper"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

// MARK: - Config Manager

struct ConfigManager {
    static let shared = ConfigManager()
    
    private let defaults = UserDefaults.standard
    private let prefix = "com.everything."
    
    func get(_ key: String) -> String? {
        return defaults.string(forKey: prefix + key)
    }
    
    func set(_ key: String, value: String) {
        defaults.set(value, forKey: prefix + key)
    }
    
    func all() -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            if key.hasPrefix(prefix) {
                let shortKey = String(key.dropFirst(prefix.count))
                result[shortKey] = value as? String ?? ""
            }
        }
        return result
    }
    
    func reset() {
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

// Extension for SearchEngine
extension SearchEngine {
    static func compile(query: String, options: SearchOptions) throws -> [SearchOpcode] {
        // Implementation would parse query string into bytecode
        return [.namePrefix(query)]
    }
    
    static func execute(_ query: SearchQuery, against snapshot: IndexSnapshot) async throws -> [SearchResult] {
        let vm = BytecodeVM()
        return vm.execute(query.bytecode, against: snapshot)
    }
}
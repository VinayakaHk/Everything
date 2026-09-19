// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Everything",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        // Main app executable
        .executable(name: "Everything", targets: ["Everything"]),
        // Privileged helper (XPC service)
        .executable(name: "EverythingHelper", targets: ["EverythingHelper"]),
        // Shared XPC protocol
        .library(name: "EverythingXPC", targets: ["EverythingXPC"]),
        // APFS parsing C library
        .library(name: "EverythingAPFS", targets: ["EverythingAPFS"]),
        // Validation gates runner
        .executable(name: "Phase1GateRunner", targets: ["Phase1GateRunner"]),
        // Benchmarks
        .executable(name: "Benchmarks", targets: ["EverythingBenchmarks"]),
        // Golden master population
        .executable(name: "PopulateGoldenMaster", targets: ["PopulateGoldenMaster"]),
    ],
    dependencies: [
        // Compression (LZ4 via system compression framework)
        // .package(url: "https://github.com/molecular/lz4-swift", from: "1.0.0"),
        // CLI argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // Testing
        .package(url: "https://github.com/Quick/Quick", from: "7.0.0"),
        .package(url: "https://github.com/Quick/Nimble", from: "12.0.0"),
        // Property-based testing
        .package(url: "https://github.com/Quick/SwiftCheck", from: "0.12.0"),
    ],
    targets: [
        // MARK: - Core Libraries
        .target(
            name: "EverythingXPC",
            dependencies: [],
            path: "EverythingXPC/Sources",
            swiftSettings: [
                .define("EVERYTHING_VERSION", to: "\"1.0.0\""),
                .unsafeFlags(["-Xfrontend", "-warn-long-expression-type-checking=100"]),
            ]
        ),
        
        .target(
            name: "EverythingAPFS",
            dependencies: [],
            path: "EverythingAPFS/Sources",
            publicHeadersPath: "include",
            cSettings: [
                .define("APFS_LITTLE_ENDIAN"),
                .unsafeFlags(["-Wno-unused-parameter"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        
        // MARK: - Main App
        .target(
            name: "EverythingCore",
            dependencies: [
                "EverythingXPC",
                "EverythingAPFS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Everything/Sources/Core",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .define("DEBUG_LOGGING", .when(configuration: .debug)),
            ]
        ),
        
        .executableTarget(
            name: "Everything",
            dependencies: ["EverythingCore"],
            path: "Everything/Sources/App",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("QuickLook"),
                .linkedFramework("FileProvider"),
                .linkedFramework("CoreSpotlight"),
            ]
        ),
        
        // MARK: - Privileged Helper
        .target(
            name: "EverythingHelperCore",
            dependencies: [
                "EverythingXPC",
                "EverythingAPFS",
            ],
            path: "EverythingHelper/Sources/Core",
            swiftSettings: [
                .define("HELPER_BUILD"),
            ]
        ),
        
        .executableTarget(
            name: "EverythingHelper",
            dependencies: ["EverythingHelperCore"],
            path: "EverythingHelper/Sources/Service",
            linkerSettings: [
                .linkedFramework("EndpointSecurity"),
                .linkedFramework("IOKit"),
            ]
        ),
        
        // MARK: - Validation Gates
        .executableTarget(
            name: "Phase1GateRunner",
            dependencies: [
                "EverythingXPC",
                "EverythingCore",
            ],
            path: "Phase1GateRunner/Sources",
            swiftSettings: [
                .define("GATE_RUNNER"),
            ]
        ),
        
        // MARK: - Benchmarks
        .executableTarget(
            name: "EverythingBenchmarks",
            dependencies: [
                "EverythingCore",
                "EverythingAPFS",
            ],
            path: "EverythingBenchmarks/Sources",
            swiftSettings: [
                .define("BENCHMARK_BUILD"),
            ]
        ),
        
        // MARK: - Golden Master Population
        .executableTarget(
            name: "PopulateGoldenMaster",
            dependencies: [],
            path: "Scripts/PopulateGoldenMaster",
        ),
        
        // MARK: - Tests
        .testTarget(
            name: "EverythingUnitTests",
            dependencies: [
                "EverythingCore",
                "EverythingAPFS",
                "EverythingXPC",
                .product(name: "Nimble", package: "Nimble"),
                .product(name: "SwiftCheck", package: "SwiftCheck"),
            ],
            path: "EverythingTests/Unit",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        
        .testTarget(
            name: "EverythingIntegrationTests",
            dependencies: [
                "EverythingCore",
                "EverythingXPC",
                .product(name: "Nimble", package: "Nimble"),
            ],
            path: "EverythingIntegrationTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        
        .testTarget(
            name: "APFSParsersTests",
            dependencies: [
                "EverythingAPFS",
                .product(name: "Nimble", package: "Nimble"),
            ],
            path: "EverythingTests/Parsers",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        
        .testTarget(
            name: "BytecodeVMTests",
            dependencies: [
                "EverythingCore",
                .product(name: "SwiftCheck", package: "SwiftCheck"),
            ],
            path: "EverythingTests/BytecodeVM",
        ),
        
        .testTarget(
            name: "IndexManagerTests",
            dependencies: [
                "EverythingCore",
                .product(name: "SwiftCheck", package: "SwiftCheck"),
            ],
            path: "EverythingTests/IndexManager",
        ),
        
        .testTarget(
            name: "DatabaseTests",
            dependencies: [
                "EverythingCore",
            ],
            path: "EverythingTests/Database",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
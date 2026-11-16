// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemorySaver",
    defaultLocalization: "ja",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MemorySaverCore", targets: ["MemorySaverCore"]),
        .library(name: "Sampling", targets: ["Sampling"]),
        .library(name: "Analysis", targets: ["Analysis"]),
        .library(name: "MemorySaverUI", targets: ["MemorySaverUI"]),
    ],
    targets: [
        // Shared value types and protocols. No system calls.
        .target(name: "MemorySaverCore", resources: [.process("Resources")]),
        // Reads memory numbers from the system.
        .target(name: "Sampling", dependencies: ["MemorySaverCore"]),
        // History (SQLite) and recommendation rules.
        .target(
            name: "Analysis",
            dependencies: ["MemorySaverCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // SwiftUI views, view model, settings, relaunch action, notifications.
        .target(name: "MemorySaverUI", dependencies: ["MemorySaverCore"]),
        // The menu bar app: wires samplers, store and advisor to the UI.
        .executableTarget(
            name: "MemorySaver",
            dependencies: ["MemorySaverCore", "Sampling", "Analysis", "MemorySaverUI"]
        ),

        .testTarget(name: "MemorySaverCoreTests", dependencies: ["MemorySaverCore"]),
        .testTarget(name: "SamplingTests", dependencies: ["Sampling"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis"]),
        .testTarget(name: "MemorySaverUITests", dependencies: ["MemorySaverUI"]),
    ]
)

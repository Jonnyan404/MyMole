// swift-tools-version:6.2
import PackageDescription

// Swift 6.2.4 on this toolchain asserts while emitting debug info for a boxed
// CGFloat or Array<CGFloat> ("Failed to reconstruct type for
// $s12CoreGraphics7CGFloatVz_XxD"), naming this flag as the workaround. Both
// the app target and the test targets hit it.
let roundTripDebugTypes: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-disable-round-trip-debug-types"])
]

// MyMole — a native SwiftUI Mac cleaner. Everything runs on MyMole's own
// engine. In the direct edition, system-level work goes through a privileged
// tool for one request at a time, via an approved service or an administrator
// prompt. The App Store edition has no such tool.
let package = Package(
    name: "MyMole",
    platforms: [
        // 14.4 rather than 14.0: NSHostingMenu, used by the pane toolbars,
        // arrived in 14.4. The build host runs 14.8.9.
        .macOS("14.4")
    ],
    products: [
        .executable(name: "MyMole", targets: ["MyMole"]),
        .library(name: "StorageKit", targets: ["StorageKit"]),
        .library(name: "SystemKit", targets: ["SystemKit"]),
        .library(name: "PrivilegedKit", targets: ["PrivilegedKit"]),
        .executable(name: "MyMoleHelper", targets: ["MyMoleHelper"]),
    ],
    targets: [
        // Back-deploy of Swift's Synchronization module (Mutex/Atomic are
        // macOS 15+ in the standard library) so the package runs on macOS 14.
        .target(
            name: "SynchronizationCompat",
            path: "Sources/SynchronizationCompat"
        ),
        // Disk analysis: parallel bulk-attribute scanner, folder tree, file
        // kinds, chart layouts, snapshots for change tracking, projects,
        // installers, Deep Clean rules, apps and leftovers, Trash + undo,
        // cleanup history.
        .target(
            name: "StorageKit",
            dependencies: ["SynchronizationCompat"],
            path: "Sources/StorageKit"
        ),
        // Live readings of the Mac itself: CPU, memory, volumes, disk and
        // network throughput, battery and the busiest processes.
        .target(
            name: "SystemKit",
            dependencies: ["SynchronizationCompat"],
            path: "Sources/SystemKit"
        ),
        // What runs as root, and the contract with it: maintenance tasks,
        // system cache rules, and the request and reply the tool reads and
        // prints (versioned JSON on its command line/output or authenticated XPC).
        .target(
            name: "PrivilegedKit",
            dependencies: ["StorageKit", "SynchronizationCompat"],
            path: "Sources/PrivilegedKit"
        ),
        // The privileged tool: handles approved requests under a shared lock,
        // as an on-demand service or a one-shot command.
        .executableTarget(
            name: "MyMoleHelper",
            dependencies: ["PrivilegedKit", "StorageKit"],
            path: "Sources/MyMoleHelper"
        ),
        .executableTarget(
            name: "MyMole",
            dependencies: ["StorageKit", "SystemKit", "PrivilegedKit", "SynchronizationCompat"],
            path: "Sources/MyMole",
            swiftSettings: roundTripDebugTypes
        ),
        .testTarget(
            name: "MyMoleTests",
            dependencies: ["MyMole", "SynchronizationCompat"],
            path: "Tests/MyMoleTests",
            swiftSettings: roundTripDebugTypes
        ),
        .testTarget(
            name: "StorageKitTests",
            dependencies: ["StorageKit", "SynchronizationCompat"],
            path: "Tests/StorageKitTests",
            resources: [.copy("Fixtures/UninstallCorpus.json"), .copy("Fixtures/Receipts.json")],
            swiftSettings: roundTripDebugTypes
        ),
        .testTarget(
            name: "PrivilegedKitTests",
            dependencies: ["PrivilegedKit", "StorageKit", "SynchronizationCompat"],
            path: "Tests/PrivilegedKitTests",
            swiftSettings: roundTripDebugTypes
        ),
        .testTarget(
            name: "SystemKitTests",
            dependencies: ["SystemKit", "SynchronizationCompat"],
            path: "Tests/SystemKitTests",
            swiftSettings: roundTripDebugTypes
        ),
    ]
)

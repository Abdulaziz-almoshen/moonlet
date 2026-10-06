// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Moonlet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoonletCore", targets: ["MoonletCore"]),
        .library(name: "MoonletIPC", targets: ["MoonletIPC"]),
        .library(name: "MoonletAdapters", targets: ["MoonletAdapters"]),
        .library(name: "MoonletSetup", targets: ["MoonletSetup"]),
        .library(name: "MoonletBrain", targets: ["MoonletBrain"]),
        .executable(name: "moonlet", targets: ["moonlet"]),
        .executable(name: "MoonletApp", targets: ["MoonletApp"]),
    ],
    targets: [
        // MARK: Libraries

        .target(name: "MoonletCore"),
        .target(name: "MoonletIPC", dependencies: ["MoonletCore"]),
        .target(name: "MoonletAdapters", dependencies: ["MoonletCore"]),
        .target(name: "MoonletSetup", dependencies: ["MoonletCore"]),
        // Attention rules, gestures, and pointer policy: pure logic, no I/O.
        .target(name: "MoonletBrain"),

        // MARK: Command-line tool

        .executableTarget(
            name: "moonlet",
            dependencies: ["MoonletCore", "MoonletIPC", "MoonletAdapters", "MoonletSetup"]
        ),

        // MARK: App

        // The menu bar app. `scripts/build-app.sh` packages it as Moonlet.app.
        .executableTarget(
            name: "MoonletApp",
            dependencies: ["MoonletCore", "MoonletIPC", "MoonletBrain"]
        ),

        // MARK: Tests

        .testTarget(name: "MoonletCoreTests", dependencies: ["MoonletCore"]),
        .testTarget(name: "MoonletIPCTests", dependencies: ["MoonletIPC", "MoonletCore"]),
        .testTarget(
            name: "MoonletAdaptersTests",
            dependencies: ["MoonletAdapters", "MoonletCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MoonletSetupTests", dependencies: ["MoonletSetup"]),
        .testTarget(name: "MoonletBrainTests", dependencies: ["MoonletBrain"]),
    ],
    swiftLanguageModes: [.v6]
)

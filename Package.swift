// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The Go engine archive is produced by Scripts/build-engine.sh into
// Engine/build. Resolving an absolute path from #filePath keeps the linker
// flags correct regardless of the directory the build is invoked from.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let engineBuildDir = "\(packageRoot)/Engine/build"

// The Go archive is libvbxgo.a, and its name must not case-fold to any Swift
// target's: SwiftPM writes libVBXEngine.a into its own Products directory,
// which sits ahead of Engine/build on the search path, and on case-insensitive
// APFS `-lvbxengine` found that instead (BUGS.md, 2026-10-01).
// scripts/test-packaging.py asserts the names stay apart.
//
// Frameworks the Go runtime and modernc.org/sqlite need on darwin.
let engineLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(engineBuildDir)"]),
    .linkedLibrary("vbxgo"),
    .linkedLibrary("resolv"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("Security"),
]

let package = Package(
    name: "vbx",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vbx", targets: ["vbx"]),
        .executable(name: "vbx-cli", targets: ["vbx-cli"]),
        .library(name: "VBXCore", targets: ["VBXCore"]),
        .library(name: "VBXEngine", targets: ["VBXEngine"]),
        .library(name: "VBXUI", targets: ["VBXUI"]),
    ],
    targets: [
        // C module exposing the Go archive's generated header.
        .target(
            name: "CVBXEngine",
            linkerSettings: engineLinkerSettings
        ),

        // Value types and pure logic. No engine dependency, so it stays
        // testable without linking the archive.
        .target(name: "VBXCore"),

        // async/await facade over the C ABI.
        .target(
            name: "VBXEngine",
            dependencies: ["CVBXEngine", "VBXCore"]
        ),

        // Application state, split out of the executable so it can be tested
        // headlessly — an executable target cannot be imported by tests.
        .target(
            name: "VBXAppCore",
            dependencies: ["VBXCore", "VBXEngine"]
        ),

        // SwiftUI views, in a library rather than the executable so they can be
        // hosted and snapshot-rendered by tests.
        .target(
            name: "VBXUI",
            dependencies: ["VBXCore", "VBXEngine", "VBXAppCore"]
        ),

        .executableTarget(
            name: "vbx",
            dependencies: ["VBXCore", "VBXEngine", "VBXAppCore", "VBXUI"]
        ),

        .executableTarget(
            name: "vbx-cli",
            dependencies: ["VBXCore", "VBXEngine"]
        ),

        .testTarget(name: "VBXCoreTests", dependencies: ["VBXCore"]),
        .testTarget(name: "VBXEngineTests", dependencies: ["VBXEngine", "VBXCore"]),
        .testTarget(name: "VBXAppCoreTests", dependencies: ["VBXAppCore", "VBXCore"]),
        .testTarget(name: "VBXUITests", dependencies: ["VBXUI", "VBXAppCore", "VBXCore"]),
    ],
    swiftLanguageModes: [.v5]
)

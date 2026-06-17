// swift-tools-version: 6.2
// Swift 6.2 tools; requires Swift 6.2+ toolchain (installed: 6.3.2).
// macOS platform: .v26 (Tahoe) -- requires PackageDescription 6.2+ (unavailable in tools 6.0).

import PackageDescription

let package = Package(
    name: "swift-usb-imager",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "DiskModel",        targets: ["DiskModel"]),
        .library(name: "HelperProtocol",   targets: ["HelperProtocol"]),
        .library(name: "Verifier",         targets: ["Verifier"]),
        .library(name: "KeychainStore",    targets: ["KeychainStore"]),
        .library(name: "FlashEngine",      targets: ["FlashEngine"]),
        .library(name: "PrivilegedHelper", targets: ["PrivilegedHelper"]),
        .library(name: "AppUI",            targets: ["AppUI"]),
        .executable(name: "USBImagerApp",  targets: ["USBImagerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Library targets
        .target(
            name: "DiskModel",
            path: "Sources/DiskModel"
        ),
        .target(
            name: "HelperProtocol",
            path: "Sources/HelperProtocol"
        ),
        .target(
            name: "Verifier",
            path: "Sources/Verifier"
        ),
        .target(
            name: "KeychainStore",
            dependencies: ["Verifier"],
            path: "Sources/KeychainStore"
        ),
        .target(
            name: "FlashEngine",
            dependencies: ["HelperProtocol", "Verifier", "DiskModel", "KeychainStore"],
            path: "Sources/FlashEngine"
        ),
        .target(
            name: "PrivilegedHelper",
            dependencies: ["HelperProtocol", "Verifier", "DiskModel"],
            path: "Sources/PrivilegedHelper"
        ),
        .target(
            name: "AppUI",
            dependencies: ["DiskModel", "FlashEngine", "Verifier", "KeychainStore"],
            path: "Sources/AppUI"
        ),
        .executableTarget(
            name: "USBImagerApp",
            dependencies: [
                "AppUI", "FlashEngine", "DiskModel", "KeychainStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/USBImagerApp"
        ),

        // MARK: - Test targets
        .testTarget(
            name: "DiskModelTests",
            dependencies: ["DiskModel"],
            path: "Tests/DiskModelTests"
        ),
        .testTarget(
            name: "HelperProtocolTests",
            dependencies: ["HelperProtocol"],
            path: "Tests/HelperProtocolTests"
        ),
        .testTarget(
            name: "VerifierTests",
            dependencies: ["Verifier"],
            path: "Tests/VerifierTests"
        ),
        .testTarget(
            name: "KeychainStoreTests",
            dependencies: ["KeychainStore"],
            path: "Tests/KeychainStoreTests"
        ),
        .testTarget(
            name: "FlashEngineTests",
            dependencies: ["FlashEngine", "DiskModel", "HelperProtocol"],
            path: "Tests/FlashEngineTests"
        ),
        .testTarget(
            name: "PrivilegedHelperTests",
            dependencies: ["PrivilegedHelper", "DiskModel"],
            path: "Tests/PrivilegedHelperTests"
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: ["AppUI", "FlashEngine", "DiskModel", "HelperProtocol", "KeychainStore"],
            path: "Tests/AppUITests"
        ),
    ]
)

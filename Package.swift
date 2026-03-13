// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HotSwift",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        .library(name: "HotSwift", targets: ["HotSwift"]),
        .library(name: "HotSwiftUI", targets: ["HotSwiftUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "510.0.0"),
    ],
    targets: [
        // MARK: - C Target (Mach-O symbol rebinding)
        .target(
            name: "CHotSwiftFishhook",
            path: "Sources/CHotSwiftFishhook",
            publicHeadersPath: "include"
        ),

        // MARK: - Core Engine
        .target(
            name: "HotSwiftCore",
            dependencies: [
                "CHotSwiftFishhook",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/HotSwiftCore"
        ),

        // MARK: - Diagnostics
        .target(
            name: "HotSwiftDiagnostics",
            path: "Sources/HotSwiftDiagnostics"
        ),

        // MARK: - Public API
        .target(
            name: "HotSwift",
            dependencies: ["HotSwiftCore", "HotSwiftDiagnostics"],
            path: "Sources/HotSwift"
        ),

        // MARK: - UIKit/SwiftUI Helpers
        .target(
            name: "HotSwiftUI",
            dependencies: ["HotSwift"],
            path: "Sources/HotSwiftUI"
        ),

        // MARK: - Tests
        .testTarget(
            name: "HotSwiftTests",
            dependencies: ["HotSwift", "HotSwiftCore"],
            path: "Tests/HotSwiftTests"
        ),
    ]
)

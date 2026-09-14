// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wisp", targets: ["wisp"]),
        .executable(name: "wispd", targets: ["wispd"]),
        .library(name: "WispCore", targets: ["WispCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "WispCore",
            path: "Sources/WispCore",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "wispd",
            dependencies: ["WispCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/wispd",
            linkerSettings: [
                // Sparkle.framework is copied into Wisp.app/Contents/Frameworks by scripts/package.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "wisp",
            dependencies: ["WispCore"],
            path: "Sources/wisp",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "WispCoreTests",
            dependencies: ["WispCore"],
            path: "Tests/WispCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)

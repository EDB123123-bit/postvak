// swift-tools-version:6.0
import PackageDescription

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Postvak",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Postvak", targets: ["Postvak"]),
        .executable(name: "postvak-dev", targets: ["postvak-dev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "PostvakCore",
                dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                swiftSettings: v5),
        .target(name: "PostvakAI", dependencies: ["PostvakCore"], swiftSettings: v5),
        .target(name: "PostvakAudio",
                dependencies: [
                    "PostvakCore", "PostvakAI",
                    .product(name: "WhisperKit", package: "argmax-oss-swift"),
                    .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                ],
                swiftSettings: v5),
        .target(name: "PostvakMCP", dependencies: ["PostvakCore"], swiftSettings: v5),
        .executableTarget(name: "Postvak",
                          dependencies: ["PostvakCore", "PostvakAI", "PostvakAudio", "PostvakMCP"],
                          swiftSettings: v5),
        .executableTarget(name: "postvak-dev",
                          dependencies: ["PostvakCore", "PostvakAI", "PostvakAudio", "PostvakMCP"],
                          swiftSettings: v5),
        // Runs the suite without Xcode: `swift run postvak-tests`. The command line tools ship Testing.framework
        // but not a working `swift test` for it, so this target calls its entry point directly.
        .executableTarget(name: "postvak-tests",
                          dependencies: ["PostvakCore", "PostvakAI", "PostvakMCP"],
                          path: "Tests/PostvakTests",
                          swiftSettings: v5 + [.unsafeFlags(["-enable-testing", "-F", cltFrameworks])],
                          linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib", "-framework", "Testing"])]),
    ]
)

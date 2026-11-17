// swift-tools-version:6.0
import PackageDescription

// Hearth Spark: a Mac companion that works out who the user is close to from data an
// iPhone app can't read (Messages, call history), entirely on the Mac, and writes a
// small file for the iOS app. See docs/hearth-spark-privacy.md.
let package = Package(
    name: "HearthSpark",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "hearth-spark", targets: ["hearth-spark"]),
        // The Mac app. Bundle it with scripts/make-app.sh so it gets its own permissions.
        .executable(name: "HearthSparkApp", targets: ["HearthSparkApp"]),
        // The Spark file format and scoring, so the iOS app can share the same types.
        .library(name: "HearthSparkCore", targets: ["HearthSparkCore"]),
    ],
    targets: [
        .target(
            name: "HearthSparkCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "hearth-spark",
            dependencies: ["HearthSparkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HearthSparkApp",
            dependencies: ["HearthSparkCore"],
            exclude: ["Info.plist", "HearthSpark.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HearthSparkCoreTests",
            dependencies: ["HearthSparkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

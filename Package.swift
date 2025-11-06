// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Hearth",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Hearth",
            targets: ["Hearth"]
        ),
    ],
    dependencies: [
        // Add your dependencies here
    ],
    targets: [
        .target(
            name: "Hearth",
            dependencies: [],
            path: "Hearth/Sources/Hearth"
        ),
        .testTarget(
            name: "HearthTests",
            dependencies: ["Hearth"],
            path: "Hearth/Tests/HearthTests"
        ),
    ]
)

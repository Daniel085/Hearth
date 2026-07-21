// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceClustering",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FaceClustering", targets: ["FaceClustering"])
    ],
    targets: [
        .target(name: "FaceClustering"),
        .testTarget(name: "FaceClusteringTests", dependencies: ["FaceClustering"]),
    ]
)

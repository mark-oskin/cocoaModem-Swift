// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoreDSP",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoreDSP", targets: ["CoreDSP"])
    ],
    targets: [
        .target(name: "CoreDSP"),
        .testTarget(name: "CoreDSPTests", dependencies: ["CoreDSP"])
    ]
)

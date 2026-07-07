// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ModemKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ModemKit", targets: ["ModemKit"])
    ],
    dependencies: [
        .package(path: "../CoreDSP")
    ],
    targets: [
        .target(name: "ModemKit", dependencies: ["CoreDSP"])
    ]
)

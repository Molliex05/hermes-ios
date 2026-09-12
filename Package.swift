// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IrisCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "IrisCore", targets: ["IrisCore"])],
    targets: [
        .target(name: "IrisCore", path: "Iris/Core"),
        .testTarget(name: "IrisCoreTests", dependencies: ["IrisCore"], path: "IrisTests")
    ]
)

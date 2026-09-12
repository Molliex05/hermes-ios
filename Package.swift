// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HermesIOSCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "HermesIOSCore", targets: ["HermesIOSCore"])],
    targets: [
        .target(name: "HermesIOSCore", path: "HermesIOS/Core"),
        .testTarget(name: "HermesIOSCoreTests", dependencies: ["HermesIOSCore"], path: "HermesIOSTests")
    ]
)

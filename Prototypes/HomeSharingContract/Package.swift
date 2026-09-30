// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HomeSharingContract",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HomeSharingContract", targets: ["HomeSharingContract"])],
    targets: [
        .target(name: "HomeSharingContract"),
        .testTarget(name: "HomeSharingContractTests", dependencies: ["HomeSharingContract"])
    ]
)

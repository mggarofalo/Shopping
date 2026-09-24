// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PersonalCartContract",
    platforms: [.macOS(.v13)],
    products: [.library(name: "PersonalCartContract", targets: ["PersonalCartContract"])],
    targets: [
        .target(name: "PersonalCartContract"),
        .testTarget(name: "PersonalCartContractTests", dependencies: ["PersonalCartContract"])
    ]
)

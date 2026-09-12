// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shipyard",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Free shafer.llc registration, Help and Contact Support.
        .package(url: "https://github.com/shaferllc/swift-licensing", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Shipyard",
            dependencies: [.product(name: "ShaferAccount", package: "swift-licensing")],
            path: "Sources/Shipyard"
        ),
        .testTarget(
            name: "ShipyardTests",
            dependencies: ["Shipyard"],
            path: "Tests/ShipyardTests"
        ),
    ]
)

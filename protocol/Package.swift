// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NetBSDAgentProtocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetBSDAgentProtocol", targets: ["NetBSDAgentProtocol"])
    ],
    targets: [
        .target(name: "NetBSDAgentProtocol"),
        .testTarget(
            name: "NetBSDAgentProtocolTests",
            dependencies: ["NetBSDAgentProtocol"],
            resources: [.copy("../../vectors/frames.json")]
        )
    ]
)

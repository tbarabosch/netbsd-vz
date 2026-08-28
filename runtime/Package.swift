// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "container-runtime-netbsd",
    platforms: [.macOS("15")],
    products: [
        .library(name: "NetBSDRuntimeCore", targets: ["NetBSDRuntimeCore"]),
        .executable(name: "container-runtime-netbsd", targets: ["ContainerRuntimeNetBSD"]),
        .executable(name: "netbsd", targets: ["NetBSDCLI"]),
        .executable(name: "netbsd-oci-base", targets: ["NetBSDOCIBase"]),
    ],
    dependencies: [
        .package(path: "../protocol"),
        // Prepared from Apple Container 1.3.0 by the runtime-deps target.
        .package(name: "container", path: "../.build/apple-container-compat"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.41.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "NetBSDOCI",
            dependencies: [
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            resources: [.copy("Resources/runtime-overlay")]
        ),
        .target(
            name: "NetBSDRuntimeCore",
            dependencies: [
                .product(name: "NetBSDAgentProtocol", package: "protocol")
            ],
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
        .executableTarget(
            name: "ContainerRuntimeNetBSD",
            dependencies: [
                "NetBSDRuntimeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerLog", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerRuntimeClient", package: "container"),
                .product(name: "ContainerXPC", package: "container"),
                .product(name: "Containerization", package: "containerization"),
            ]
        ),
        .executableTarget(
            name: "NetBSDCLI",
            dependencies: [
                "NetBSDOCI",
                "NetBSDRuntimeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerImagesService", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ]
        ),
        .executableTarget(
            name: "NetBSDOCIBase",
            dependencies: [
                "NetBSDOCI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "NetBSDRuntimeCoreTests", dependencies: ["NetBSDRuntimeCore"]),
        .testTarget(
            name: "NetBSDOCITests",
            dependencies: [
                "NetBSDOCI",
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ]
        ),
    ]
)

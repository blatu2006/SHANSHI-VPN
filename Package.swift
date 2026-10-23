// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HillstoneConnect",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HillstoneConnect", targets: ["HillstoneConnect"]),
        .library(name: "HillstoneProtocol", targets: ["HillstoneProtocol"]),
        .library(name: "HillstonePacketTunnel", targets: ["HillstonePacketTunnel"])
    ],
    targets: [
        .target(name: "HillstoneProtocol"),
        .target(
            name: "HillstonePacketTunnel",
            dependencies: ["HillstoneProtocol"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "HillstoneConnect",
            dependencies: ["HillstoneProtocol"]
        ),
        .testTarget(
            name: "HillstoneProtocolTests",
            dependencies: ["HillstoneProtocol"]
        ),
        .testTarget(
            name: "HillstonePacketTunnelTests",
            dependencies: ["HillstonePacketTunnel", "HillstoneProtocol"]
        ),
        .testTarget(
            name: "HillstoneConnectSnapshotTests",
            dependencies: ["HillstoneConnect"]
        )
    ]
)

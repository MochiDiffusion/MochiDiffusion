// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CompactSlider",
    platforms: [
        .macOS(.v11), .iOS(.v14), .watchOS(.v7),
    ],
    products: [
        .library(name: "CompactSlider", targets: ["CompactSlider"])
    ],
    targets: [
        .target(
            name: "CompactSlider",
            resources: [.process("PrivacyInfo.xcprivacy")]
        )
    ]
)

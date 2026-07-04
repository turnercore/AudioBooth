// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Models",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .watchOS(.v10),
  ],
  products: [
    .library(
      name: "Models",
      targets: ["Models"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.13.1")
  ],
  targets: [
    .target(
      name: "Models",
      dependencies: [
        .product(name: "Logging", package: "swift-log")
      ]
    ),
    .testTarget(
      name: "ModelsTests",
      dependencies: ["Models"]
    ),
  ]
)

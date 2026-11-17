// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "famchat_updater",
  platforms: [
    .macOS("12.0")
  ],
  products: [
    .library(name: "famchat-updater", targets: ["famchat_updater"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
  ],
  targets: [
    .target(
      name: "famchat_updater",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")]
    )
  ]
)

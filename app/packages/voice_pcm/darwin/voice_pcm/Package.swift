// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "voice_pcm",
  platforms: [
    .iOS("15.0"),
    .macOS("12.0"),
  ],
  products: [
    .library(name: "voice-pcm", targets: ["voice_pcm"])
  ],
  targets: [
    .target(name: "voice_pcm")
  ]
)

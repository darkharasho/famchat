// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PreviewCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "PreviewCore", targets: ["PreviewCore"])],
    targets: [
        .target(name: "PreviewCore"),
        .testTarget(name: "PreviewCoreTests", dependencies: ["PreviewCore"], exclude: ["Fixtures"]),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "caffeinate-ui",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "caffeinate-ui", targets: ["CaffeineApp"])
    ],
    targets: [
        .executableTarget(name: "CaffeineApp")
    ]
)

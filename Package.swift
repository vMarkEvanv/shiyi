// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Shiyi",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Shiyi", targets: ["Shiyi"])],
    targets: [
        .executableTarget(name: "Shiyi"),
        .testTarget(name: "ShiyiTests", dependencies: ["Shiyi"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OfflineSpeechWorker", platforms: [.macOS(.v15)],
    products: [.executable(name: "OfflineSpeechWorker", targets: ["OfflineSpeechWorker"])],
    dependencies: [.package(path: "Vendor/argmax-oss-swift")],
    targets: [.executableTarget(name: "OfflineSpeechWorker", dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift")
    ])]
)

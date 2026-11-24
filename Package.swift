// swift-tools-version: 6.2
import PackageDescription

/// Everything the app, its share extension and widgets share: talking to a Ferret server, signing in, the models.
/// Foundation and CryptoKit only, so `swift test` runs on a Mac.
let package = Package(
    name: "FerretKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "FerretKit", targets: ["FerretKit"])],
    targets: [
        .target(name: "FerretKit"),
        .testTarget(name: "FerretKitTests", dependencies: ["FerretKit"]),
    ]
)

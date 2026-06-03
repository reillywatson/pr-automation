// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PRReviewNotifier",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PRReviewNotifier",
            path: "Sources/PRReviewNotifier"
        )
    ]
)

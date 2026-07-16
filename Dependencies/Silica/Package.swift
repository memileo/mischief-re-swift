// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Silica",
    products: [
        .library(
            name: "Silica",
            targets: ["Silica"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/halset/Cairo.git",
            from: "1.3.2"
        ),
        .package(
            url: "https://github.com/PureSwift/FontConfig.git",
            from: "2.0.0"
        )
    ],
    targets: [
        .target(
            name: "Silica",
            dependencies: [
                "Cairo",
                "FontConfig"
            ]
        ),
        .testTarget(
            name: "SilicaTests",
            dependencies: ["Silica"]
        )
    ]
)

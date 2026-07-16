// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "art2png",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "art2png", targets: ["art2png"]),
        .library(name: "ArtRenderLibrary", targets: ["ArtRenderLibrary"]),
    ],
    dependencies: [
        // Add any external dependencies here, all platforms
    ],
    targets: [
        .executableTarget(
            name: "art2png",
            dependencies: ["ArtParser", "ArtRenderLibrary"],
            path: "Sources/art2png",
//            resources: [
//                .process("noise.png")
//            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "Metal"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreGraphics"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreImage"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "AppKit"], .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "ArtParser",
            path: "Sources/ArtParser",
            swiftSettings: [
                .define("ART2PNG_MODULE"),
                .unsafeFlags(["-O", "-whole-module-optimization"], .when(configuration: .release))
            ]
        ),
        // Library target
        .target(
            name: "ArtRenderLibrary",
            dependencies: ["ArtParser"],
            path: "Sources/ArtRenderLibrary",
            sources: ["MetalRenderer.swift", /*"NoiseAtlas.swift", skip procedural noise for now */ "render.swift", "GPExport.swift"],
            resources: [.process("noise.png"),
                        .copy("ArtRenderShaders.metallib"),
            /* ,
                        .process("Textures.xcassets") */],
            linkerSettings: [
                .unsafeFlags(["-framework", "Metal"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreGraphics"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreImage"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "AppKit"], .when(platforms: [.macOS]))
            ]
        ),
    ]
)


#if os(Linux)
package.dependencies.append(contentsOf: [
    //         .package(url: "https://github.com/pureswift/silica.git", branch: "master"),
    //         .package(url: "https://github.com/halset/Silica.git", branch: "master"),
    .package(url: "https://github.com/halset/Cairo.git", from: "1.3.2"),
    .package(path: "Dependencies/Silica"),
    .package(url: "https://github.com/tayloraswift/swift-jpeg.git", from: "2.1.0"),
])

package.targets = package.targets.map { target in
    var target = target
    if target.name == "ArtRenderLibrary" {
        target.dependencies.append(contentsOf: [
            .product(name: "Silica", package: "silica"),
            .product(name: "Cairo", package: "cairo"),
            .product(name: "JPEG", package: "swift-jpeg"),
        ])
    }
    return target
}
#endif

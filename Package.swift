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
        .target(
            name: "ArtRenderLibrary",
            dependencies: ["ArtParser"],
            path: "Sources/ArtRenderLibrary",
            sources: [
                "MetalRenderer.swift",
                "MetalRenderer_Dispatch.swift",
                "MetalRenderer_TextureIO.swift",

                "Renderer.swift",
                "Renderer_Actions.swift",
                "Renderer_CPURaster.swift",
                "Renderer_PasteMerge.swift",
                "Renderer_Replay.swift",
                "Renderer_Resources.swift",
                "Renderer_StrokeGeometry.swift",
                "RendererTypes.swift",
                "PixelBuffers.swift",
                "CGCompat.swift",
                
                // Live Metal view (interactive pan/zoom/rotate preview)
                "LiveViewTransform.swift",
                "LiveFramePacing.swift",
                "LiveRenderedCanvas.swift",
                "LiveRenderCache.swift",
                "MetalRenderer_LiveCompositing.swift",
                "MetalRenderer_LivePresent.swift",
                "Renderer_Live.swift",
                
                "GPExport.swift"
            ],
            resources: [.process("noise.png"),
                        .copy("ArtRenderShaders.metallib"),
            /* ,
                        .process("Textures.xcassets") */],
            linkerSettings: [
                .unsafeFlags(["-framework", "Metal"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreGraphics"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreImage"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "CoreVideo"], .when(platforms: [.macOS])),
                .unsafeFlags(["-framework", "AppKit"], .when(platforms: [.macOS]))
            ]
        ),
        // Tests for the platform-independent parts (live view transform maths).
        // These run on Linux as well as macOS.
        .testTarget(
            name: "ArtRenderLibraryTests",
            dependencies: ["ArtRenderLibrary", "ArtParser"],
            path: "Tests/ArtRenderLibraryTests"
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
    let target = target
    if target.name == "ArtRenderLibrary" {
        target.dependencies.append(contentsOf: [
            .product(name: "Silica", package: "silica"),
            .product(name: "Cairo", package: "cairo"),
            .product(name: "JPEG", package: "swift-jpeg"),
        ])
    }
    if target.name == "ArtRenderLibraryTests" {
        target.dependencies.append(contentsOf: [
            .product(name: "Silica", package: "silica"),
        ])
    }
    return target
}
#endif

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TeleprompterMirror",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "TeleprompterMirror",
            targets: ["TeleprompterMirror"]
        )
    ],
    targets: [
        .target(
            name: "TeleprompterCore"
        ),
        .executableTarget(
            name: "TeleprompterMirror",
            dependencies: ["TeleprompterCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "TeleprompterCoreTests",
            dependencies: ["TeleprompterCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)

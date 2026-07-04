// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenubarNativeControl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MenubarNativeControl", targets: ["MenubarNativeControl"])
    ],
    targets: [
        .executableTarget(
            name: "MenubarNativeControl",
            path: "Sources/MenubarNativeControl",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

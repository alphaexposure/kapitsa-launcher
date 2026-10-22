// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KapitsaLauncher",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        // The icon file is packaged into the .app by Scripts/build-app.zsh, not as a SwiftPM
        // resource: SwiftPM's resource-bundle lookup varies between Swift versions and crashed
        // released builds.
        .executableTarget(name: "KapitsaLauncher", exclude: ["Resources/Kapitsa.icns"]),
        .testTarget(
            name: "KapitsaLauncherTests",
            dependencies: ["KapitsaLauncher"]
        ),
    ]
)

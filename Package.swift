// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMixer",
    platforms: [
        // Core Audio process taps (per-app audio capture) need macOS 14.2+.
        .macOS("14.2")
    ],
    targets: [
        .executableTarget(
            name: "MacMixer",
            path: "Sources/MacMixer",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

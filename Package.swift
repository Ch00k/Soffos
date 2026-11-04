// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Soffos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Soffos", targets: ["Soffos"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Local control of Sonos players over UPnP/SOAP (port 1400).
        .target(name: "SonosKit"),
        // Spotify Web API client with PKCE auth (browse/search/library only;
        // playback goes through the Sonos queue).
        .target(name: "SpotifyKit"),
        .executableTarget(
            name: "Soffos",
            dependencies: ["SonosKit", "SpotifyKit", .product(name: "Sparkle", package: "Sparkle")],
            // build.sh puts Sparkle.framework in the app bundle's Frameworks folder.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SonosKitTests", dependencies: ["SonosKit"]),
        .testTarget(name: "SpotifyKitTests", dependencies: ["SpotifyKit"]),
    ]
)

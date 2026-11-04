// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Soffos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Soffos", targets: ["Soffos"]),
    ],
    targets: [
        // Local control of Sonos players over UPnP/SOAP (port 1400).
        .target(name: "SonosKit"),
        // Spotify Web API client with PKCE auth (browse/search/library only;
        // playback goes through the Sonos queue).
        .target(name: "SpotifyKit"),
        .executableTarget(
            name: "Soffos",
            dependencies: ["SonosKit", "SpotifyKit"]
        ),
        .testTarget(name: "SonosKitTests", dependencies: ["SonosKit"]),
        .testTarget(name: "SpotifyKitTests", dependencies: ["SpotifyKit"]),
    ]
)

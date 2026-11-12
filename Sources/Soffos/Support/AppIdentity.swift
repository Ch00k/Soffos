import Foundation

/// Which copy of the app this is. Release builds are "Soffos"; local builds
/// are "Soffos Dev" with their own bundle ID, so the two keep separate
/// settings, Spotify sign-ins and logs and can run side by side. A bare
/// binary (`swift run`) has no bundle and counts as a dev build.
enum AppIdentity {
    private static let devBundleID = "re.mntw.soffos.dev"
    static let bundleID = Bundle.main.bundleIdentifier ?? devBundleID
    static let isDev = bundleID == devBundleID
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Soffos Dev"

    /// ~/Library/Application Support/<app name>, created on first use.
    static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

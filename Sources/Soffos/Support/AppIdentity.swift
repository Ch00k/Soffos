import Foundation

/// Which copy of the app this is. Release builds are "Soffos"; local builds
/// are "Soffos Dev" with their own bundle ID, so the two keep separate
/// settings, Spotify sign-ins and logs and can run side by side. A bare
/// binary (`swift run`) has no bundle and counts as a dev build.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "re.mntw.soffos.dev"
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Soffos Dev"
}

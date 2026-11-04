import os

/// Logs to the unified log under the app's bundle ID. View with Console.app or
/// `log stream --predicate 'subsystem == "re.mntw.soffos"'` (`re.mntw.soffos.dev`
/// for local builds).
struct AppLog: Sendable {
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "app")

    func info(_ message: String) { logger.notice("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    /// Only kept while someone streams the log with `--level debug`.
    func debug(_ message: @escaping @autoclosure () -> String) { logger.debug("\(message(), privacy: .public)") }
}

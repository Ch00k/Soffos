import os

/// Logs to the unified log. View with Console.app (subsystem re.mntw.soffos) or
/// `log stream --predicate 'subsystem == "re.mntw.soffos"'`.
struct AppLog: Sendable {
    private let logger = Logger(subsystem: "re.mntw.soffos", category: "app")

    func info(_ message: String) { logger.notice("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    /// Only kept while someone streams the log with `--level debug`.
    func debug(_ message: @escaping @autoclosure () -> String) { logger.debug("\(message(), privacy: .public)") }
}

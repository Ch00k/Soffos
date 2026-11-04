import AppKit
import SwiftUI

@main
struct SoffosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var sonos: SonosStore
    @State private var spotify: SpotifyStore

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 256 << 20)
        let settings = AppSettings()
        let log = AppLog()
        _settings = State(initialValue: settings)
        _sonos = State(initialValue: SonosStore(settings: settings, log: log))
        _spotify = State(initialValue: SpotifyStore(settings: settings, log: log))
    }

    var body: some Scene {
        Window("Soffos", id: "main") {
            RootView()
                .environment(settings)
                .environment(sonos)
                .environment(spotify)
                .task {
                    let sonos = sonos
                    appDelegate.beforeQuit = { await sonos.unsubscribeAll() }
                    sonos.start()
                    await spotify.restore()
                }
        }
        .defaultSize(width: 600, height: 720)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(sonos)
                .environment(spotify)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Cleanup to run before quitting (cancelling Sonos event subscriptions).
    @MainActor var beforeQuit: (@Sendable @MainActor () async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeQuit else { return .terminateNow }
        self.beforeQuit = nil
        Task { @MainActor in
            // Don't let an unreachable speaker hold up quitting.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await beforeQuit() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (`swift run`) instead of the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

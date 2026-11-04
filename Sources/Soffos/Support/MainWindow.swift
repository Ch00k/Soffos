import AppKit
import Observation
import SwiftUI

/// Shows and hides the sidebar and queue by growing or shrinking the window
/// (the sidebar to the left, the queue to the right), so the main pane keeps
/// its size instead of being squeezed.
@Observable
@MainActor
final class MainWindow {
    enum Panel {
        case sidebar, queue

        var defaultsKey: String { self == .sidebar ? "showSidebar" : "showQueue" }
    }

    /// Both panels share one width.
    static let panelWidth: CGFloat = 260
    static let animationDuration: TimeInterval = 0.25

    /// Which panels are open is remembered across launches; the window frame,
    /// which includes the open panels' width, is restored by AppKit.
    private(set) var showSidebar = UserDefaults.standard.bool(forKey: Panel.sidebar.defaultsKey)
    private(set) var showQueue = UserDefaults.standard.bool(forKey: Panel.queue.defaultsKey)
    /// Set while a panel animates: the main pane keeps this width and the
    /// panel takes whatever width the window has.
    private(set) var frozenMainWidth: CGFloat?
    private(set) var animating: Panel?

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private let closeToDock = CloseToDock()

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        closeToDock.install(on: window)
        // Restores the saved frame now and saves it on every move and resize.
        window.setFrameAutosaveName("Main")

        // The accessory stays at the window's right edge, after the
        // toolbar's search field, and never moves into the overflow menu.
        let queueToggle = NSHostingView(rootView: QueueToggle(window: self))
        queueToggle.frame.size = queueToggle.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = queueToggle
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// The narrowest the main pane may be: wide enough for the toolbar to
    /// show every item while a search field is focused and expanded (636
    /// measured on Playlists and Liked Songs), so nothing moves into the
    /// overflow menu.
    static let mainMinimumWidth: CGFloat = 640

    /// The narrowest the window may be: the main pane plus the open panels.
    /// A panel that's animating doesn't count yet (opening) or any more
    /// (closing), otherwise AppKit snaps the window to the new minimum
    /// before the animation can run.
    var minimumWidth: CGFloat {
        let sidebar = showSidebar && animating != .sidebar ? Self.panelWidth : 0
        let queue = showQueue && animating != .queue ? Self.panelWidth : 0
        return Self.mainMinimumWidth + sidebar + queue
    }

    /// Panel and main pane widths for a given total width.
    func layout(totalWidth: CGFloat) -> (sidebar: CGFloat, main: CGFloat, queue: CGFloat) {
        let w = Self.panelWidth
        if let main = frozenMainWidth, let animating {
            let other = animating == .sidebar ? (showQueue ? w : 0) : (showSidebar ? w : 0)
            let moving = max(0, totalWidth - main - other)
            return animating == .sidebar ? (moving, main, other) : (other, main, moving)
        }
        let sidebar = showSidebar ? w : 0
        let queue = showQueue ? w : 0
        return (sidebar, max(0, totalWidth - sidebar - queue), queue)
    }

    func toggle(_ panel: Panel) {
        guard animating == nil else { return }
        let opening = panel == .sidebar ? !showSidebar : !showQueue

        // In full screen (or without a window yet) the window can't grow, so
        // the panel simply takes space from the main pane.
        guard let window, !window.styleMask.contains(.fullScreen) else {
            set(panel, visible: opening)
            return
        }

        let delta = Self.panelWidth * (opening ? 1 : -1)
        var frame = window.frame
        frame.size.width += delta
        if panel == .sidebar { frame.origin.x -= delta }
        if let screen = window.screen?.visibleFrame {
            if frame.maxX > screen.maxX { frame.origin.x = screen.maxX - frame.width }
            if frame.minX < screen.minX { frame.origin.x = screen.minX }
        }

        frozenMainWidth = layout(totalWidth: window.frame.width).main
        animating = panel
        if opening { set(panel, visible: true) }
        Task {
            await animateFrame(window, to: frame)
            if !opening { set(panel, visible: false) }
            animating = nil
            frozenMainWidth = nil
        }
    }

    private func set(_ panel: Panel, visible: Bool) {
        switch panel {
        case .sidebar: showSidebar = visible
        case .queue: showQueue = visible
        }

        UserDefaults.standard.set(visible, forKey: panel.defaultsKey)
    }

    /// Moves and resizes the window together, frame by frame. AppKit's own
    /// window animation applies the origin change separately from the size
    /// change, which makes the main pane jump sideways when the sidebar opens.
    private func animateFrame(_ window: NSWindow, to target: NSRect) async {
        let start = window.frame
        let began = Date()
        while true {
            let t = min(1, Date().timeIntervalSince(began) / Self.animationDuration)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // ease in-out
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * eased).rounded() }
            window.setFrame(NSRect(x: lerp(start.minX, target.minX), y: lerp(start.minY, target.minY),
                                   width: lerp(start.width, target.width), height: lerp(start.height, target.height)),
                            display: true)
            if t >= 1 { return }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}

/// Makes the window's close button minimize to the Dock instead of closing
/// (closing the last window would quit the app). Clicking the Dock icon
/// brings the window back.
@MainActor
private final class CloseToDock: NSObject {
    private weak var window: NSWindow?

    func install(on window: NSWindow) {
        self.window = window
        guard let button = window.standardWindowButton(.closeButton) else { return }
        button.target = self
        button.action = #selector(minimize(_:))
    }

    @objc private func minimize(_ sender: Any?) {
        window?.miniaturize(sender)
    }
}

/// Hands the hosting NSWindow to `MainWindow`.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}

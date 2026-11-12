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
    /// Each toggle's accessory view and the width of its button.
    @ObservationIgnored private var toggles: [Panel: (view: NSView, buttonWidth: CGFloat)] = [:]
    @ObservationIgnored private var resizeObserver: NSObjectProtocol?
    @ObservationIgnored private var toolbarObserver: NSObjectProtocol?
    @ObservationIgnored private var toolbarInstallObserver: NSKeyValueObservation?

    /// The toolbar search fields' width. AppKit would otherwise resize them
    /// as the window resizes, so they wobble while a panel animates. Fits
    /// Liked Songs (the longest title with a search field) at the minimum
    /// width with both panels closed, focused or not; 238 pushes its refresh
    /// button into the overflow menu.
    static let searchFieldWidth: CGFloat = 230

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        closeToDock.install(on: window)
        // Restores the saved frame now and saves it on every move and resize.
        window.setFrameAutosaveName("Main")

        // The toggles are title bar accessories pinned to the window's
        // edges, so toolbar items (back button, search field) never move
        // them or push them into the overflow menu. Each accessory spans its
        // open panel, which keeps the toolbar items above the main pane.
        addToggle(.sidebar, at: .left, to: window)
        addToggle(.queue, at: .right, to: window)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateToggleWidths() }
        }
        // The accessories' positions are known only after the title bar's
        // first layout, and they move when SwiftUI installs the toolbar,
        // which can happen after that.
        DispatchQueue.main.async { [weak self] in self?.updateToggleWidths() }
        watchSearchFields(in: window.toolbar)
        toolbarInstallObserver = window.observe(\.toolbar) { [weak self] window, _ in
            MainActor.assumeIsolated {
                window.layoutIfNeeded()
                self?.updateToggleWidths()
                self?.watchSearchFields(in: window.toolbar)
            }
        }
    }

    /// Fixes the width of the toolbar's search fields, present and future:
    /// SwiftUI adds a screen's search field to the toolbar when the screen
    /// appears.
    private func watchSearchFields(in toolbar: NSToolbar?) {
        if let toolbarObserver { NotificationCenter.default.removeObserver(toolbarObserver) }
        toolbarObserver = nil
        guard let toolbar else { return }

        toolbar.items.forEach(Self.fixSearchFieldWidth)
        toolbarObserver = NotificationCenter.default.addObserver(
            forName: NSToolbar.willAddItemNotification, object: toolbar, queue: .main
        ) { note in
            guard let item = note.userInfo?["item"] as? NSToolbarItem else { return }
            MainActor.assumeIsolated { Self.fixSearchFieldWidth(item) }
        }
    }

    private static func fixSearchFieldWidth(_ item: NSToolbarItem) {
        guard let field = (item as? NSSearchToolbarItem)?.searchField else { return }
        field.widthAnchor.constraint(equalToConstant: searchFieldWidth).isActive = true
    }

    private func addToggle(_ panel: Panel, at edge: NSLayoutConstraint.Attribute, to window: NSWindow) {
        let toggle = NSHostingView(rootView: PanelToggle(panel: panel, window: self))
        toggle.frame.size = toggle.fittingSize
        // From here on `updateToggleWidths` sets the size. Without sizing
        // options `fittingSize` is zero, so the button's width is kept.
        toggle.sizingOptions = []
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = edge
        accessory.view = toggle
        window.addTitlebarAccessoryViewController(accessory)
        toggles[panel] = (toggle, toggle.frame.width)
    }

    /// Widens each toggle's accessory to reach the inner edge of its panel
    /// at the given window width (the current one by default). The accessory
    /// starts a little in from the window edge (past the traffic lights on
    /// the left), so that inset, measured at the current width, is
    /// subtracted.
    private func updateToggleWidths(windowWidth: CGFloat? = nil) {
        guard let window else { return }
        let widths = layout(totalWidth: windowWidth ?? window.frame.width)
        for (panel, toggle) in toggles {
            let frame = toggle.view.convert(toggle.view.bounds, to: nil)
            let inset = panel == .sidebar ? frame.minX : window.frame.width - frame.maxX
            let panelWidth = panel == .sidebar ? widths.sidebar : widths.queue
            toggle.view.frame.size.width = max(toggle.buttonWidth, panelWidth - inset)
        }
    }

    /// The narrowest the main pane may be: wide enough for the toolbar to
    /// show every item, so nothing moves into the overflow menu. With both
    /// panels closed the toggles take part of it, which `searchFieldWidth`
    /// allows for.
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
            updateToggleWidths()
        }
    }

    private func set(_ panel: Panel, visible: Bool) {
        switch panel {
        case .sidebar: showSidebar = visible
        case .queue: showQueue = visible
        }

        UserDefaults.standard.set(visible, forKey: panel.defaultsKey)
        updateToggleWidths()
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
            let frame = NSRect(x: lerp(start.minX, target.minX), y: lerp(start.minY, target.minY),
                               width: lerp(start.width, target.width), height: lerp(start.height, target.height))
            // Sized before the frame changes so the title bar is drawn with
            // the new widths in the same step as the window.
            updateToggleWidths(windowWidth: frame.width)
            window.setFrame(frame, display: true)
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

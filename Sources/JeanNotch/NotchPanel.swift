import AppKit
import os
import SwiftUI

private let panelLog = Logger(subsystem: "build.jean.notch", category: "panel")

/// Size of the hardware notch, or of the pill drawn on screens without one.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    /// Picks the built-in notched screen, else the primary screen.
    static func current() -> (NSScreen, NotchGeometry)? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return (screen, NotchGeometry(width: width, height: screen.safeAreaInsets.top, hasNotch: true))
        }
        guard let screen = NSScreen.screens.first else { return nil }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return (screen, NotchGeometry(width: 0, height: max(menuBar, 24), hasNotch: false))
    }
}

/// Borderless, non-activating panel pinned to the top center of the screen.
/// It never becomes key or main, so the frontmost app keeps focus.
final class NotchPanel: NSPanel {
    private var screenFrame = NSRect.zero

    init<Content: View>(rootView: Content, onHover: @escaping (Bool) -> Void, onRightClick: @escaping (NSEvent, NSView) -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true  // sets level to .floating, so set level after it
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear

        let host = HoverHostingView(rootView: rootView)
        host.sizingOptions = []  // the panel sizes itself from the SwiftUI size report
        host.onHover = onHover
        host.onRightClick = onRightClick
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit pushes windows below the menu bar; the panel must sit over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func place(on screen: NSScreen) {
        screenFrame = screen.frame
        resize(to: frame.size)
    }

    /// Keeps the panel top-centered on its screen at the SwiftUI content size.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, screenFrame != .zero else { return }
        let origin = NSPoint(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
        panelLog.debug("Panel frame \(NSStringFromRect(self.frame), privacy: .public)")
    }

    var containsMouse: Bool { frame.contains(NSEvent.mouseLocation) }
}

/// Reports hover with an always-active tracking area (the panel is never key)
/// and accepts the first click so rows respond without activating the app.
private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event, self)
    }
}

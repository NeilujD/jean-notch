import AppKit
import JeanNotchCore
import os
import ServiceManagement
import SwiftUI

private let appLog = Logger(subsystem: "build.jean.notch", category: "app")
private let jeanBundleId = "com.jean.desktop"
private let mutedKey = "muted"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let panelState = PanelState()
    private var panel: NotchPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = NotchActions(
            open: { [weak self] in self?.open($0) },
            showMenu: { [weak self] in self?.showMenu(event: nil, in: nil) },
            sizeChanged: { [weak self] in self?.panel.resize(to: $0) }
        )
        panel = NotchPanel(
            rootView: NotchView(store: store, panel: panelState, actions: actions),
            onHover: { [weak self] in self?.panelState.setHovering($0) },
            onRightClick: { [weak self] event, view in self?.showMenu(event: event, in: view) }
        )
        placePanel()
        panel.orderFrontRegardless()

        store.onAlert = { [weak self] in self?.alert($0) }
        store.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == jeanBundleId else { return }
            MainActor.assumeIsolated { self?.store.markAllSeen() }
        }
    }

    private func placePanel() {
        guard let (screen, geometry) = NotchGeometry.current() else { return }
        panelState.geometry = geometry
        panel.place(on: screen)
        appLog.info("Placed on \(screen.localizedName, privacy: .public): notch \(geometry.hasNotch) \(Int(geometry.width))x\(Int(geometry.height))")
    }

    // MARK: Alerts

    private var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }

    private func alert(_ session: SessionState) {
        panelState.alert()
        guard !muted else { return }
        let sound = switch session.status {
        case .failed: "Funk"
        case .waiting: "Glass"
        default: "Tink"
        }
        NSSound(named: sound)?.play()
    }

    // MARK: Jump to Jean

    /// Brings Jean to the front, then asks it to select the session (best effort).
    private func open(_ session: SessionState) {
        store.markSeen(session.id)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: jeanBundleId) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { appLog.error("Cannot open Jean: \(error.localizedDescription, privacy: .public)") }
            }
        } else {
            appLog.error("Jean (\(jeanBundleId, privacy: .public)) is not installed")
        }
        Task { await store.selectInJean(session) }
    }

    // MARK: Menu

    private func showMenu(event: NSEvent?, in view: NSView?) {
        let menu = NSMenu()
        let mute = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute), keyEquivalent: "")
        mute.state = muted ? .on : .off
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSMenuItem(title: "Quit JeanNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in [mute, login] { item.target = self }
        menu.items = [mute, login, .separator(), quit]

        if let event, let view {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        // Menu tracking can swallow the exit event; resync hover with the pointer.
        panelState.setHovering(panel.containsMouse)
    }

    @objc private func toggleMute() {
        muted.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            appLog.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

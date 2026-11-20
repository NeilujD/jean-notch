import AppKit
import JeanNotchCore
import os
import ServiceManagement
import SwiftUI

private let appLog = Logger(subsystem: "build.jean.notch", category: "app")
private let jeanBundleId = "com.jean.desktop"
private let mutedKey = "muted"

/// A limit that turns something orange once passed, stored in UserDefaults. 0 turns it off.
/// Any value works: `defaults write build.jean.notch tokenWarning -int 3000000`.
struct WarningLimit: Sendable {
    let key: String
    let defaultValue: Int
    let presets: [Int]
    let title: String
    /// "10 million tokens", "80% used".
    let label: @Sendable (Int) -> String

    /// A session row's token total.
    static let tokens = WarningLimit(
        key: "tokenWarning", defaultValue: 10_000_000,
        presets: [1_000_000, 5_000_000, 10_000_000, 20_000_000, 50_000_000],
        title: "Token Warning",
        label: { value in
            let amount = value % 1_000_000 == 0 ? "\(value / 1_000_000) million" : value.formatted()
            return "\(amount) tokens"
        }
    )

    /// The tightest plan limit of any provider, in percent.
    static let usage = WarningLimit(
        key: "usageWarning", defaultValue: 80, presets: [50, 70, 80, 90, 95],
        title: "Usage Warning", label: { "\($0)% used" }
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let panelState = PanelState()
    private var panel: NotchPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Dictionary(uniqueKeysWithValues:
            [WarningLimit.tokens, .usage].map { ($0.key, $0.defaultValue) }))
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
        applyExperimental()
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
        if session.status == .done { panelState.celebrate() }
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
        let limits = [WarningLimit.tokens, .usage].map { limit in
            let item = NSMenuItem(title: limit.title, action: nil, keyEquivalent: "")
            item.submenu = warningMenu(limit)
            return item
        }
        let experimental = NSMenuItem(title: "Experimental", action: nil, keyEquivalent: "")
        experimental.submenu = experimentalMenu()
        menu.items = [mute, login] + limits + [experimental, .separator(), quit]

        if let event, let view {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        // Menu tracking can swallow the exit event; resync hover with the pointer.
        panelState.setHovering(panel.containsMouse)
    }

    private func warningMenu(_ limit: WarningLimit) -> NSMenu {
        let current = UserDefaults.standard.integer(forKey: limit.key)
        let menu = NSMenu()
        for value in [0] + limit.presets {
            let item = NSMenuItem(
                title: value == 0 ? "Off" : "Over \(limit.label(value))",
                action: #selector(setWarning(_:)), keyEquivalent: ""
            )
            item.tag = value
            item.representedObject = limit.key
            item.target = self
            item.state = value == current ? .on : .off
            menu.addItem(item)
        }
        if current > 0, !limit.presets.contains(current) {
            let custom = NSMenuItem(title: "Over \(limit.label(current)) (custom)", action: nil, keyEquivalent: "")
            custom.state = .on
            menu.addItem(custom)
        }
        return menu
    }

    private func experimentalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: ExperimentalFeature.notice))
        for feature in ExperimentalFeature.allCases {
            let item = NSMenuItem(title: feature.title, action: #selector(toggleExperimental(_:)), keyEquivalent: "")
            item.representedObject = feature.rawValue
            item.target = self
            item.state = feature.isOn ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleExperimental(_ sender: NSMenuItem) {
        guard let feature = (sender.representedObject as? String).flatMap(ExperimentalFeature.init) else { return }
        feature.isOn.toggle()
        applyExperimental()
    }

    private func applyExperimental() {
        store.answersQuestions = ExperimentalFeature.answerQuestions.isOn
        store.approvesPlans = ExperimentalFeature.approvePlans.isOn
    }

    @objc private func setWarning(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(sender.tag, forKey: key)
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

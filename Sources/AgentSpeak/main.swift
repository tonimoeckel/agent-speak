import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        HookInstaller.autoUpdateScript()

        let state = AppState.shared
        state.start()
        overlay = OverlayController(state: state)
        statusItem = StatusItemController(state: state)

        // Erster Start: Einrichtung zeigen
        if !state.hookRegistered || !state.scriptInstalled {
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// Ohne Hauptmenü funktionieren ⌘C/⌘V in Textfeldern nicht (z. B. API-Key einfügen).
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Einstellungen …", "Settings …"), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Agent Speak beenden", "Quit Agent Speak"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Bearbeiten", "Edit"))
        edit.addItem(withTitle: tr("Ausschneiden", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Kopieren", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Einsetzen", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Alles auswählen", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: tr("Fenster", "Window"))
        win.addItem(withTitle: tr("Schließen", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        return main
    }

    @objc func openSettings() { SettingsWindowController.shared.show() }
}

// MARK: - Menüleiste

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        updateIcon()
    }

    private func updateIcon() {
        let name: String
        if !state.enabled { name = "speaker.slash" }
        else if state.speaking { name = "speaker.wave.3.fill" }
        else if state.summarizing { name = "ellipsis.bubble" }
        else { name = "speaker.wave.2" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Agent Speak")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = menu.addItem(withTitle: tr("Ruhe – alles stumm", "Mute all sessions"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = state.enabled ? .off : .on
        let stop = menu.addItem(withTitle: tr("Ansage stoppen", "Stop speaking"), action: state.speaking ? #selector(stopPlayback) : nil, keyEquivalent: "")
        stop.isEnabled = state.speaking
        menu.addItem(withTitle: tr("Letzte Ansage wiederholen", "Repeat last summary"), action: state.hasLastText ? #selector(replay) : nil, keyEquivalent: "")
        menu.addItem(.separator())
        let sessionsItem = menu.addItem(withTitle: tr("Sessions", "Sessions"), action: nil, keyEquivalent: "")
        sessionsItem.submenu = sessionsMenu()
        menu.addItem(.separator())
        let overlay = menu.addItem(withTitle: tr("Overlay anzeigen", "Show overlay"), action: #selector(toggleOverlay), keyEquivalent: "")
        overlay.state = state.showOverlay ? .on : .off
        menu.addItem(withTitle: tr("Einstellungen …", "Settings …"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Agent Speak beenden", "Quit Agent Speak"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
    }

    // MARK: Sessions

    private func sessionsMenu() -> NSMenu {
        let m = NSMenu()
        let recent = state.recentSessions
        if recent.isEmpty {
            m.addItem(withTitle: tr("Noch keine Sessions", "No sessions yet"), action: nil, keyEquivalent: "").isEnabled = false
            return m
        }
        for s in recent {
            let item = m.addItem(withTitle: (s.pending ? "● " : "") + s.title(maxLabel: 40), action: nil, keyEquivalent: "")
            item.state = state.isOn(s) ? .on : .off
            item.submenu = sessionSubmenu(s)
        }
        return m
    }

    private func sessionSubmenu(_ s: SessionInfo) -> NSMenu {
        let m = NSMenu()
        let locked = s.lockedValue != nil
        let read = m.addItem(withTitle: tr("Diese Session vorlesen", "Read this session aloud") + (locked ? " (AGENT_SPEAK)" : ""),
                             action: locked ? nil : #selector(toggleSessionItem(_:)), keyEquivalent: "")
        read.state = state.isOn(s) ? .on : .off
        read.representedObject = s.id
        read.target = self
        if s.pending {
            let p = m.addItem(withTitle: tr("Ungehörte Antwort vorlesen", "Read unheard reply aloud"),
                              action: #selector(speakPendingItem(_:)), keyEquivalent: "")
            p.representedObject = s.id
            p.target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: tr("Projekt „\(s.project)“:", "Project “\(s.project)”:"), action: nil, keyEquivalent: "").isEnabled = false
        let current = state.rules.projects[s.root]
        let std = state.newSessionsOn ? tr("vorlesen", "read aloud") : tr("stumm", "muted")
        for (title, value) in [(tr("Immer vorlesen", "Always read aloud"), "on"),
                               (tr("Immer stumm", "Always muted"), "off"),
                               (tr("Standard (\(std))", "Default (\(std))"), "")] {
            let i = m.addItem(withTitle: title, action: #selector(setProjectItem(_:)), keyEquivalent: "")
            i.state = (current ?? "") == value ? .on : .off
            i.representedObject = [s.root, value]
            i.target = self
            i.indentationLevel = 1
        }
        return m
    }

    private func session(_ sender: NSMenuItem) -> SessionInfo? {
        guard let id = sender.representedObject as? String else { return nil }
        return state.sessions.first { $0.id == id }
    }

    @objc private func toggleSessionItem(_ sender: NSMenuItem) { if let s = session(sender) { state.toggleSession(s) } }
    @objc private func speakPendingItem(_ sender: NSMenuItem) { if let s = session(sender) { state.speakPending(s) } }
    @objc private func setProjectItem(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], v.count == 2 else { return }
        state.setProject(v[0], on: v[1].isEmpty ? nil : v[1] == "on")
    }

    @objc private func toggleEnabled() { state.toggleEnabled() }
    @objc private func stopPlayback() { state.stopPlayback() }
    @objc private func replay() { state.replay() }
    @objc private func toggleOverlay() { state.showOverlay.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
}

// MARK: - Start

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        app.setActivationPolicy(.accessory)
        Snapshot.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

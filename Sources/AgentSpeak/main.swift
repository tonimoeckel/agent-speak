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
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Einstellungen …", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Agent Speak beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Fenster")
        win.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        let toggle = menu.addItem(withTitle: "Vorlesen aktiv", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = state.enabled ? .on : .off
        let stop = menu.addItem(withTitle: "Ansage stoppen", action: state.speaking ? #selector(stopPlayback) : nil, keyEquivalent: "")
        stop.isEnabled = state.speaking
        menu.addItem(withTitle: "Letzte Ansage wiederholen", action: state.hasLastText ? #selector(replay) : nil, keyEquivalent: "")
        menu.addItem(.separator())
        let overlay = menu.addItem(withTitle: "Overlay anzeigen", action: #selector(toggleOverlay), keyEquivalent: "")
        overlay.state = state.showOverlay ? .on : .off
        menu.addItem(withTitle: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Agent Speak beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
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

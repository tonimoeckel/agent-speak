import AppKit
import SwiftUI

/// Entwickler-Hilfe: `AgentSpeak --snapshot <ordner>` rendert Overlay und Einstellungen als PNG
/// (für README-Screenshots und zum Prüfen des Layouts ohne Bildschirmaufnahme).
@MainActor
enum Snapshot {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState.shared
        state.refresh()

        let collapsed = OverlayModel()
        write(OverlayView(model: collapsed, state: state) { _ in }.background(Color(white: 0.55)),
              size: OverlayController.collapsedSize, to: dir.appendingPathComponent("overlay-collapsed.png"))

        let expanded = OverlayModel()
        expanded.expanded = true
        expanded.hovered = .toggle
        write(OverlayView(model: expanded, state: state) { _ in }.background(Color(white: 0.55)),
              size: OverlayController.expandedSize, to: dir.appendingPathComponent("overlay-expanded.png"))

        // Beispiel-Sessions für Session-Zeile und Liste
        let now = Date().timeIntervalSince1970
        func sample(_ id: String, _ project: String, _ label: String, _ ago: Double, pending: Bool = false, locked: String = "") -> SessionInfo {
            SessionInfo(id: id, cwd: "/Users/dev/\(project)", root: "/Users/dev/\(project)", project: project, label: label,
                        lastSeen: now - ago, pending: pending, locked: locked)
        }
        let realSessions = state.sessions, realRules = state.rules, realUnheard = state.unheard
        state.injectForSnapshot(sessions: [
            sample("a", "billing-api", "Migriere die Rechnungs-Tabelle auf das neue Schema", 40, pending: true),
            sample("b", "agent-speak", "Mehrsprachigkeit für die App einbauen", 300),
            sample("c", "infra", "Terraform-Plan für Staging prüfen", 1800, locked: "off"),
            sample("d", "website", "Landingpage-Texte überarbeiten", 7200),
        ], rules: SessionRules(sessions: ["a": "off"], projects: ["/Users/dev/website": "off"]), unheard: true)

        // Texte in beiden Sprachen (Dateien mit Suffix -de / -en)
        let saved = L10n.lang
        for lang in [Lang.de, .en] {
            L10n.lang = lang
            let suffix = "-\(lang.rawValue).png"
            // Längster Tooltip – darf die Button-Spalte nicht verschieben
            let gear = OverlayModel()
            gear.expanded = true
            gear.hovered = .settings
            write(OverlayView(model: gear, state: state) { _ in }.background(Color(white: 0.55)),
                  size: OverlayController.expandedSize, to: dir.appendingPathComponent("overlay-settings-hover" + suffix))

            let hoverSession = OverlayModel()
            hoverSession.expanded = true
            hoverSession.hovered = .session
            write(OverlayView(model: hoverSession, state: state) { _ in }.background(Color(white: 0.55)),
                  size: OverlayController.expandedSize, to: dir.appendingPathComponent("overlay-session-hover" + suffix))

            let list = OverlayModel()
            list.expanded = true
            list.listOpen = true
            write(OverlayView(model: list, state: state) { _ in }.background(Color(white: 0.55)),
                  size: OverlayController.listSize, to: dir.appendingPathComponent("overlay-list" + suffix))

            write(SettingsView(model: SettingsModel(), state: state),
                  size: NSSize(width: 540, height: 720), to: dir.appendingPathComponent("settings" + suffix))
        }
        L10n.lang = saved

        // Eingeklappt mit Punkt für Ungehörtes
        write(OverlayView(model: OverlayModel(), state: state) { _ in }.background(Color(white: 0.55)),
              size: OverlayController.collapsedSize, to: dir.appendingPathComponent("overlay-collapsed-unheard.png"))
        state.injectForSnapshot(sessions: realSessions, rules: realRules, unheard: realUnheard)
    }

    private static func write<V: View>(_ view: V, size: NSSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

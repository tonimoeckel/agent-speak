import AppKit
import Combine
import ServiceManagement

enum OverlaySide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? tr("Links", "Left") : tr("Rechts", "Right") }
}

/// Zentrale Zustandsquelle. Der Hook kommuniziert über Dateien in ~/.claude/hooks/speak-summary,
/// die App liest sie regelmäßig und schreibt `muted` / `config`.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var enabled = true
    @Published private(set) var speaking = false
    @Published private(set) var summarizing = false
    @Published private(set) var hookRegistered = false
    @Published private(set) var scriptInstalled = false

    // Session-Steuerung (Sessions.swift)
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var rules = SessionRules()
    @Published private(set) var unheard = false
    @Published private(set) var newSessionsOn = true
    private var stamps: [FileStamp] = []

    @Published var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "showOverlay") }
    }
    @Published var overlaySide: OverlaySide {
        didSet { UserDefaults.standard.set(overlaySide.rawValue, forKey: "overlaySide") }
    }

    /// Vertikale Position des Overlays (0 = unten, 1 = oben), per Drag & Drop gesetzt.
    @Published var overlayY: Double {
        didSet { UserDefaults.standard.set(overlayY, forKey: "overlayY") }
    }

    var busy: Bool { speaking || summarizing }

    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        showOverlay = d.object(forKey: "showOverlay") as? Bool ?? true
        overlaySide = OverlaySide(rawValue: d.string(forKey: "overlaySide") ?? "") ?? .left
        overlayY = d.object(forKey: "overlayY") as? Double ?? 0.5
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { AppState.shared.refresh() }
        }
    }

    func refresh() {
        set(\.enabled, !Paths.exists(Paths.muted))
        set(\.speaking, Self.playerAlive())
        set(\.summarizing, Self.summarizingFresh())
        set(\.hookRegistered, HookInstaller.isRegistered())
        set(\.scriptInstalled, Paths.exists(Paths.script))
        set(\.unheard, Paths.exists(Paths.unheard))
        reloadSessions()
    }

    /// Liest Sessions, Regeln und Standard nur neu, wenn sich eine der Dateien geändert hat.
    func reloadSessions(force: Bool = false) {
        let now = [FileStamp(Paths.sessionsDir), FileStamp(Paths.rules), FileStamp(Paths.config)]
        guard force || now != stamps else { return }
        stamps = now
        let list = SessionFiles.loadAll()
        if list != sessions { sessions = list }
        var r = SessionRules.load()
        // Session-Ausnahmen verfallen mit ihrer Session (der Hook räumt Sessions nach 7 Tagen auf)
        let known = Set(list.map(\.id))
        if Paths.exists(Paths.sessionsDir), r.sessions.keys.contains(where: { !known.contains($0) }) {
            r.sessions = r.sessions.filter { known.contains($0.key) }
            try? r.save()
            stamps = [FileStamp(Paths.sessionsDir), FileStamp(Paths.rules), FileStamp(Paths.config)]
        }
        if r != rules { rules = r }
        set(\.newSessionsOn, HookConfig.load().newSessions != "off")
    }

    private func set(_ kp: ReferenceWritableKeyPath<AppState, Bool>, _ value: Bool) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }

    /// Nur für `--snapshot`: Beispiel-Sessions statt echter Daten.
    func injectForSnapshot(sessions: [SessionInfo], rules: SessionRules, unheard: Bool) {
        self.sessions = sessions
        self.rules = rules
        self.unheard = unheard
        stamps = [FileStamp(Paths.sessionsDir), FileStamp(Paths.rules), FileStamp(Paths.config)]
    }

    // MARK: Aktionen

    func setEnabled(_ on: Bool) {
        try? FileManager.default.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
        if on {
            try? FileManager.default.removeItem(at: Paths.muted)
        } else {
            FileManager.default.createFile(atPath: Paths.muted.path, contents: nil)
            stopPlayback()
        }
        refresh()
    }

    func toggleEnabled() { setEnabled(!enabled) }

    func stopPlayback() {
        if let s = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
           let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: Paths.pidFile)
        refresh()
    }

    var hasLastText: Bool { Paths.exists(Paths.lastText) }

    func replay() {
        guard Paths.exists(Paths.script) else { return }
        Shell.spawn(Paths.script.path, ["--replay"])
    }

    func testAnnouncement() {
        guard Paths.exists(Paths.script) else { return }
        Shell.spawn(Paths.script.path, ["--test"])
    }

    // MARK: Login-Start

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }

    // MARK: Statusdateien

    private static func playerAlive() -> Bool {
        guard let s = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    private static func summarizingFresh() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.summarizing.path),
              let date = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < 90   // verwaiste Markierung ignorieren
    }
}

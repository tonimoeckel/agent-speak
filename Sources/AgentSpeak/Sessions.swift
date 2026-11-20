import AppKit
import Foundation

// Session-Steuerung (docs/adr/0001-session-steuerung.md):
// Standard für neue Sessions + Ausnahmen pro Session und Projekt.
// Rangfolge: AGENT_SPEAK → Session-Ausnahme → Projekt-Regel → Standard.

/// Eine Session, wie der Hook sie in sessions/<id>.json ablegt.
struct SessionInfo: Decodable, Identifiable, Equatable {
    let id: String
    let cwd: String
    let root: String
    let project: String
    let label: String
    let lastSeen: Double
    let pending: Bool
    let locked: String?

    var lastSeenDate: Date { Date(timeIntervalSince1970: lastSeen) }
    /// Durch `AGENT_SPEAK` festgelegt (on/off), in der App nicht umschaltbar.
    var lockedValue: Bool? { locked == "on" ? true : locked == "off" ? false : nil }

    /// „agent-speak · Mehrsprachigkeit für …“
    func title(maxLabel: Int = 40) -> String {
        let l = label.count > maxLabel ? String(label.prefix(maxLabel)).trimmingCharacters(in: .whitespaces) + "…" : label
        return l.isEmpty ? project : "\(project) · \(l)"
    }
}

/// rules.json – wird nur von der App geschrieben.
struct SessionRules: Codable, Equatable {
    var sessions: [String: String] = [:]
    var projects: [String: String] = [:]

    static func load() -> SessionRules {
        guard let d = try? Data(contentsOf: Paths.rules),
              let r = try? JSONDecoder().decode(SessionRules.self, from: d) else { return SessionRules() }
        return r
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: Paths.rules, options: .atomic)
    }

    /// Passende Projekt-Regel: Projekt selbst, Startordner oder ein übergeordneter Ordner – längster Pfad gewinnt.
    func projectRule(root: String, cwd: String) -> (path: String, on: Bool)? {
        projects
            .filter { $0.key == root || $0.key == cwd || cwd.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value == "on") }
    }
}

enum SessionRuleSource { case env, session, project, standard }

extension AppState {
    /// Sessions der letzten 24 Stunden, neueste zuerst, höchstens 8.
    var recentSessions: [SessionInfo] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return Array(sessions.filter { $0.lastSeenDate > cutoff }.prefix(8))
    }

    /// Die zuletzt fertig gewordene Session (bezugspunkt der Session-Zeile im Overlay).
    var lastSession: SessionInfo? { recentSessions.first }

    func effective(_ s: SessionInfo) -> (on: Bool, source: SessionRuleSource) {
        if let l = s.lockedValue { return (l, .env) }
        if let r = rules.sessions[s.id] { return (r == "on", .session) }
        return fallback(s)
    }

    /// Was ohne Session-Ausnahme gelten würde.
    func fallback(_ s: SessionInfo) -> (on: Bool, source: SessionRuleSource) {
        if let p = rules.projectRule(root: s.root, cwd: s.cwd) { return (p.on, .project) }
        return (newSessionsOn, .standard)
    }

    func isOn(_ s: SessionInfo) -> Bool { effective(s).on }

    /// Session vorlesen oder stumm schalten. Entspricht der Wunsch ohnehin der Regel darunter,
    /// wird die Ausnahme entfernt, damit die Liste sauber bleibt.
    /// Beim Freigeben wird eine ungehörte Antwort sofort vorgelesen.
    func setSession(_ s: SessionInfo, on: Bool) {
        guard s.lockedValue == nil else { return }
        var r = rules
        r.sessions[s.id] = on == fallback(s).on ? nil : (on ? "on" : "off")
        saveRules(r)
        if on && s.pending { speakPending(s) }
    }

    func toggleSession(_ s: SessionInfo) { setSession(s, on: !isOn(s)) }

    func removeSessionRule(_ id: String) {
        var r = rules
        r.sessions[id] = nil
        saveRules(r)
    }

    /// nil = Projekt-Regel entfernen (es gilt der Standard)
    func setProject(_ path: String, on: Bool?) {
        var r = rules
        r.projects[path] = on.map { $0 ? "on" : "off" }
        saveRules(r)
    }

    func speakPending(_ s: SessionInfo) {
        guard Paths.exists(Paths.script) else { return }
        Shell.spawn(Paths.script.path, ["--speak-session", s.id])
    }

    func clearUnheard() {
        try? FileManager.default.removeItem(at: Paths.unheard)
        refresh()
    }

    /// Ordner auf sein Projekt (Git-Repo samt Worktrees) abbilden – dieselbe Logik wie im Hook.
    static func projectRoot(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let script = [Paths.bundledScript, Paths.script].compactMap({ $0 }).first(where: Paths.exists) else { return path }
        let out = Shell.run("/bin/bash", [script.path, "--project-root", path]).out
        return out.hasPrefix("/") ? out : path
    }

    func saveRules(_ r: SessionRules) {
        do { try r.save() } catch { NSSound.beep() }
        reloadSessions(force: true)
    }
}

/// Merkt sich Änderungszeitpunkte, damit nur bei Änderungen neu gelesen wird.
struct FileStamp: Equatable {
    let date: Date?
    init(_ url: URL) {
        date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

enum SessionFiles {
    static func loadAll() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(SessionInfo.self, from: Data(contentsOf: $0)) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
}

/// Relative Zeitangabe in der eingestellten Sprache („vor 3 Min.“ / „3 min. ago“).
func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: L10n.lang.rawValue)
    f.unitsStyle = .short
    if Date().timeIntervalSince(date) < 60 { return tr("gerade eben", "just now") }
    return f.localizedString(for: date, relativeTo: Date())
}

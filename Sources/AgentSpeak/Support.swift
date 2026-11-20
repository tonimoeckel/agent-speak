import AppKit
import Foundation
import Security

// MARK: - Pfade

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let hookDir = home.appendingPathComponent(".claude/hooks/speak-summary")
    static let script = hookDir.appendingPathComponent("speak-summary.sh")
    static let config = hookDir.appendingPathComponent("config")
    static let muted = hookDir.appendingPathComponent("muted")
    static let pidFile = hookDir.appendingPathComponent("player.pid")
    static let summarizing = hookDir.appendingPathComponent("summarizing")
    static let lastText = hookDir.appendingPathComponent("last.txt")
    static let prompt = hookDir.appendingPathComponent("prompt.txt")
    static let log = hookDir.appendingPathComponent("last.log")
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    static var bundledScript: URL? { Bundle.main.url(forResource: "speak-summary", withExtension: "sh") }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

// MARK: - Shell

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(Paths.home.path)/.local/bin", "\(Paths.home.path)/.claude/local",
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], stdin: String? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)); try? inPipe.fileHandleForWriting.close() }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      err: String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Startet einen Prozess im Hintergrund, ohne auf ihn zu warten.
    static func spawn(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func findClaude() -> String? {
        let h = Paths.home.path
        let candidates = ["\(h)/.local/bin/claude", "\(h)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(h)/.npm-global/bin/claude", "\(h)/.bun/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // Fallback: Login-Shell des Users fragen (nvm, asdf, …)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let r = run(shell, ["-lc", "command -v claude"])
        return r.out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") })
    }

    static func findJQ() -> String? {
        ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Hook-Konfiguration (Shell-Datei, wird vom Skript per `source` gelesen)

struct HookConfig: Equatable {
    var language = "system"
    var ttsEngine = "auto"
    var voiceID = ""
    var voiceName = ""
    var elevenModel = "eleven_flash_v2_5"
    var elevenSpeed = 1.0
    var sayVoice = "Anna"
    var sayRate = 190
    var summaryModel = "haiku"
    var summaryLength = "normal"
    var claudeBin = ""

    static func load() -> HookConfig {
        var c = HookConfig()
        guard let text = try? String(contentsOf: Paths.config, encoding: .utf8) else { return c }
        var v: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            v[String(line[..<eq])] = unquote(String(line[line.index(after: eq)...]))
        }
        c.language = v["SPEAK_LANGUAGE"] ?? c.language
        c.ttsEngine = v["TTS_ENGINE"] ?? c.ttsEngine
        c.voiceID = v["ELEVENLABS_VOICE_ID"] ?? c.voiceID
        c.voiceName = v["ELEVENLABS_VOICE_NAME"] ?? c.voiceName
        c.elevenModel = v["ELEVENLABS_MODEL"] ?? c.elevenModel
        c.elevenSpeed = Double(v["ELEVENLABS_SPEED"] ?? "").map { min(max($0, 0.7), 1.2) } ?? c.elevenSpeed
        c.sayVoice = v["SAY_VOICE"] ?? c.sayVoice
        c.sayRate = Int(v["SAY_RATE"] ?? "") ?? c.sayRate
        c.summaryModel = v["SUMMARY_MODEL"] ?? c.summaryModel
        c.summaryLength = v["SUMMARY_LENGTH"] ?? c.summaryLength
        c.claudeBin = v["CLAUDE_BIN"] ?? c.claudeBin
        return c
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
        let q = HookConfig.quote
        let text = """
        # Konfiguration für speak-summary.sh – wird von der Agent-Speak-App geschrieben.
        # Kann auch von Hand bearbeitet werden (Shell-Syntax).

        # Sprache der App und der Ansagen: system | de | en
        SPEAK_LANGUAGE=\(q(language))

        # auto = ElevenLabs, wenn Key + Voice-ID da sind, sonst Systemstimme | elevenlabs | say
        TTS_ENGINE=\(q(ttsEngine))

        # ElevenLabs (der API-Key liegt im macOS-Schlüsselbund, nicht hier)
        ELEVENLABS_VOICE_ID=\(q(voiceID))
        ELEVENLABS_VOICE_NAME=\(q(voiceName))
        ELEVENLABS_MODEL=\(q(elevenModel))
        # Sprechtempo 0.7 … 1.2 (1.0 = Einstellung der Stimme bei ElevenLabs)
        ELEVENLABS_SPEED=\(q(String(format: "%.2f", elevenSpeed)))

        # Systemstimme (say -v '?')
        SAY_VOICE=\(q(sayVoice))
        SAY_RATE=\(q(String(sayRate)))

        # Modell für die Zusammenfassung (läuft über das Claude-Abo via `claude -p`)
        SUMMARY_MODEL=\(q(summaryModel))
        # Länge der Ansage: kurz | normal | ausfuehrlich (ersetzt {{LAENGE}}/{{LENGTH}} im Prompt)
        SUMMARY_LENGTH=\(q(summaryLength))
        CLAUDE_BIN=\(q(claudeBin))

        """
        try text.write(to: Paths.config, atomically: true, encoding: .utf8)
    }

    /// Sicher für `source`: alles in einfache Anführungszeichen.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f else { return s }
        let inner = String(s.dropFirst().dropLast())
        return f == "'" ? inner.replacingOccurrences(of: "'\\''", with: "'") : inner
    }
}

// MARK: - Prompt für die Zusammenfassung

/// Der Standard-Prompt steht nur im Hook-Skript (`--default-prompt`); ein eigener liegt in prompt.txt.
enum SummaryPrompt {
    /// Beide Schreibweisen werden vom Hook ersetzt; der Standard-Prompt nutzt die der Sprache.
    static let placeholders = ["{{LAENGE}}", "{{LENGTH}}"]
    static var placeholder: String { L10n.lang == .de ? "{{LAENGE}}" : "{{LENGTH}}" }

    static func defaultText(_ lang: Lang) -> String {
        guard let script = [Paths.bundledScript, Paths.script].compactMap({ $0 }).first(where: Paths.exists) else { return "" }
        return Shell.run("/bin/bash", [script.path, "--default-prompt", lang.rawValue]).out
    }

    static func custom() -> String? {
        guard let s = try? String(contentsOf: Paths.prompt, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// Leer oder gleich dem Standard: Datei entfernen, damit Updates des Standard-Prompts greifen.
    static func save(_ text: String, defaultText: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == defaultText.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? FileManager.default.removeItem(at: Paths.prompt)
        } else {
            try FileManager.default.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
            try (t + "\n").write(to: Paths.prompt, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Schlüsselbund

enum Keychain {
    static let service = "elevenlabs-api-key"

    static func hasKey() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess
    }

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Speichert den Key so, dass sowohl die App als auch `/usr/bin/security` (das Hook-Skript)
    /// ohne Nachfrage darauf zugreifen dürfen.
    @discardableResult
    static func save(_ key: String) -> OSStatus {
        delete()
        var attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: NSUserName(),
                                    kSecAttrLabel as String: service,
                                    kSecValueData as String: Data(key.utf8)]
        if let access = makeAccess() { attrs[kSecAttrAccess as String] = access }
        return SecItemAdd(attrs as CFDictionary, nil)
    }

    @discardableResult
    static func delete() -> OSStatus {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    private static func makeAccess() -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        var cli: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath("/usr/bin/security", &cli) == errSecSuccess, let cli { apps.append(cli) }
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}

// MARK: - ElevenLabs

struct ElevenVoice: Identifiable, Hashable, Decodable {
    let voiceID: String
    let name: String
    let category: String?
    let language: String?
    var id: String { voiceID }

    enum CodingKeys: String, CodingKey { case voice_id, name, category, labels }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        voiceID = try c.decode(String.self, forKey: .voice_id)
        name = try c.decode(String.self, forKey: .name)
        category = try? c.decode(String.self, forKey: .category)
        let labels = (try? c.decode([String: String].self, forKey: .labels)) ?? [:]
        language = labels["language"] ?? labels["accent"]
    }

    var label: String {
        var s = name
        if let language, !language.isEmpty { s += " · \(language)" }
        return s
    }
}

enum ElevenLabs {
    struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func voices(key: String) async throws -> [ElevenVoice] {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw APIError(message: code == 401 ? tr("API-Key ungültig (401).", "Invalid API key (401).")
                                               : tr("ElevenLabs antwortet mit HTTP \(code).", "ElevenLabs returned HTTP \(code)."))
        }
        struct R: Decodable { let voices: [ElevenVoice] }
        return try JSONDecoder().decode(R.self, from: data).voices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var models: [(id: String, label: String)] { [
        ("eleven_flash_v2_5", tr("Flash v2.5 – schnell, günstig", "Flash v2.5 – fast, low cost")),
        ("eleven_turbo_v2_5", "Turbo v2.5"),
        ("eleven_multilingual_v2", tr("Multilingual v2 – beste Qualität", "Multilingual v2 – best quality")),
        ("eleven_v3", tr("v3 – ausdrucksstark", "v3 – expressive")),
    ] }
}

// MARK: - Systemstimmen (`say -v '?'`)

struct SystemVoice: Hashable, Identifiable {
    let name: String
    let locale: String
    var id: String { name }

    static func all() -> [SystemVoice] {
        let r = Shell.run("/usr/bin/say", ["-v", "?"])
        let regex = try! NSRegularExpression(pattern: #"^(.+?)\s+([a-z]{2,3}_[A-Za-z0-9]+)\s+#"#)
        return r.out.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let n = Range(m.range(at: 1), in: s), let l = Range(m.range(at: 2), in: s) else { return nil }
            return SystemVoice(name: String(s[n]).trimmingCharacters(in: .whitespaces), locale: String(s[l]))
        }
    }
}

// MARK: - Hook-Installation

enum HookInstaller {
    static let marker = "speak-summary/speak-summary.sh"
    static let command = "$HOME/.claude/hooks/speak-summary/speak-summary.sh"

    struct InstallError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func isRegistered() -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    static func scriptUpToDate() -> Bool {
        guard let bundled = Paths.bundledScript, let a = try? Data(contentsOf: bundled),
              let b = try? Data(contentsOf: Paths.script) else { return false }
        return a == b
    }

    static func installScript() throws {
        guard let bundled = Paths.bundledScript else { throw InstallError(message: tr("Hook-Skript fehlt im App-Bundle.", "The hook script is missing from the app bundle.")) }
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
        if Paths.exists(Paths.script) { try fm.removeItem(at: Paths.script) }
        try fm.copyItem(at: bundled, to: Paths.script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.script.path)
    }

    /// Beim App-Start: ein bereits installiertes Skript still auf die Version im Bundle bringen.
    static func autoUpdateScript() {
        if Paths.exists(Paths.script), !scriptUpToDate() { try? installScript() }
    }

    static func install() throws {
        try installScript()
        var cfg = HookConfig.load()
        if cfg.claudeBin.isEmpty || !FileManager.default.isExecutableFile(atPath: cfg.claudeBin) {
            cfg.claudeBin = Shell.findClaude() ?? ""
        }
        try cfg.save()
        if !isRegistered() { try register() }
    }

    static func register() throws {
        try editSettings(filter: """
        .hooks.Stop = ((.hooks.Stop // []) + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}])
        """)
    }

    static func unregister() throws {
        try editSettings(filter: """
        if (.hooks.Stop | type) == "array" then
          .hooks.Stop |= map(select(any(.hooks[]?; (.command // "") | contains($marker)) | not))
          | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
        else . end
        """)
    }

    /// Ändert ~/.claude/settings.json mit jq (erhält Reihenfolge und Formatierung der übrigen Einträge).
    private static func editSettings(filter: String) throws {
        guard let jq = Shell.findJQ() else { throw InstallError(message: tr("jq wurde nicht gefunden (brew install jq).", "jq not found (brew install jq).")) }
        let fm = FileManager.default
        let url = Paths.claudeSettings
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !Paths.exists(url) { try "{}\n".write(to: url, atomically: true, encoding: .utf8) }
        let r = Shell.run(jq, ["--arg", "cmd", command, "--arg", "marker", marker, filter, url.path])
        guard r.status == 0, !r.out.isEmpty else {
            throw InstallError(message: tr("settings.json konnte nicht gelesen werden: ", "Could not read settings.json: ") + r.err)
        }
        let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.bak-agent-speak")
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: url, to: backup)
        try (r.out + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

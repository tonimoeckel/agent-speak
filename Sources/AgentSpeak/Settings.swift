import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: SettingsModel(), state: .shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Agent Speak"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 540, height: 720))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config = HookConfig.load() {
        didSet {
            guard config != oldValue else { return }
            save()
            if config.language != oldValue.language { languageChanged() }
        }
    }
    @Published var apiKeyInput = ""
    @Published var hasKey = Keychain.hasKey()
    @Published var voices: [ElevenVoice] = []
    @Published var loadingVoices = false
    @Published var systemVoices: [SystemVoice] = []
    @Published var claudePath: String?
    @Published var jqPath: String?
    @Published var message: (text: String, isError: Bool)?
    @Published var launchAtLogin = AppState.shared.launchAtLogin
    @Published private(set) var defaultPrompt: String
    @Published var promptText: String {
        didSet { if promptText != oldValue { savePrompt() } }
    }

    init() {
        let def = SummaryPrompt.defaultText(L10n.lang)
        defaultPrompt = def
        promptText = SummaryPrompt.custom() ?? def
        systemVoices = SystemVoice.all()
        jqPath = Shell.findJQ()
        claudePath = config.claudeBin.isEmpty ? nil : config.claudeBin
        Task.detached {
            let path = Shell.findClaude()
            await MainActor.run { self.claudePath = path }
        }
    }

    private func save() {
        do { try config.save() } catch {
            flash(tr("Konfiguration nicht gespeichert: ", "Could not save the configuration: ") + error.localizedDescription, error: true)
        }
    }

    // MARK: Sprache

    /// Oberfläche sofort umstellen, Standard-Prompt und Systemstimme an die neue Sprache anpassen.
    private func languageChanged() {
        let lang = LanguagePreference(rawValue: config.language)?.resolved ?? .de
        guard lang != L10n.lang else { return }
        let wasCustom = promptIsCustom
        L10n.lang = lang
        defaultPrompt = SummaryPrompt.defaultText(lang)
        if !wasCustom { promptText = defaultPrompt }
        if let voice = systemVoices.first(where: { $0.name == config.sayVoice }), !voice.locale.hasPrefix(lang.rawValue),
           let replacement = preferredSystemVoice(lang) {
            config.sayVoice = replacement   // didSet greift hier nicht erneut, daher selbst speichern
            save()
        }
        message = nil
        NSApp.mainMenu = AppDelegate.makeMainMenu()
        AppState.shared.objectWillChange.send()   // Overlay und Menüleiste neu zeichnen
    }

    private func preferredSystemVoice(_ lang: Lang) -> String? {
        let preferred = lang == .de ? "Anna" : "Samantha"
        if systemVoices.contains(where: { $0.name == preferred }) { return preferred }
        return systemVoices.first { $0.locale.hasPrefix(lang.rawValue) }?.name
    }

    func flash(_ text: String, error: Bool = false) { message = (text, error) }

    // MARK: Prompt

    var promptIsCustom: Bool {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines) != defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var promptHasPlaceholder: Bool { SummaryPrompt.placeholders.contains { promptText.contains($0) } }

    func resetPrompt() { promptText = defaultPrompt }

    private func savePrompt() {
        do { try SummaryPrompt.save(promptText, defaultText: defaultPrompt) } catch {
            flash(tr("Prompt nicht gespeichert: ", "Could not save the prompt: ") + error.localizedDescription, error: true)
        }
    }

    // MARK: ElevenLabs

    func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let status = Keychain.save(key)
        if status == errSecSuccess {
            hasKey = true
            flash(tr("API-Key im Schlüsselbund gespeichert.", "API key saved to the keychain."))
            loadVoices(using: key)
            apiKeyInput = ""
        } else {
            flash(tr("Speichern im Schlüsselbund fehlgeschlagen (\(status)).", "Could not save to the keychain (\(status))."), error: true)
        }
    }

    func removeKey() {
        Keychain.delete()
        hasKey = Keychain.hasKey()
        voices = []
        flash(tr("API-Key entfernt.", "API key removed."))
    }

    func loadVoices(using explicitKey: String? = nil) {
        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = explicitKey ?? (typed.isEmpty ? Keychain.read() : typed) else {
            flash(tr("Kein API-Key vorhanden.", "No API key available."), error: true)
            return
        }
        loadingVoices = true
        Task {
            defer { loadingVoices = false }
            do {
                voices = try await ElevenLabs.voices(key: key)
                if config.voiceID.isEmpty { flash(tr("\(voices.count) Stimmen geladen – bitte eine auswählen.", "Loaded \(voices.count) voices – please pick one.")) }
            } catch {
                flash(error.localizedDescription, error: true)
            }
        }
    }

    var voiceSelection: Binding<String> {
        Binding(
            get: { self.config.voiceID },
            set: { id in
                self.config.voiceID = id
                self.config.voiceName = self.voices.first { $0.voiceID == id }?.name ?? self.config.voiceName
            })
    }

    /// Systemstimmen der eingestellten Sprache (plus die aktuell gewählte, falls sie nicht dazugehört).
    var languageSystemVoices: [SystemVoice] {
        var list = systemVoices.filter { $0.locale.hasPrefix(L10n.lang.rawValue) }
        if !list.contains(where: { $0.name == config.sayVoice }) {
            list.append(SystemVoice(name: config.sayVoice, locale: ""))
        }
        return list
    }

    // MARK: Hook

    func installHook() {
        do {
            try HookInstaller.install()
            config = HookConfig.load()
            claudePath = config.claudeBin.isEmpty ? claudePath : config.claudeBin
            flash(tr("Hook installiert. Laufende Claude-Code-Sessions übernehmen ihn nach einem Neustart.",
                     "Hook installed. Running Claude Code sessions pick it up after a restart."))
        } catch {
            flash(error.localizedDescription, error: true)
        }
        AppState.shared.refresh()
    }

    func removeHook() {
        do {
            try HookInstaller.unregister()
            flash(tr("Hook aus settings.json entfernt. Skript und Konfiguration bleiben erhalten.",
                     "Hook removed from settings.json. Script and configuration are kept."))
        } catch {
            flash(error.localizedDescription, error: true)
        }
        AppState.shared.refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { try AppState.shared.setLaunchAtLogin(on) } catch {
            flash(tr("Login-Start: ", "Launch at login: ") + error.localizedDescription, error: true)
        }
        launchAtLogin = AppState.shared.launchAtLogin
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Form {
                speechSection
                elevenLabsSection
                systemVoiceSection
                summarySection
                overlaySection
                hookSection
            }
            .formStyle(.grouped)

            if let msg = model.message {
                HStack(spacing: 8) {
                    Image(systemName: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(msg.isError ? .orange : .green)
                    Text(msg.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .frame(width: 540, height: 720)
    }

    // MARK: Sections

    private var speechSection: some View {
        Section {
            Picker(tr("Sprache", "Language"), selection: $model.config.language) {
                ForEach(LanguagePreference.allCases) { l in Text(l.label).tag(l.rawValue) }
            }
            Toggle(tr("Vorlesen aktiv", "Read aloud"), isOn: Binding(get: { state.enabled }, set: { state.setEnabled($0) }))
            Picker(tr("Sprachausgabe", "Voice output"), selection: $model.config.ttsEngine) {
                Text(tr("Automatisch (ElevenLabs, sonst Systemstimme)", "Automatic (ElevenLabs, else system voice)")).tag("auto")
                Text(tr("Nur ElevenLabs", "ElevenLabs only")).tag("elevenlabs")
                Text(tr("Nur Systemstimme", "System voice only")).tag("say")
            }
            HStack {
                Button(tr("Test-Ansage abspielen", "Play test summary")) { state.testAnnouncement() }
                    .disabled(!state.scriptInstalled || state.busy)
                if state.busy {
                    Button(tr("Stoppen", "Stop")) { state.stopPlayback() }
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !state.scriptInstalled {
                    Text(tr("Erst Hook installieren", "Install the hook first")).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(tr("Vorlesen", "Read aloud"))
        } footer: {
            FooterText(tr("Nach jeder Antwort von Claude Code wird eine kurze Zusammenfassung vorgelesen. Braucht Claude eine Entscheidung von dir, kommen Hintergrund und Empfehlung dazu. Die Sprache gilt für die App und die Ansagen.",
                          "After every Claude Code reply, a short summary is read aloud. If Claude needs a decision from you, it adds the background and a recommendation. The language applies to the app and the spoken summaries."))
        }
    }

    private var elevenLabsSection: some View {
        Section {
            HStack {
                SecureField(model.hasKey ? tr("Neuen API-Key eingeben, um ihn zu ersetzen", "Enter a new API key to replace it")
                                         : tr("API-Key einfügen", "Paste API key"), text: $model.apiKeyInput)
                    .onSubmit { model.saveKey() }
                Button(tr("Speichern", "Save")) { model.saveKey() }
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Label(model.hasKey ? tr("Key im Schlüsselbund gespeichert", "Key stored in the keychain") : tr("Kein Key gespeichert", "No key stored"),
                      systemImage: model.hasKey ? "key.fill" : "key")
                    .foregroundStyle(model.hasKey ? .primary : .secondary)
                Spacer()
                if model.hasKey {
                    Button(tr("Entfernen", "Remove"), role: .destructive) { model.removeKey() }
                }
            }
            HStack {
                Picker(tr("Stimme", "Voice"), selection: model.voiceSelection) {
                    Text(tr("– keine –", "– none –")).tag("")
                    if !model.config.voiceID.isEmpty && !model.voices.contains(where: { $0.voiceID == model.config.voiceID }) {
                        Text(model.config.voiceName.isEmpty ? model.config.voiceID : model.config.voiceName)
                            .tag(model.config.voiceID)
                    }
                    ForEach(model.voices) { v in Text(v.label).tag(v.voiceID) }
                }
                Button(model.voices.isEmpty ? tr("Stimmen laden", "Load voices") : tr("Neu laden", "Reload")) { model.loadVoices() }
                    .disabled(model.loadingVoices || (!model.hasKey && model.apiKeyInput.isEmpty))
                if model.loadingVoices { ProgressView().controlSize(.small) }
            }
            Picker(tr("Modell", "Model"), selection: $model.config.elevenModel) {
                ForEach(ElevenLabs.models, id: \.id) { m in Text(m.label).tag(m.id) }
                if !ElevenLabs.models.contains(where: { $0.id == model.config.elevenModel }) {
                    Text(model.config.elevenModel).tag(model.config.elevenModel)
                }
            }
            HStack {
                Text(tr("Tempo", "Speed"))
                Slider(value: Binding(get: { model.config.elevenSpeed },
                                      set: { model.config.elevenSpeed = ($0 * 20).rounded() / 20 }),
                       in: 0.7...1.2) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                Text(String(format: "%.2f×", model.config.elevenSpeed))
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                Button("1×") { model.config.elevenSpeed = 1.0 }
                    .disabled(model.config.elevenSpeed == 1.0)
            }
        } header: {
            Text("ElevenLabs")
        } footer: {
            FooterText(tr("Den API-Key findest du bei ElevenLabs unter Profil → API Keys. Er liegt nur im macOS-Schlüsselbund, nicht in einer Datei. Tempo 1× nutzt die Einstellung der Stimme bei ElevenLabs.",
                          "You can find the API key at ElevenLabs under Profile → API Keys. It is stored only in the macOS keychain, never in a file. Speed 1× uses the voice's own setting at ElevenLabs."))
        }
    }

    private var systemVoiceSection: some View {
        Section(tr("Systemstimme (kostenlos, auch als Fallback)", "System voice (free, also the fallback)")) {
            Picker(tr("Stimme", "Voice"), selection: $model.config.sayVoice) {
                ForEach(model.languageSystemVoices) { v in Text(v.name).tag(v.name) }
            }
            HStack {
                Text(tr("Tempo", "Speed"))
                Slider(value: Binding(get: { Double(model.config.sayRate) },
                                      set: { model.config.sayRate = Int($0) }),
                       in: 130...300, step: 10)
                Text("\(model.config.sayRate)").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
        }
    }

    private var summarySection: some View {
        Section {
            Picker(tr("Modell", "Model"), selection: $model.config.summaryModel) {
                Text(tr("Haiku – schnell", "Haiku – fast")).tag("haiku")
                Text(tr("Sonnet – gründlicher", "Sonnet – more thorough")).tag("sonnet")
            }
            Picker(tr("Länge", "Length"), selection: $model.config.summaryLength) {
                Text(tr("Kurz", "Short")).tag("kurz")
                Text("Normal").tag("normal")
                Text(tr("Ausführlich", "Detailed")).tag("ausfuehrlich")
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Prompt")
                    if model.promptIsCustom {
                        Text(tr("angepasst", "custom")).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                    Button(tr("Standard wiederherstellen", "Restore default")) { model.resetPrompt() }
                        .disabled(!model.promptIsCustom)
                }
                TextEditor(text: $model.promptText)
                    .font(.system(size: 12))
                    .frame(height: 240)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                if !model.promptHasPlaceholder {
                    Label(tr("Ohne \(SummaryPrompt.placeholder) im Prompt hat die Länge-Einstellung keine Wirkung.",
                             "Without \(SummaryPrompt.placeholder) in the prompt, the length setting has no effect."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text(tr("Zusammenfassung", "Summary"))
        } footer: {
            FooterText(tr("Läuft über dein Claude-Abo mit `claude -p`. Der Prompt bekommt die letzte Antwort von Claude als Eingabe. {{LAENGE}} wird durch die gewählte Länge ersetzt (Kurz ≈ 2, Normal ≈ 4, Ausführlich ≈ 7 Sätze). Änderungen gelten ab der nächsten Ansage, mit „Test-Ansage abspielen“ kannst du sie ausprobieren.",
                          "Runs on your Claude subscription via `claude -p`. The prompt receives Claude's latest reply as input. {{LENGTH}} is replaced with the chosen length (Short ≈ 2, Normal ≈ 4, Detailed ≈ 7 sentences). Changes apply from the next summary; try them with “Play test summary”."))
        }
    }

    private var overlaySection: some View {
        Section("Overlay") {
            Toggle(tr("Overlay am Bildschirmrand anzeigen", "Show overlay at the screen edge"), isOn: $state.showOverlay)
            HStack {
                Picker("Position", selection: $state.overlaySide) {
                    ForEach(OverlaySide.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                Button(tr("Mittig", "Center")) { state.overlayY = 0.5 }
                    .disabled(abs(state.overlayY - 0.5) < 0.01)
            }
            Text(tr("Tipp: Du kannst das Overlay auch direkt greifen und an den linken oder rechten Rand ziehen. Die Höhe merkt es sich.",
                    "Tip: you can also grab the overlay and drag it to the left or right edge. It remembers the height."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(tr("Beim Anmelden starten", "Launch at login"), isOn: Binding(get: { model.launchAtLogin },
                                                         set: { model.setLaunchAtLogin($0) }))
        }
    }

    private var hookSection: some View {
        Section {
            status("Hook in ~/.claude/settings.json", ok: state.hookRegistered)
            status(tr("Hook-Skript installiert", "Hook script installed"), ok: state.scriptInstalled)
            status(model.claudePath.map { "Claude CLI: \($0)" } ?? tr("Claude CLI nicht gefunden", "Claude CLI not found"), ok: model.claudePath != nil)
            status(model.jqPath.map { "jq: \($0)" } ?? tr("jq nicht gefunden (brew install jq)", "jq not found (brew install jq)"), ok: model.jqPath != nil)
            HStack {
                Button(state.hookRegistered && state.scriptInstalled ? tr("Hook neu installieren", "Reinstall hook") : tr("Hook installieren", "Install hook")) {
                    model.installHook()
                }
                .buttonStyle(.borderedProminent)
                Button(tr("Hook entfernen", "Remove hook")) { model.removeHook() }
                    .disabled(!state.hookRegistered)
                Spacer()
                Button(tr("Ordner öffnen", "Open folder")) {
                    try? FileManager.default.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Paths.hookDir)
                }
            }
        } header: {
            Text(tr("Claude-Code-Hook", "Claude Code hook"))
        } footer: {
            FooterText(tr("Trägt einen Stop-Hook in deine globalen Claude-Code-Einstellungen ein. Andere Hooks bleiben erhalten, vorher wird eine Sicherung angelegt.",
                          "Adds a Stop hook to your global Claude Code settings. Other hooks are kept, and a backup is made first."))
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
        }
    }
}

private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(LocalizedStringKey(text))   // LocalizedStringKey, damit `Code` als Markdown erscheint
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

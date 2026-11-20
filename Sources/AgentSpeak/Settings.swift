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
        didSet { if config != oldValue { save() } }
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
    let defaultPrompt: String
    @Published var promptText: String {
        didSet { if promptText != oldValue { savePrompt() } }
    }

    init() {
        let def = SummaryPrompt.defaultText()
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
        do { try config.save() } catch { flash("Konfiguration nicht gespeichert: \(error.localizedDescription)", error: true) }
    }

    func flash(_ text: String, error: Bool = false) { message = (text, error) }

    // MARK: Prompt

    var promptIsCustom: Bool {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines) != defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var promptHasPlaceholder: Bool { promptText.contains(SummaryPrompt.placeholder) }

    func resetPrompt() { promptText = defaultPrompt }

    private func savePrompt() {
        do { try SummaryPrompt.save(promptText, defaultText: defaultPrompt) } catch {
            flash("Prompt nicht gespeichert: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: ElevenLabs

    func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let status = Keychain.save(key)
        if status == errSecSuccess {
            hasKey = true
            flash("API-Key im Schlüsselbund gespeichert.")
            loadVoices(using: key)
            apiKeyInput = ""
        } else {
            flash("Speichern im Schlüsselbund fehlgeschlagen (\(status)).", error: true)
        }
    }

    func removeKey() {
        Keychain.delete()
        hasKey = Keychain.hasKey()
        voices = []
        flash("API-Key entfernt.")
    }

    func loadVoices(using explicitKey: String? = nil) {
        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = explicitKey ?? (typed.isEmpty ? Keychain.read() : typed) else {
            flash("Kein API-Key vorhanden.", error: true)
            return
        }
        loadingVoices = true
        Task {
            defer { loadingVoices = false }
            do {
                voices = try await ElevenLabs.voices(key: key)
                if config.voiceID.isEmpty { flash("\(voices.count) Stimmen geladen – bitte eine auswählen.") }
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

    var germanFirstSystemVoices: [SystemVoice] {
        var list = systemVoices.filter { $0.locale.hasPrefix("de") }
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
            flash("Hook installiert. Laufende Claude-Code-Sessions übernehmen ihn nach einem Neustart.")
        } catch {
            flash(error.localizedDescription, error: true)
        }
        AppState.shared.refresh()
    }

    func removeHook() {
        do {
            try HookInstaller.unregister()
            flash("Hook aus settings.json entfernt. Skript und Konfiguration bleiben erhalten.")
        } catch {
            flash(error.localizedDescription, error: true)
        }
        AppState.shared.refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { try AppState.shared.setLaunchAtLogin(on) } catch {
            flash("Login-Start: \(error.localizedDescription)", error: true)
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
            Toggle("Vorlesen aktiv", isOn: Binding(get: { state.enabled }, set: { state.setEnabled($0) }))
            Picker("Sprachausgabe", selection: $model.config.ttsEngine) {
                Text("Automatisch (ElevenLabs, sonst Systemstimme)").tag("auto")
                Text("Nur ElevenLabs").tag("elevenlabs")
                Text("Nur Systemstimme").tag("say")
            }
            HStack {
                Button("Test-Ansage abspielen") { state.testAnnouncement() }
                    .disabled(!state.scriptInstalled || state.busy)
                if state.busy {
                    Button("Stoppen") { state.stopPlayback() }
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !state.scriptInstalled {
                    Text("Erst Hook installieren").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Vorlesen")
        } footer: {
            FooterText("Nach jeder Antwort von Claude Code wird eine kurze Zusammenfassung vorgelesen. Braucht Claude eine Entscheidung von dir, kommen Hintergrund und Empfehlung dazu.")
        }
    }

    private var elevenLabsSection: some View {
        Section {
            HStack {
                SecureField(model.hasKey ? "Neuen API-Key eingeben, um ihn zu ersetzen" : "API-Key einfügen", text: $model.apiKeyInput)
                    .onSubmit { model.saveKey() }
                Button("Speichern") { model.saveKey() }
                    .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Label(model.hasKey ? "Key im Schlüsselbund gespeichert" : "Kein Key gespeichert",
                      systemImage: model.hasKey ? "key.fill" : "key")
                    .foregroundStyle(model.hasKey ? .primary : .secondary)
                Spacer()
                if model.hasKey {
                    Button("Entfernen", role: .destructive) { model.removeKey() }
                }
            }
            HStack {
                Picker("Stimme", selection: model.voiceSelection) {
                    Text("– keine –").tag("")
                    if !model.config.voiceID.isEmpty && !model.voices.contains(where: { $0.voiceID == model.config.voiceID }) {
                        Text(model.config.voiceName.isEmpty ? model.config.voiceID : model.config.voiceName)
                            .tag(model.config.voiceID)
                    }
                    ForEach(model.voices) { v in Text(v.label).tag(v.voiceID) }
                }
                Button(model.voices.isEmpty ? "Stimmen laden" : "Neu laden") { model.loadVoices() }
                    .disabled(model.loadingVoices || (!model.hasKey && model.apiKeyInput.isEmpty))
                if model.loadingVoices { ProgressView().controlSize(.small) }
            }
            Picker("Modell", selection: $model.config.elevenModel) {
                ForEach(ElevenLabs.models, id: \.id) { m in Text(m.label).tag(m.id) }
                if !ElevenLabs.models.contains(where: { $0.id == model.config.elevenModel }) {
                    Text(model.config.elevenModel).tag(model.config.elevenModel)
                }
            }
            HStack {
                Text("Tempo")
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
            FooterText("Den API-Key findest du bei ElevenLabs unter Profil → API Keys. Er liegt nur im macOS-Schlüsselbund, nicht in einer Datei. Tempo 1× nutzt die Einstellung der Stimme bei ElevenLabs.")
        }
    }

    private var systemVoiceSection: some View {
        Section("Systemstimme (kostenlos, auch als Fallback)") {
            Picker("Stimme", selection: $model.config.sayVoice) {
                ForEach(model.germanFirstSystemVoices) { v in Text(v.name).tag(v.name) }
            }
            HStack {
                Text("Tempo")
                Slider(value: Binding(get: { Double(model.config.sayRate) },
                                      set: { model.config.sayRate = Int($0) }),
                       in: 130...300, step: 10)
                Text("\(model.config.sayRate)").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
        }
    }

    private var summarySection: some View {
        Section {
            Picker("Modell", selection: $model.config.summaryModel) {
                Text("Haiku – schnell").tag("haiku")
                Text("Sonnet – gründlicher").tag("sonnet")
            }
            Picker("Länge", selection: $model.config.summaryLength) {
                Text("Kurz").tag("kurz")
                Text("Normal").tag("normal")
                Text("Ausführlich").tag("ausfuehrlich")
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Prompt")
                    if model.promptIsCustom {
                        Text("angepasst").font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                    Button("Standard wiederherstellen") { model.resetPrompt() }
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
                    Label("Ohne {{LAENGE}} im Prompt hat die Länge-Einstellung keine Wirkung.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Zusammenfassung")
        } footer: {
            FooterText("Läuft über dein Claude-Abo mit `claude -p`. Der Prompt bekommt die letzte Antwort von Claude als Eingabe. {{LAENGE}} wird durch die gewählte Länge ersetzt (Kurz ≈ 2, Normal ≈ 4, Ausführlich ≈ 7 Sätze). Änderungen gelten ab der nächsten Ansage, mit „Test-Ansage abspielen“ kannst du sie ausprobieren.")
        }
    }

    private var overlaySection: some View {
        Section("Overlay") {
            Toggle("Overlay am Bildschirmrand anzeigen", isOn: $state.showOverlay)
            HStack {
                Picker("Position", selection: $state.overlaySide) {
                    ForEach(OverlaySide.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                Button("Mittig") { state.overlayY = 0.5 }
                    .disabled(abs(state.overlayY - 0.5) < 0.01)
            }
            Text("Tipp: Du kannst das Overlay auch direkt greifen und an den linken oder rechten Rand ziehen. Die Höhe merkt es sich.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Beim Anmelden starten", isOn: Binding(get: { model.launchAtLogin },
                                                         set: { model.setLaunchAtLogin($0) }))
        }
    }

    private var hookSection: some View {
        Section {
            status("Hook in ~/.claude/settings.json", ok: state.hookRegistered)
            status("Hook-Skript installiert", ok: state.scriptInstalled)
            status(model.claudePath.map { "Claude CLI: \($0)" } ?? "Claude CLI nicht gefunden", ok: model.claudePath != nil)
            status(model.jqPath.map { "jq: \($0)" } ?? "jq nicht gefunden (brew install jq)", ok: model.jqPath != nil)
            HStack {
                Button(state.hookRegistered && state.scriptInstalled ? "Hook neu installieren" : "Hook installieren") {
                    model.installHook()
                }
                .buttonStyle(.borderedProminent)
                Button("Hook entfernen") { model.removeHook() }
                    .disabled(!state.hookRegistered)
                Spacer()
                Button("Ordner öffnen") {
                    try? FileManager.default.createDirectory(at: Paths.hookDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Paths.hookDir)
                }
            }
        } header: {
            Text("Claude-Code-Hook")
        } footer: {
            FooterText("Trägt einen Stop-Hook in deine globalen Claude-Code-Einstellungen ein. Andere Hooks bleiben erhalten, vorher wird eine Sicherung angelegt.")
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
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

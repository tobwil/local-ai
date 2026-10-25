import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var testResult: String?
    @State private var testing = false
    @State private var cloudNote: String?
    @State private var browserTest: String?
    @State private var gpuNote: String?
    @State private var showKey = false

    private func refresh(anthropic: Bool) {
        Task {
            do {
                let ids = try await CloudModels.refresh(anthropic: anthropic)
                cloudNote = "\(ids.count) Modelle geladen: \(ids.prefix(6).joined(separator: ", "))\(ids.count > 6 ? " …" : "")"
            } catch { cloudNote = error.localizedDescription }
        }
    }

    var body: some View {
        @Bindable var settings = app.settings
        @Bindable var state = app
        Form {
            Section("Web") {
                Toggle("Websuche und Seitenabruf erlauben", isOn: $state.useWebTools)
                Picker("Suchanbieter", selection: $settings.searchProvider) {
                    ForEach(WebSearch.Provider.allCases) { Text($0.label).tag($0) }
                }
                if settings.searchProvider == .searxng {
                    TextField("SearXNG-Adresse", text: $settings.searxngURL, prompt: Text("http://localhost:8888"))
                }
                if settings.searchProvider == .brave {
                    SecureField("Brave-API-Schlüssel", text: $settings.braveKey)
                    Text("Wird im Schlüsselbund gespeichert.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Suche testen") {
                        testing = true
                        Task {
                            do {
                                let r = try await WebSearch.search("Apple MLX", max: 3)
                                testResult = r.isEmpty ? "Keine Treffer" : r.map(\.title).joined(separator: " · ")
                            } catch { testResult = error.localizedDescription }
                            testing = false
                        }
                    }
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }

            Section("Heimnetz: iPhone & andere Geräte") {
                Toggle("KI/lokal im Heimnetz freigeben (mit Schlüssel)", isOn: Binding(get: { settings.lanEnabled }, set: { on in
                    settings.lanEnabled = on
                    if app.server.state == .running { Task { await app.server.restart() } }
                }))
                if settings.lanEnabled && app.server.state == .external {
                    HStack {
                        Label("Die Engine wurde außerhalb der App gestartet und ist nur auf diesem Mac erreichbar.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("In der App neu starten") { Task { await app.server.takeOver() } }
                    }
                }
                if settings.lanEnabled {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = HomeNetwork.qrCode(HomeNetwork.webChatURL) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mit dem iPhone scannen → Web-Chat öffnen → mit dem Schlüssel anmelden.").font(.callout)
                            LabeledContent("Web-Chat", value: HomeNetwork.webChatURL).textSelection(.enabled)
                            LabeledContent("API (OpenAI)", value: HomeNetwork.apiURL).textSelection(.enabled)
                            if let ip = HomeNetwork.ipAddress { LabeledContent("IP-Adresse", value: ip).textSelection(.enabled) }
                            HStack {
                                Text("Schlüssel").foregroundStyle(.secondary)
                                Text(showKey ? settings.lanKey : String(repeating: "•", count: 16)).font(.callout.monospaced()).textSelection(.enabled)
                                Button(showKey ? "Verbergen" : "Zeigen") { showKey.toggle() }.buttonStyle(.borderless)
                                Button("Kopieren") { AppState.copy(settings.lanKey) }.buttonStyle(.borderless)
                                Button("Neu erzeugen") {
                                    settings.regenerateLanKey()
                                    if app.server.state == .running { Task { await app.server.restart() } }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Text("Nur im eigenen WLAN nutzen. macOS fragt beim ersten Start, ob eingehende Verbindungen erlaubt sind. Apps wie Chatbox, Enchanted oder Open WebUI brauchen API-URL, Schlüssel und Modell \(app.selectedModelID).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Bildschirm & Gesprächsmodus") {
                Toggle("Agent darf auf den Bildschirm schauen (look_at_screen, „schau auf meinen Bildschirm“)", isOn: $settings.screenEnabled)
                Text("Bildschirmfotos gehen an das Vision-Modell (\(app.visionModelID.map(CloudModels.displayName) ?? "keins installiert")) – lokal, außer du hast ein Cloud-Modell gewählt. Jede Aufnahme durch den Agenten braucht deine Freigabe, außer im YOLO-Modus. macOS fragt einmal nach der Erlaubnis für Bildschirmaufnahmen.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Gesprächsmodus (Wellen-Symbol im Chat): sprechen, nach ~1,4 s Pause wird abgeschickt, die Antwort wird vorgelesen, danach hört KI/lokal wieder zu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Kalender, Erinnerungen, Kontakte & Mail") {
                Toggle("Agent darf Termine, Erinnerungen, Kontakte und Mail nutzen", isOn: $settings.pimEnabled)
                Text("Lesen läuft direkt, Termine/Erinnerungen anlegen und Mail-Entwürfe nur nach Freigabe. Mails werden nie selbst verschickt – der Agent legt einen Entwurf an, du sendest. macOS fragt beim ersten Zugriff nach.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Browser-Steuerung") {
                Toggle("Agent darf meinen Browser steuern", isOn: $settings.browserEnabled)
                if settings.browserEnabled {
                    Picker("Browser", selection: $settings.browserApp) {
                        ForEach(BrowserTools.browsers, id: \.self) { Text($0).tag($0) }
                    }
                    Text("""
                    Einmalig einrichten: im Browser „JavaScript von Apple Events erlauben“ einschalten \
                    (Chrome/Brave/Edge: Ansicht → Entwickler; Safari: Einstellungen → Erweitert → Entwickler-Menü, dann Entwickler-Menü). \
                    macOS fragt beim ersten Zugriff, ob KI/lokal den Browser steuern darf. \
                    Lesen und Scrollen laufen direkt, Öffnen, Klicken und Tippen nur nach deiner Freigabe im Chat.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Verbindung testen") {
                            browserTest = "prüfe …"
                            Task {
                                do { browserTest = try await BrowserTools.all()[0].run([:]).split(separator: "\n").prefix(3).joined(separator: "\n") }
                                catch { browserTest = error.localizedDescription }
                            }
                        }
                        if let browserTest { Text(browserTest).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }

            Section("Modell-Router") {
                Toggle("Modell automatisch nach Thema wählen", isOn: $settings.routerEnabled)
                if settings.routerEnabled {
                    ForEach(ModelRouter.Topic.allCases) { topic in
                        Picker(selection: Binding(get: { settings.routes[topic.rawValue] ?? "" },
                                                  set: { settings.routes[topic.rawValue] = $0 })) {
                            Text("Gewähltes Modell").tag("")
                            ForEach(app.installedModels.filter { topic != .vision || $0.vision }) { Text($0.name).tag($0.id) }
                            ForEach(CloudModels.all, id: \.self) { Text(CloudModels.displayName($0)).tag($0) }
                        } label: {
                            Label(topic.label, systemImage: topic.icon)
                        }
                    }
                    Text("Erkennung per Stichworten (Code-Begriffe, Dateinamen, Code-Blöcke, Slash-Befehle) und angehängten Bildern. Auf 24 GB passt nur ein großes Modell in den Speicher: Ein Wechsel lädt das andere Modell neu (~10–15 s).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Agent") {
                Toggle("Datei- und Shell-Werkzeuge", isOn: $state.useBuiltinTools)
                Toggle(isOn: Bindable(app.session).autoApprove) {
                    Label("YOLO-Modus: ohne Nachfrage ausführen", systemImage: "flame.fill")
                }
                Toggle("Notbremse: bei zerstörerischen Aktionen trotzdem fragen (sudo, rm -rf, force-push, Schreiben außerhalb ~)",
                       isOn: Bindable(app.session).dangerGuard)
                    .disabled(!app.session.autoApprove)
                Stepper("Höchstens \(settings.maxSteps) Schritte pro Aufgabe", value: $settings.maxSteps, in: 4...100, step: 4)
                Stepper("Antwortlänge bis \(settings.maxTokens) Tokens", value: $settings.maxTokens, in: 1024...32768, step: 1024)
                VStack(alignment: .leading) {
                    Text("Eigene Anweisungen (gelten für jedes Gespräch)")
                    TextEditor(text: $settings.customInstructions)
                        .font(.callout).frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            }

            Section("Cloud-Modelle (optional)") {
                SecureField("Anthropic-API-Schlüssel", text: $settings.anthropicKey)
                HStack {
                    Picker("Claude-Effort", selection: $settings.anthropicEffort) {
                        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                    }
                    Button("Modelle laden") { refresh(anthropic: true) }.disabled(settings.anthropicKey.isEmpty)
                }
                SecureField("OpenAI-kompatibler API-Schlüssel", text: $settings.openaiKey)
                HStack {
                    TextField("Basis-URL", text: $settings.openaiBaseURL, prompt: Text("https://api.openai.com/v1"))
                    Button("Modelle laden") { refresh(anthropic: false) }.disabled(settings.openaiKey.isEmpty)
                }
                Text("OpenAI, OpenRouter (https://openrouter.ai/api/v1), Groq, Mistral … – alles mit OpenAI-kompatibler API. Schlüssel liegen im Schlüsselbund.")
                    .font(.caption).foregroundStyle(.secondary)
                if let cloudNote { Text(cloudNote).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Picker(selection: $settings.expertModel) {
                    Text("Aus").tag("")
                    ForEach(CloudModels.all, id: \.self) { Text(CloudModels.displayName($0)).tag($0) }
                } label: {
                    Label("Experte für den lokalen Agenten (ask_expert)", systemImage: "person.badge.shield.checkmark")
                }
                Text("Der lokale Agent darf bei schweren Teilfragen ein Briefing vom Cloud-Modell holen – jedes Mal nach deiner Freigabe. Cloud-Modelle lassen sich außerdem unter Modelle direkt als Hauptmodell wählen oder im Router einem Thema zuordnen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Über") {
                HStack(spacing: 14) {
                    Wordmark(size: 26)
                    Spacer()
                    KisruptivLogo(height: 20)
                }
                Text("KI/lokal ist ein Tool von KIsruptiv: KI und Automatisierung verständlich, wirksam und für alle nutzbar machen – hier ganz privat auf deinem Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Link("kisruptiv.de", destination: URL(string: "https://kisruptiv.de")!)
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") · Engine oMLX (Apache 2.0)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Engine") {
                HStack {
                    Text(app.server.engineInstalled ? "oMLX eingerichtet (\(EngineInstaller.omlxCommit.prefix(7)) + MTP-Patch)" : "oMLX fehlt")
                    Spacer()
                    Button(app.server.engineInstalled ? "Neu einrichten / reparieren" : "Engine einrichten") { app.installer.install() }
                        .disabled(app.installer.running)
                }
                if app.installer.running || app.installer.finished != nil {
                    Text(app.installer.step).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("oMLX", value: Paths.omlx.path)
                LabeledContent("Modelle", value: Paths.models.path)
                LabeledContent("Speichergrenze", value: String(format: "%.1f GiB", app.server.memoryCeilingGiB))
                LabeledContent("GPU-Limit von macOS", value: app.hardware.gpuLimitGB.gb)
                HStack {
                    Button("GPU-Speicher auf \(app.recommendedGPULimitMB / 1024) GB erhöhen …") {
                        Task { gpuNote = await app.setGPULimit(mb: app.recommendedGPULimitMB) ?? "Erhöht – gilt bis zum nächsten Neustart." }
                    }
                    Button("Zurücksetzen") {
                        Task { gpuNote = await app.setGPULimit(mb: 0) ?? "Standard wiederhergestellt." }
                    }
                }
                Text("Mehr GPU-Speicher erlaubt 64k Kontext und größere Modelle. macOS fragt nach deinem Passwort; die Einstellung gilt bis zum Neustart. Dann bleibt weniger Speicher für andere Apps.")
                    .font(.caption).foregroundStyle(.secondary)
                if let gpuNote { Text(gpuNote).font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Adresse", value: Paths.openAIBase.absoluteString)
            }
        }
        .formStyle(.grouped)
    }
}

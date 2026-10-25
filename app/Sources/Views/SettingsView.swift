import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var testResult: String?
    @State private var testing = false
    @State private var cloudNote: String?
    @State private var browserTest: String?

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

            Section("Browser-Steuerung") {
                Toggle("Agent darf meinen Browser steuern", isOn: $settings.browserEnabled)
                if settings.browserEnabled {
                    Picker("Browser", selection: $settings.browserApp) {
                        ForEach(BrowserTools.browsers, id: \.self) { Text($0).tag($0) }
                    }
                    Text("""
                    Einmalig einrichten: im Browser „JavaScript von Apple Events erlauben“ einschalten \
                    (Chrome/Brave/Edge: Ansicht → Entwickler; Safari: Einstellungen → Erweitert → Entwickler-Menü, dann Entwickler-Menü). \
                    macOS fragt beim ersten Zugriff, ob Local AI den Browser steuern darf. \
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

            Section("Engine") {
                LabeledContent("oMLX", value: Paths.omlx.path)
                LabeledContent("Modelle", value: Paths.models.path)
                LabeledContent("Speichergrenze", value: String(format: "%.1f GiB", app.server.memoryCeilingGiB))
                LabeledContent("Adresse", value: Paths.openAIBase.absoluteString)
            }
        }
        .formStyle(.grouped)
    }
}

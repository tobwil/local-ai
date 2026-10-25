import SwiftUI

struct AutomationsView: View {
    @Environment(AppState.self) private var app
    @State private var editing: Automation?
    @State private var location = ""

    var body: some View {
        let center = app.automations
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    HStack {
                        Label("Automationen", systemImage: "clock.badge.checkmark.fill").font(.headline)
                        Spacer()
                        Button { editing = Automation(name: "Neue Automation", prompt: "", outputs: [.notify]) } label: {
                            Label("Neu", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Aufträge, die der Agent zu festen Zeiten von selbst erledigt – z. B. jeden Morgen ein Briefing. KI/lokal muss dafür laufen (Menüleiste genügt) und startet die Engine bei Bedarf.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Bei Anmeldung automatisch starten", isOn: Binding(get: { center.launchAtLogin }, set: { center.launchAtLogin = $0 }))
                    if !center.automations.contains(where: { $0.name == "Morgen-Briefing" }) {
                        Divider()
                        HStack {
                            Image(systemName: "sun.horizon.fill").foregroundStyle(Theme.gold)
                            Text("Vorlage: Morgen-Briefing (Mo–Fr 7:30)").font(.callout.weight(.medium))
                            TextField("Ort fürs Wetter", text: $location).textFieldStyle(.roundedBorder).frame(width: 160)
                            Button("Anlegen") {
                                app.settings.homeLocation = location
                                if !app.settings.pimEnabled { app.settings.pimEnabled = true }
                                center.upsert(.briefing(location: location.isEmpty ? "meiner Stadt" : location))
                            }
                        }
                        Text("Termine, Erinnerungen, ungelesene Mails, Wetter und Nachrichten – als Mitteilung und vorgelesen. Schaltet den Zugriff auf Kalender & Mail ein (macOS fragt beim ersten Mal).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                ForEach(center.automations) { a in
                    Card {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.name).font(.headline)
                                HStack(spacing: 6) {
                                    Chip(text: a.scheduleText, systemImage: "clock")
                                    ForEach(Array(a.outputs).sorted { $0.rawValue < $1.rawValue }) { Chip(text: $0.label) }
                                    if a.allowActions { Chip(text: "darf handeln", systemImage: "flame", tint: .orange) }
                                }
                                if let last = a.lastRun {
                                    Text("Zuletzt: \(last.formatted(date: .abbreviated, time: .shortened)) · nächstes Mal: \(a.nextRun(after: Date())?.formatted(date: .abbreviated, time: .shortened) ?? "–")")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let next = a.nextRun(after: Date()) {
                                    Text("Nächstes Mal: \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if center.running.contains(a.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Jetzt ausführen") { Task { await center.run(a) } }
                            }
                            Button("Bearbeiten") { editing = a }
                            Toggle("", isOn: Binding(get: { a.enabled }, set: { var b = a; b.enabled = $0; center.upsert(b) }))
                                .toggleStyle(.switch)
                        }
                    }
                }

                if !center.runs.isEmpty {
                    Card {
                        Text("Letzte Ergebnisse").font(.headline)
                        ForEach(center.runs.prefix(15)) { run in
                            DisclosureGroup {
                                RichText(text: run.result).padding(.vertical, 6)
                            } label: {
                                HStack {
                                    Image(systemName: run.failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(run.failed ? .red : .green)
                                    Text(run.name).font(.callout.weight(.medium))
                                    Text(run.started.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(item: $editing) { a in AutomationEditor(automation: a) }
        .onAppear { location = app.settings.homeLocation }
    }
}

private struct AutomationEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var automation: Automation
    @State private var time = Date()
    @State private var useInterval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automation").font(.title2.bold())
            Form {
                TextField("Name", text: $automation.name)
                VStack(alignment: .leading) {
                    Text("Auftrag an den Agenten")
                    TextEditor(text: $automation.prompt).font(.callout).frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
                Toggle("Wiederholen in festem Abstand statt zu einer Uhrzeit", isOn: $useInterval)
                if useInterval {
                    Stepper("Alle \(max(automation.intervalMinutes, 15)) Minuten", value: $automation.intervalMinutes, in: 15...1440, step: 15)
                } else {
                    DatePicker("Uhrzeit", selection: $time, displayedComponents: .hourAndMinute)
                    HStack {
                        ForEach([(2, "Mo"), (3, "Di"), (4, "Mi"), (5, "Do"), (6, "Fr"), (7, "Sa"), (1, "So")], id: \.0) { day, name in
                            Toggle(name, isOn: Binding(get: { automation.weekdays.contains(day) },
                                                       set: { if $0 { automation.weekdays.insert(day) } else { automation.weekdays.remove(day) } }))
                                .toggleStyle(.button)
                        }
                    }
                    Text("Keine Tage ausgewählt = täglich.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Ergebnis")
                    ForEach(Automation.Output.allCases) { o in
                        Toggle(o.label, isOn: Binding(get: { automation.outputs.contains(o) },
                                                      set: { if $0 { automation.outputs.insert(o) } else { automation.outputs.remove(o) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                Toggle("Darf handeln (Dateien schreiben, Shell, Termine/Entwürfe anlegen, Browser, MCP) – ohne Rückfrage", isOn: $automation.allowActions)
            }
            .formStyle(.grouped)
            HStack {
                if app.automations.automations.contains(where: { $0.id == automation.id }) {
                    Button("Löschen", role: .destructive) {
                        app.automations.remove(automation)
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    automation.hour = c.hour ?? 7
                    automation.minute = c.minute ?? 30
                    if !useInterval { automation.intervalMinutes = 0 } else { automation.intervalMinutes = max(automation.intervalMinutes, 15) }
                    app.automations.upsert(automation)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(automation.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear {
            time = Calendar.current.date(bySettingHour: automation.hour, minute: automation.minute, second: 0, of: Date()) ?? Date()
            useInterval = automation.intervalMinutes > 0
        }
    }
}

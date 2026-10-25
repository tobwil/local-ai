import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var app
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Meine Modelle").tag(0)
                Text("Hugging Face durchsuchen").tag(1)
            }
            .pickerStyle(.segmented).frame(maxWidth: 420).padding(14)
            Divider()
            if tab == 0 {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(app.allModels) { ModelRow(model: $0) }
                        if !CloudModels.all.isEmpty { CloudModelsCard() }
                        Text("Modelle liegen unter \(Paths.models.path). oMLX bietet alle installierten Modelle an und lädt das gewählte beim ersten Aufruf.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                }
            } else {
                HubView(onInstalled: { tab = 0 })
            }
        }
    }
}

private struct ModelRow: View {
    @Environment(AppState.self) private var app
    let model: ModelInfo
    @State private var acceleration: Acceleration = .plain

    var body: some View {
        let installed = { _ = app.installedModels; return model.isInstalled }()
        let selected = app.selectedModelID == model.id
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(model.name).font(.title3.weight(.semibold))
                        if model.id == app.recommended?.id { Chip(text: "Empfehlung", systemImage: "star.fill", tint: Theme.violet) }
                        if selected { Chip(text: "aktiv", systemImage: "checkmark", tint: .green) }
                        if model.vision { Chip(text: "Vision", systemImage: "eye", tint: Theme.teal) }
                        if model.origin != "Katalog" { Chip(text: model.origin, systemImage: "shippingbox") }
                    }
                    Text(model.summary).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Chip(text: model.sizeGB.gb, systemImage: "internaldrive")
                        Chip(text: "\(model.activeParamsB.oneDecimal) Mrd. aktiv", systemImage: "bolt")
                        if let t = model.estimatedTokS(app.hardware) { Chip(text: "~\(Int(t)) tok/s", systemImage: "speedometer") }
                        Chip(text: model.license, systemImage: "doc.text")
                        if !model.fits(app.hardware) { Chip(text: "braucht \(model.neededGPUGB.gb) GPU", systemImage: "exclamationmark.triangle", tint: .orange) }
                    }
                }
                Spacer()
                actions(installed: installed, selected: selected)
            }
            if let p = app.downloads.active[model.id] {
                ProgressView(value: p.fraction).tint(Theme.violet)
                Text("\(p.file) · \(formatBytes(p.done)) / \(formatBytes(p.total)) · \(formatBytes(Int64(p.bytesPerSecond)))/s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let err = app.downloads.errors[model.id] {
                Label(err, systemImage: "exclamationmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if installed && model.hasMTP {
                Divider()
                HStack {
                    Text("Beschleunigung").foregroundStyle(.secondary)
                    Picker("", selection: $acceleration) {
                        ForEach(Acceleration.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 420)
                    .onChange(of: acceleration) { _, new in Task { await app.setAcceleration(new, for: model) } }
                    Spacer()
                }
                Text("MTP verdoppelt das Tempo bei Code-Edits (~77 tok/s), ist bei freiem Text aber ~10 % langsamer. Ein Wechsel startet den Server neu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { acceleration = ModelSettingsStore.acceleration(for: model.id) }
    }

    @ViewBuilder private func actions(installed: Bool, selected: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if app.downloads.isRunning(model.id) {
                Button("Abbrechen", role: .cancel) { app.downloads.cancel(model.id) }
            } else if !installed {
                Button { app.download(model) } label: { Label("Laden", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sizeGB + 2 > app.hardware.freeDiskGB)
            } else {
                if !selected {
                    Button("Verwenden") { app.selectedModelID = model.id }.buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) { app.moveToTrash(model) } label: { Label("In den Papierkorb", systemImage: "trash") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}


private struct CloudModelsCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Card {
            HStack {
                Label("Cloud-Modelle", systemImage: "cloud").font(.title3.weight(.semibold))
                Chip(text: "Daten verlassen den Mac", systemImage: "exclamationmark.shield", tint: .orange)
            }
            ForEach(CloudModels.all, id: \.self) { id in
                HStack {
                    Text(CloudModels.displayName(id)).font(.callout.monospaced())
                    Spacer()
                    if app.selectedModelID == id {
                        Chip(text: "aktiv", systemImage: "checkmark", tint: .green)
                    } else {
                        Button("Verwenden") { app.selectedModelID = id }
                    }
                }
            }
        }
    }
}

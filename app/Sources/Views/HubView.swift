import SwiftUI

struct HubView: View {
    @Environment(AppState.self) private var app
    @State private var hub = HubBrowser()
    let onInstalled: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("MLX-Modelle auf Hugging Face suchen, z. B. „Qwen“, „coder“, „vision“ …", text: $hub.query)
                    .textFieldStyle(.plain)
                    .onSubmit { hub.search(hw: app.hardware) }
                Picker("", selection: $hub.sort) { ForEach(HubBrowser.Sort.allCases) { Text($0.label).tag($0) } }
                    .frame(width: 140)
                Toggle("Nur passende", isOn: $hub.onlyFitting).toggleStyle(.checkbox)
                Toggle("Nur Vision", isOn: $hub.onlyVision).toggleStyle(.checkbox)
                if hub.loading { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(.background.secondary)
            .onChange(of: hub.query) { hub.search(hw: app.hardware) }
            .onChange(of: hub.sort) { hub.search(hw: app.hardware) }
            .onChange(of: hub.onlyFitting) { hub.search(hw: app.hardware) }
            .onChange(of: hub.onlyVision) { hub.search(hw: app.hardware) }

            if let e = hub.error {
                Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.red).padding()
            }
            List(hub.results) { HubRow(model: $0, onInstalled: onInstalled) }
                .listStyle(.inset)
                .overlay {
                    if hub.results.isEmpty && !hub.loading {
                        ContentUnavailableView("Keine Treffer", systemImage: "square.stack.3d.up.slash",
                                               description: Text("Anderen Suchbegriff probieren oder „Nur passende“ abschalten."))
                    }
                }
            Text("Bewertung aus Gewichtsgröße (Safetensors-Metadaten) gegen dein GPU-Limit von \(app.hardware.gpuLimitGB.gb); Tempo aus aktiven Parametern im Namen und \(Int(app.hardware.bandwidthGBs ?? 0)) GB/s, kalibriert an der Ornith-Messung. „Engine“ prüft, ob deine oMLX-Version die Architektur kennt.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .task { hub.search(hw: app.hardware) }
    }
}

private struct HubRow: View {
    @Environment(AppState.self) private var app
    let model: HubModel
    let onInstalled: () -> Void

    var body: some View {
        let rating = model.rating(app.hardware)
        let supported = EngineSupport.supports(model.modelType)
        let installed = app.allModels.contains { $0.repo == model.id && $0.isInstalled }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rating.icon).font(.title3).foregroundStyle(color(rating)).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(model.author).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Chip(text: rating.label, tint: color(rating))
                    Chip(text: model.sizeGB.gb, systemImage: "internaldrive")
                    if let t = model.totalParamsB {
                        Chip(text: model.isMoE ? "\(fmt(t)) / \(fmt(model.activeParamsB ?? t)) Mrd. aktiv" : "\(fmt(t)) Mrd. dicht",
                             systemImage: "bolt")
                    }
                    if let t = model.estimatedTokS(app.hardware) { Chip(text: "~\(Int(t)) tok/s", systemImage: "speedometer") }
                    if model.vision { Chip(text: "Vision", systemImage: "eye", tint: Theme.teal) }
                    switch supported {
                    case true?: Chip(text: model.modelType, systemImage: "checkmark.seal", tint: .green)
                    case false?: Chip(text: "\(model.modelType) – Engine kennt es nicht", systemImage: "xmark.seal", tint: .red)
                    case nil: Chip(text: model.modelType)
                    }
                }
                Text("↓ \(model.downloads.formatted()) · ♥ \(model.likes) · \(model.license) · \(model.lastModified)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if installed {
                    Label("Installiert", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                } else if app.downloads.isRunning(model.name) {
                    ProgressView(value: app.downloads.active[model.name]?.fraction ?? 0).frame(width: 90)
                } else {
                    Button("Laden") {
                        app.addFromHub(model)
                        onInstalled()
                    }
                    .disabled(rating == .tooBig || supported == false || model.sizeGB + 2 > app.hardware.freeDiskGB)
                }
                Link(destination: URL(string: "https://huggingface.co/\(model.id)")!) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Auf Hugging Face öffnen")
            }
        }
        .padding(.vertical, 4)
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func color(_ r: ModelFit.Rating) -> Color {
        switch r {
        case .good: return .green
        case .slow: return .orange
        case .tight: return .yellow
        case .tooBig: return .red
        }
    }
}

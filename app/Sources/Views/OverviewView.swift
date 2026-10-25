import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var app
    @Binding var screen: Screen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                HardwareGrid(hw: app.hardware)
                fitList
            }
            .padding(24)
        }
    }

    // MARK: Hero

    private var model: ModelInfo? { app.selectedModel ?? app.recommended }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background.secondary)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.glow))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator.opacity(0.6)))

            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StatusDot(state: app.server.state)
                        Text(app.server.state.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text("KI auf deinem Mac.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Privat, offline, ohne Abo – mit einem Modell, das zu deiner Hardware passt.")
                        .font(.title3).foregroundStyle(.secondary)
                    if let model {
                        HStack(spacing: 6) {
                            Chip(text: model.name, systemImage: "cpu", tint: Theme.violet)
                            Chip(text: model.sizeGB.gb, systemImage: "internaldrive")
                            if model.isInstalled { Chip(text: "installiert", systemImage: "checkmark.seal.fill", tint: .green) }
                        }
                        .padding(.top, 4)
                    }
                    primaryAction.padding(.top, 10)
                    if !app.server.engineInstalled {
                        Text("oMLX nicht gefunden – erwartet unter \(Paths.omlx.path). Einrichtung siehe README.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                if let model { SpeedGauge(tokS: model.estimatedTokS(app.hardware), measured: model.measuredTokSOnM4 != nil && app.hardware.chip.contains("M4") && !app.hardware.chip.contains("M4 ")) }
            }
            .padding(28)
        }
        .frame(minHeight: 260)
    }

    @ViewBuilder private var primaryAction: some View {
        if let model {
            if let p = app.downloads.active[model.id] {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.fraction).frame(maxWidth: 360).tint(Theme.violet)
                    Text("\(formatBytes(p.done)) von \(formatBytes(p.total)) · \(formatBytes(Int64(p.bytesPerSecond)))/s")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if !model.isInstalled {
                Button { app.download(model) } label: { Label("\(model.name) laden", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            } else if !app.server.state.isUp {
                Button { app.server.start() } label: { Label(app.server.state == .starting ? "Startet …" : "Starten", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(app.server.state == .starting || !app.server.engineInstalled)
            } else {
                Button { screen = .agent } label: { Label("Loslegen", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: Was passt

    private var fitList: some View {
        Card {
            Text("Was auf deinen Mac passt").font(.headline)
            ForEach(ModelCatalog.all) { m in
                HStack {
                    Image(systemName: m.fits(app.hardware) ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(m.fits(app.hardware) ? .green : .secondary)
                    Text(m.name).fontWeight(m.id == app.recommended?.id ? .semibold : .regular)
                    if m.id == app.recommended?.id { Chip(text: "Empfehlung", tint: Theme.violet) }
                    Spacer()
                    Text(m.sizeGB.gb).foregroundStyle(.secondary).monospacedDigit()
                    Text(m.estimatedTokS(app.hardware).map { "~\(Int($0)) tok/s" } ?? "–")
                        .frame(width: 90, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
            }
            Text("Passt = Gewichte + 1,5 GB Reserve unter dem GPU-Limit von \(app.hardware.gpuLimitGB.gb). Geschwindigkeit aus Messungen auf einem M4, mit der Speicherbandbreite hochgerechnet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SpeedGauge: View {
    let tokS: Double?
    let measured: Bool
    @State private var shown: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(.quaternary, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * min(shown / 80, 1))
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(135))
                VStack(spacing: 0) {
                    Text(tokS.map { "\(Int($0))" } ?? "–")
                        .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("tok/s").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
            Text(measured ? "gemessen" : "geschätzt").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { withAnimation(.spring(duration: 1.2)) { shown = tokS ?? 0 } }
    }
}

struct HardwareGrid: View {
    let hw: Hardware

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            tile("cpu", "Chip", hw.chip.replacingOccurrences(of: "Apple ", with: ""))
            tile("memorychip", "Arbeitsspeicher", "\(hw.memoryGiB) GB")
            tile("square.stack.3d.down.forward", "GPU-Limit", hw.gpuLimitGB.gb)
            tile("speedometer", "Bandbreite", hw.bandwidthGBs.map { "\(Int($0)) GB/s" } ?? "unbekannt")
            tile("internaldrive", "Frei auf SSD", String(format: "%.0f GB", hw.freeDiskGB))
        }
    }

    private func tile(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.brand)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

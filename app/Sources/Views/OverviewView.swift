import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var app
    @Binding var screen: Screen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CrashBanner()
                hero
                HardwareGrid(hw: app.hardware)
                UsageCard()
                fitList
                KisruptivFooter()
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
                    Wordmark(size: 46)
                    Text("KI für alle – direkt auf deinem Mac.")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Privat, offline, ohne Abo – mit einem Modell, das zu deiner Hardware passt.")
                        .font(.title3).foregroundStyle(.secondary)
                    if let model {
                        HStack(spacing: 6) {
                            Chip(text: model.name, systemImage: "cpu", tint: Theme.primary)
                            Chip(text: model.sizeGB.gb, systemImage: "internaldrive")
                            if model.isInstalled { Chip(text: "installiert", systemImage: "checkmark.seal.fill", tint: .green) }
                        }
                        .padding(.top, 4)
                    }
                    primaryAction.padding(.top, 10)
                    if !app.server.engineInstalled || app.installer.running {
                        EngineSetupCard()
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
                    ProgressView(value: p.fraction).frame(maxWidth: 360).tint(Theme.primary)
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
                    if m.id == app.recommended?.id { Chip(text: "Empfehlung", tint: Theme.primary) }
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


/// Nutzung der Engine (wie im oMLX-Webinterface) und Zustand des Macs – aktualisiert sich alle 5 Sekunden.
struct UsageCard: View {
    @Environment(AppState.self) private var app
    @State private var alltime = true

    var body: some View {
        let u = app.usage
        Card {
            HStack {
                Label("Nutzung & Mac", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Spacer()
                Picker("", selection: $alltime) {
                    Text("Seit Engine-Start").tag(false)
                    Text("Insgesamt").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let e = alltime ? u.alltime : u.session
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                tile("text.word.spacing", "Tokens verarbeitet", e.map { Self.count($0.tokensServed) } ?? "–",
                     e.map { "\(Self.count($0.promptTokens)) rein · \(Self.count($0.completionTokens)) raus" })
                tile("arrow.left.arrow.right", "Anfragen", e.map { "\($0.requests)" } ?? "–",
                     u.activeRequests > 0 ? "\(u.activeRequests) läuft gerade" : nil)
                tile("bolt.fill", "Ø Antwort-Tempo", e.map { $0.generationTPS > 0 ? "\($0.generationTPS.oneDecimal) tok/s" : "–" } ?? "–",
                     e.map { $0.prefillTPS > 0 ? "Eingabe \(Int($0.prefillTPS)) tok/s" : nil } ?? nil)
                tile("arrow.triangle.2.circlepath", "Cache-Treffer", e.map { "\(Int($0.cacheEfficiency)) %" } ?? "–",
                     e.map { "\(Self.count($0.cachedTokens)) Tokens wiederverwendet" })
                tile("memorychip", "Modell im Speicher", u.modelMemory.map { "\(Self.gb($0.used)) von \(Self.gb($0.max))" } ?? "–",
                     u.pressure.isEmpty ? nil : "Druck: \(Self.pressure(u.pressure))")
                tile("thermometer.medium", "Temperatur", u.temperature.map { "\(Int($0.rounded())) °C" } ?? u.thermalText.capitalized,
                     u.temperature == nil ? nil : u.thermalText, warn: u.thermal == .serious || u.thermal == .critical)
                tile("clock", "Engine läuft seit", e.map { Self.duration($0.uptime) } ?? "–", nil)
                tile("cpu", "Modell", app.selectedModelName, app.server.state.isUp ? "bereit" : "Engine aus")
            }
            if u.thermal == .serious || u.thermal == .critical {
                Label("Der Mac ist heiß und drosselt – lange Agent-Läufe werden langsamer (gemessen bis −24 %). Eine harte Unterlage oder kurze Pausen helfen.",
                      systemImage: "flame").font(.caption).foregroundStyle(.orange)
            }
        }
        .task {
            while !Task.isCancelled {
                await app.usage.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func tile(_ icon: String, _ label: String, _ value: String, _ sub: String?, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(Theme.brand))
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let sub { Text(sub).font(.caption2).foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary)).lineLimit(1) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func count(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f Mio.", Double(n) / 1e6) : n >= 10_000 ? String(format: "%.1f Tsd.", Double(n) / 1e3) : "\(n)"
    }
    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    static func pressure(_ p: String) -> String { ["ok": "normal", "soft": "erhöht", "hard": "hoch"][p] ?? p }
    static func duration(_ s: Double) -> String {
        s < 3600 ? "\(Int(s / 60)) min" : String(format: "%d h %02d min", Int(s / 3600), Int(s.truncatingRemainder(dividingBy: 3600) / 60))
    }
}

/// Absender: ein Tool von KIsruptiv.
struct KisruptivFooter: View {
    var body: some View {
        HStack(spacing: 14) {
            KisruptivLogo(height: 22)
            Divider().frame(height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ein Tool von KIsruptiv – KI verständlich, nutzbar und für alle.").font(.callout)
                Text("Let’s disrupt the system together.").font(.caption).foregroundStyle(.secondary).italic()
            }
            Spacer()
            Link("kisruptiv.de", destination: URL(string: "https://kisruptiv.de")!).font(.callout.weight(.medium))
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.gold).frame(width: 4).padding(.vertical, 14)
        }
    }
}


/// Einrichtung der Engine per Klick, mit Live-Protokoll.
struct EngineSetupCard: View {
    @Environment(AppState.self) private var app
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.installer.running {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(app.installer.step).font(.callout)
                }
            } else if app.installer.finished == false {
                Label(app.installer.step, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            } else {
                Text("Die Engine (oMLX) ist noch nicht eingerichtet. Das erledigt KI/lokal für dich – ca. 5–10 Minuten, ohne Terminal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button { app.installer.install() } label: { Label("Engine einrichten", systemImage: "wrench.and.screwdriver.fill") }
                    .buttonStyle(.borderedProminent).disabled(app.installer.running)
                Button(showLog ? "Protokoll ausblenden" : "Protokoll") { showLog.toggle() }.buttonStyle(.borderless)
            }
            if showLog {
                ScrollView {
                    Text(app.installer.log.suffix(200).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 6)
    }
}


/// Hinweis nach einem Absturz: ansehen oder als GitHub-Issue melden (der Nutzer schickt selbst ab).
struct CrashBanner: View {
    @State private var reports = CrashReports.unseen()

    var body: some View {
        if let r = reports.first {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("KI/lokal ist beim letzten Mal abgestürzt").font(.headline)
                    Text("\(r.exception) · \(r.date.formatted(date: .abbreviated, time: .shortened)) – ein Bericht hilft, den Fehler zu beheben. Er enthält nur Version, macOS, Chip und die Stelle im Code.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Melden …") {
                            if let url = CrashReports.issueURL(r) { NSWorkspace.shared.open(url) }
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Bericht ansehen") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                        Button("Ignorieren") { dismiss() }
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func dismiss() {
        CrashReports.markSeen()
        reports = []
    }
}

import AppKit
import SwiftUI

/// KIsruptiv-CI (kisruptiv.de): Dunkelblau #274060, Hellblau #7590BF, Gold #FCC419.
/// Im Dunkelmodus wird das Dunkelblau zum Hellblau angehoben, damit Text und Flächen lesbar bleiben.
enum Theme {
    static let navy = Color(red: 0x27 / 255, green: 0x40 / 255, blue: 0x60 / 255)
    static let skyBlue = Color(red: 0x75 / 255, green: 0x90 / 255, blue: 0xBF / 255)
    static let gold = Color(red: 0xFC / 255, green: 0xC4 / 255, blue: 0x19 / 255)

    /// Hauptfarbe für Akzente und Text: Dunkelblau hell, Hellblau dunkel.
    static let primary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x93 / 255, green: 0xAB / 255, blue: 0xD6 / 255, alpha: 1)
            : NSColor(srgbRed: 0x27 / 255, green: 0x40 / 255, blue: 0x60 / 255, alpha: 1)
    })
    static let sky = skyBlue
    static let teal = Color(red: 0.12, green: 0.70, blue: 0.62)
    /// Flächen (Buttons, Nutzer-Blasen): immer Dunkelblau → Hellblau, weiße Schrift.
    static let brand = LinearGradient(colors: [navy, skyBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let glow = LinearGradient(colors: [skyBlue.opacity(0.30), gold.opacity(0.10), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Wortmarke im Stil des KIsruptiv-Logos: kräftiges „KI“, dünner goldener Slash, leichtes Suffix.
struct Wordmark: View {
    var suffix = "lokal"
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text("KI").font(.system(size: size, weight: .black)).kerning(-size * 0.04)
            Text("/").font(.system(size: size * 0.95, weight: .thin)).foregroundStyle(Theme.gold)
            Text(suffix).font(.system(size: size * 0.66, weight: .light))
        }
        .foregroundStyle(Theme.primary)
        .accessibilityLabel("KI \(suffix)")
    }
}

/// Original-Logo „KI/sruptiv“ (Marke von KIsruptiv), eingefärbt.
struct KisruptivLogo: View {
    var height: CGFloat = 18
    var body: some View {
        Image("KisruptivLogo").renderingMode(.template).resizable().scaledToFit()
            .frame(height: height)
            .foregroundStyle(Theme.primary)
            .accessibilityLabel("KIsruptiv")
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct StatusDot: View {
    let state: ServerController.State
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(state.color.opacity(0.5), lineWidth: 6).scaleEffect(pulse ? 1.8 : 0.6).opacity(pulse ? 0 : 1))
            .onAppear { animate() }
            .onChange(of: state) { animate() }
    }

    private func animate() {
        pulse = false
        guard state.isUp || state == .starting else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(Theme.brand, in: Capsule())
            .shadow(color: Theme.primary.opacity(0.35), radius: configuration.isPressed ? 2 : 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension ServerController.State {
    var label: String {
        switch self {
        case .stopped: return "Server aus"
        case .starting: return "Startet …"
        case .running: return "Bereit"
        case .external: return "Bereit (extern gestartet)"
        case let .failed(m): return "Fehler: \(m)"
        }
    }

    var color: Color {
        switch self {
        case .running, .external: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

extension Double {
    var gb: String { String(format: "%.1f GB", self) }
    var oneDecimal: String { String(format: "%.1f", self) }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

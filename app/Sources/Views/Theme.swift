import SwiftUI

enum Theme {
    static let violet = Color(red: 0.52, green: 0.36, blue: 1.0)
    static let blue = Color(red: 0.16, green: 0.56, blue: 1.0)
    static let teal = Color(red: 0.12, green: 0.78, blue: 0.72)
    static let brand = LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let glow = LinearGradient(colors: [violet.opacity(0.35), blue.opacity(0.15), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
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
            .shadow(color: Theme.violet.opacity(0.35), radius: configuration.isPressed ? 2 : 10, y: 4)
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

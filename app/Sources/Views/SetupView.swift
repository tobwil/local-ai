import AppKit
import AVFoundation
import EventKit
import Speech
import SwiftUI
import UserNotifications

/// Einrichtung in drei Schritten: Engine, Modell, Berechtigungen. Erscheint beim ersten Start von selbst und ist
/// später über das Menü unten in der Seitenleiste erreichbar („Einrichtung & Berechtigungen“).
struct SetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("einrichtungFertig") private var done = false
    @State private var permissions: [Permission.Kind: Permission.Status] = [:]

    private var model: ModelInfo? { app.selectedModel?.isInstalled == true ? app.selectedModel : app.recommended }
    private var engineReady: Bool { app.server.engineInstalled }
    private var modelReady: Bool { !app.installedModels.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Wordmark(size: 26)
                Spacer()
                Button("Schließen") { dismiss() }.buttonStyle(.borderless)
            }
            Text("In drei Schritten startklar").font(.title2.bold())
            Text("Alles läuft auf diesem Mac – privat und ohne Abo. Die Schritte lassen sich jederzeit wiederholen.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Engine einrichten", done: engineReady,
                         detail: engineReady ? "Die Engine (oMLX) ist installiert." : "Die Engine führt das Modell aus. KI/lokal richtet sie ein – ca. 5–10 Minuten, ohne Terminal.") {
                        if !engineReady { EngineSetupCard() }
                    }
                    step(2, "Modell laden", done: modelReady,
                         detail: modelReady ? "Installiert: \(app.installedModels.map(\.name).joined(separator: ", "))."
                                            : "Das empfohlene Modell passt zu deinem Mac\(model.map { " (\($0.name), \($0.sizeGB.gb))" } ?? "").") {
                        if !modelReady, let model { modelDownload(model) }
                    }
                    step(3, "Berechtigungen", done: Permission.Kind.allCases.allSatisfy { permissions[$0] == .granted },
                         detail: "Nur nötig für die jeweiligen Funktionen – macOS fragt einmal, du kannst es jederzeit ändern.") {
                        VStack(spacing: 6) {
                            ForEach(Permission.Kind.allCases) { kind in permissionRow(kind) }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(engineReady && modelReady ? "Los geht’s" : "Später") {
                    done = true
                    dismiss()
                    if engineReady && modelReady { app.requestedScreen = .agent }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 640)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }

    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Theme.primary.opacity(0.15)).frame(width: 30, height: 30)
                if done { Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(Theme.primary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private func modelDownload(_ model: ModelInfo) -> some View {
        if let p = app.downloads.active[model.id] {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p.fraction).tint(Theme.primary)
                Text("\(formatBytes(p.done)) von \(formatBytes(p.total)) · \(formatBytes(Int64(p.bytesPerSecond)))/s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Button { app.download(model) } label: { Label("\(model.name) laden", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(!engineReady)
            if !engineReady { Text("Erst die Engine einrichten.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func permissionRow(_ kind: Permission.Kind) -> some View {
        let status = permissions[kind] ?? .unknown
        return HStack(spacing: 10) {
            Image(systemName: kind.icon).foregroundStyle(Theme.primary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.callout.weight(.medium))
                Text(kind.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Erlaubt", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .denied:
                Button("In Einstellungen öffnen") { kind.openSettings() }.controlSize(.small)
            case .unknown:
                Button("Erlauben") { Task { await kind.request(); await refresh() } }.controlSize(.small).buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func refresh() async {
        var out: [Permission.Kind: Permission.Status] = [:]
        for kind in Permission.Kind.allCases { out[kind] = await kind.status() }
        permissions = out
    }
}

/// macOS-Berechtigungen, die KI/lokal für einzelne Funktionen braucht: Stand abfragen, anfragen, Einstellungen öffnen.
enum Permission {
    enum Status { case granted, denied, unknown }

    enum Kind: String, CaseIterable, Identifiable {
        case screen, calendar, reminders, microphone, speech, notifications
        var id: String { rawValue }

        var title: String {
            switch self {
            case .screen: return "Bildschirmaufnahme"
            case .calendar: return "Kalender"
            case .reminders: return "Erinnerungen"
            case .microphone: return "Mikrofon"
            case .speech: return "Spracherkennung"
            case .notifications: return "Mitteilungen"
            }
        }

        var why: String {
            switch self {
            case .screen: return "„Schau auf meinen Bildschirm“ und Bildschirmfotos im Chat"
            case .calendar: return "Termine lesen und auf Wunsch anlegen („Mein Tag“)"
            case .reminders: return "Erinnerungen lesen und anlegen"
            case .microphone: return "Diktieren und Sprechen mit dem Agenten"
            case .speech: return "Gesprochenes auf dem Mac in Text umwandeln"
            case .notifications: return "Ergebnisse von Automationen melden"
            }
        }

        var icon: String {
            switch self {
            case .screen: return "camera.viewfinder"
            case .calendar: return "calendar"
            case .reminders: return "checklist"
            case .microphone: return "mic"
            case .speech: return "waveform"
            case .notifications: return "bell"
            }
        }

        func status() async -> Status {
            switch self {
            case .screen: return CGPreflightScreenCaptureAccess() ? .granted : .unknown
            case .calendar: return Self.map(EKEventStore.authorizationStatus(for: .event))
            case .reminders: return Self.map(EKEventStore.authorizationStatus(for: .reminder))
            case .microphone:
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .granted
                case .denied, .restricted: return .denied
                default: return .unknown
                }
            case .speech:
                switch SFSpeechRecognizer.authorizationStatus() {
                case .authorized: return .granted
                case .denied, .restricted: return .denied
                default: return .unknown
                }
            case .notifications:
                let s = await UNUserNotificationCenter.current().notificationSettings()
                switch s.authorizationStatus {
                case .authorized, .provisional: return .granted
                case .denied: return .denied
                default: return .unknown
                }
            }
        }

        private static func map(_ s: EKAuthorizationStatus) -> Status {
            switch s {
            case .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            default: return .unknown
            }
        }

        func request() async {
            switch self {
            case .screen:
                // macOS zeigt dafür keinen Dialog in der App, sondern verweist auf die Systemeinstellungen.
                if !CGRequestScreenCaptureAccess() { openSettings() }
            case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
            case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
            case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .speech:
                _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            case .notifications:
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }

        func openSettings() {
            let anchor: String
            switch self {
            case .screen: anchor = "com.apple.preference.security?Privacy_ScreenCapture"
            case .calendar: anchor = "com.apple.preference.security?Privacy_Calendars"
            case .reminders: anchor = "com.apple.preference.security?Privacy_Reminders"
            case .microphone: anchor = "com.apple.preference.security?Privacy_Microphone"
            case .speech: anchor = "com.apple.preference.security?Privacy_SpeechRecognition"
            case .notifications: anchor = "com.apple.Notifications-Settings.extension"
            }
            if let url = URL(string: "x-apple.systempreferences:\(anchor)") { NSWorkspace.shared.open(url) }
        }
    }
}

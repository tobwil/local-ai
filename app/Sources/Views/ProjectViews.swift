import AppKit
import SwiftUI

/// Projektauswahl mittig in der Titelleiste: „Ohne Projekt“ oder ein Projekt (Code-Projekte mit Kennzeichen).
struct ProjectPicker: View {
    @Environment(AppState.self) private var app
    @State private var editing: Project?

    var body: some View {
        let session = app.session
        Menu {
            Button { session.switchProject(nil) } label: {
                Label("Ohne Projekt", systemImage: session.project == nil ? "checkmark" : "tray")
            }
            if !session.projects.projects.isEmpty {
                Section("Projekte") {
                    ForEach(session.projects.sorted) { p in
                        Button { session.switchProject(p) } label: {
                            Label(p.name, systemImage: p.id == session.project?.id ? "checkmark" : "folder")
                        }
                    }
                }
            }
            Divider()
            Button("Neues Projekt …") { editing = Project(name: "Neues Projekt") }
            if let p = session.project {
                Button("„\(p.name)“ bearbeiten …") { editing = p }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.project == nil ? "tray" : "folder.fill")
                    .foregroundStyle(session.project == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.gold))
                Text(session.project?.name ?? "Ohne Projekt").fontWeight(.semibold)
                if session.mode == .code {
                    Text("Code")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.primary.opacity(0.18), in: Capsule())
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(session.isRunning)
        .help("Projekt wählen: Ein Projekt bündelt Gespräche, einen Ordner und eigene Anweisungen.")
        .sheet(item: $editing) { ProjectEditor(project: $0) }
    }
}

struct ProjectEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var project: Project

    var body: some View {
        let session = app.session
        let exists = session.projects.project(id: project.id) != nil
        VStack(alignment: .leading, spacing: 12) {
            Text(exists ? "Projekt" : "Neues Projekt").font(.title2.bold())
            Text("Ein Projekt bündelt Gespräche, einen Ordner und eigene Anweisungen. Liegt im Ordner Code, arbeitet der Agent automatisch wie ein Coding-Agent.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $project.name)
                LabeledContent("Ordner") {
                    HStack {
                        Text(project.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "keiner")
                            .foregroundStyle(project.folder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Wählen …") { pickFolder() }
                        if project.folder != nil { Button("Entfernen") { project.folder = nil }.buttonStyle(.borderless) }
                    }
                }
                Picker("Arbeitsweise", selection: $project.kind) {
                    ForEach(Project.Kind.allCases) { k in
                        Text(k == .auto ? "Automatisch (erkannt: \(autoMode.title))" : k.title).tag(k)
                    }
                }
                Text(project.mode.help).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Anweisungen für dieses Projekt")
                    TextEditor(text: $project.instructions).font(.callout).frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    Text("z. B. Zielgruppe, Stil, Technik, Regeln – gilt für jedes Gespräch im Projekt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if exists {
                    Button("Löschen", role: .destructive) {
                        session.deleteProject(project)
                        dismiss()
                    }
                    .help("Die Gespräche bleiben erhalten und erscheinen ohne Projekt.")
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button(exists ? "Speichern" : "Anlegen") {
                    if exists { session.updateProject(project) } else { session.projects.upsert(project); session.switchProject(project) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var autoMode: WorkMode {
        var p = project
        p.kind = .auto
        return p.mode
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        if panel.runModal() == .OK, let url = panel.url {
            project.folder = url.path
            if project.name == "Neues Projekt" { project.name = url.lastPathComponent }
        }
    }
}

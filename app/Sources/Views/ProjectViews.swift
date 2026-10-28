import AppKit
import SwiftUI

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

import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    let hardware = Hardware.detect()
    let server = ServerController()
    let downloads = Downloads()
    let mcp = MCPManager()
    let session = AgentSession()

    var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModel") }
    }
    /// Wird erhöht, wenn sich installierte Modelle ändern, damit die Ansichten neu prüfen.
    private(set) var installGeneration = 0
    var useBuiltinTools = true

    init() {
        let hw = hardware
        let rec = ModelCatalog.recommended(for: hw)
        selectedModelID = UserDefaults.standard.string(forKey: "selectedModel")
            ?? ModelCatalog.all.first { $0.isInstalled && $0.fits(hw) }?.id
            ?? rec?.id ?? ModelCatalog.all[1].id
        // oMLX rechnet in GiB; knapp unter dem Metal-Limit bleiben (24-GB-Mac: 17,7).
        let limitGiB = hw.gpuLimitGB * 1e9 / 1_073_741_824
        server.memoryCeilingGiB = ((limitGiB - 0.05) * 10).rounded(.down) / 10
    }

    var recommended: ModelInfo? { ModelCatalog.recommended(for: hardware) }
    var selectedModel: ModelInfo? { ModelCatalog.model(id: selectedModelID) }

    var installedModels: [ModelInfo] {
        _ = installGeneration
        return ModelCatalog.all.filter(\.isInstalled)
    }

    var agentTools: [AgentTool] {
        (useBuiltinTools ? BuiltinTools.all { [session] in session.workspace } : []) + mcp.tools
    }

    private var booted = false

    func bootOnce() async {
        guard !booted else { return }
        booted = true
        await server.probe()
        await mcp.connectAll()
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await server.probe()
            }
        }
    }

    func download(_ model: ModelInfo) {
        downloads.start(model) { [weak self] in
            self?.installGeneration += 1
            if self?.selectedModel?.isInstalled != true { self?.selectedModelID = model.id }
        }
    }

    func moveToTrash(_ model: ModelInfo) {
        try? FileManager.default.trashItem(at: model.folder, resultingItemURL: nil)
        installGeneration += 1
    }

    func setAcceleration(_ acc: Acceleration, for model: ModelInfo) async {
        try? ModelSettingsStore.setAcceleration(acc, for: model.id)
        installGeneration += 1
        if server.state == .running { await server.restart() }
    }

    func send() {
        session.send(model: selectedModelID, tools: agentTools)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var appExecutablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Local AI.app/Contents/MacOS/Local AI"
    }
}

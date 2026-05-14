import Foundation
import TmpspaceCore

/// Persists panel data to `~/Library/Application Support/Tmpspace/panels.json`
/// with debounced auto-saving.
public actor PanelStorage: PanelStorageProtocol {

    // MARK: - Dependencies

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let autoSaveManager: AutoSaveManager

    // MARK: - In-memory cache

    private var panelCache: [UUID: PanelModel] = [:]

    // MARK: - File-system paths (nonisolated — FileManager is thread-safe)

    private nonisolated var storageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Tmpspace", isDirectory: true)
    }

    private nonisolated var storageFileURL: URL {
        storageDirectory.appendingPathComponent(Constants.panelsStorageFilename)
    }

    // MARK: - Init

    public init() throws {
        self.autoSaveManager = AutoSaveManager(
            debounceMs: Constants.autoSaveDebounceMs
        )
        try createStorageDirectoryIfNeeded()
    }

    // MARK: - PanelStorageProtocol

    public func savePanel(_ panel: PanelModel) async throws {
        var panels = try await loadAllPanelsInternal()
        panels.removeAll { $0.id == panel.id }
        panels.append(panel)
        panelCache[panel.id] = panel
        try await writePanels(panels)
    }

    public func loadAllPanels() async throws -> [PanelModel] {
        let panels = try await loadAllPanelsInternal()
        panelCache = Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0) })
        return panels
    }

    public func deletePanel(id: UUID) async throws {
        var panels = try await loadAllPanelsInternal()
        panels.removeAll { $0.id == id }
        panelCache[id] = nil
        await autoSaveManager.cancelSave(panelId: id)

        let panelDataDir = storageDirectory.appendingPathComponent(
            id.uuidString, isDirectory: true
        )
        if FileManager.default.fileExists(atPath: panelDataDir.path) {
            try? FileManager.default.removeItem(at: panelDataDir)
        }

        try await writePanels(panels)
    }

    public func panelContentDidChange(id: UUID, content: String) async {
        let panel: PanelModel

        if var cached = panelCache[id] {
            cached.content = content
            cached.lastModifiedAt = Date()
            panelCache[id] = cached
            panel = cached
        } else if let loaded = try? await loadPanelFromDisk(by: id) {
            var updated = loaded
            updated.content = content
            updated.lastModifiedAt = Date()
            panelCache[id] = updated
            panel = updated
        } else {
            let stub = PanelModel(
                id: id,
                content: content,
                title: "未命名",
                lastModifiedAt: Date()
            )
            panelCache[id] = stub
            panel = stub
        }

        await autoSaveManager.scheduleSave(
            panelId: id,
            panel: panel
        ) { [weak self] panel in
            guard let self else { return }
            try? await self.savePanel(panel)
        }
    }

    public func saveAllPanels(_ panels: [PanelModel]) async throws {
        await autoSaveManager.flushAll()
        panelCache = Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0) })
        try await writePanels(panels)
    }

    // MARK: - Internal helpers

    private func loadAllPanelsInternal() async throws -> [PanelModel] {
        guard FileManager.default.fileExists(atPath: storageFileURL.path) else {
            return []
        }

        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: storageFileURL)
        } catch {
            return []
        }

        do {
            return try decoder.decode([PanelModel].self, from: jsonData)
        } catch {
            return []
        }
    }

    private func loadPanelFromDisk(by id: UUID) async throws -> PanelModel? {
        let panels = try await loadAllPanelsInternal()
        return panels.first { $0.id == id }
    }

    private func writePanels(_ panels: [PanelModel]) async throws {
        let jsonData = try encoder.encode(panels)
        try createStorageDirectoryIfNeeded()

        // Atomic write via temp file to avoid corruption on crash.
        let tempURL = storageFileURL.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try jsonData.write(to: tempURL, options: .atomic)

        if FileManager.default.fileExists(atPath: storageFileURL.path) {
            try FileManager.default.removeItem(at: storageFileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: storageFileURL)
    }

    private nonisolated func createStorageDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}

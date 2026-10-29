import Foundation

extension ProjectModel {
    func createEntry(in folder: String, directory: Bool) async -> String? {
        let name = directory ? "untitled folder" : "untitled.tex"
        guard let made = await alerting("Couldn’t Create “\(name)”", {
            try await session.call(CreateEntry(folder: folder, name: name, dir: directory))
        }) else { return nil }
        if !directory { await open(made, focus: false) }
        return made
    }

    func renameEntry(_ from: String, to: String, action: String = String(localized: "Rename")) async {
        if let result = await performRename(from, to: to) { registerRenameUndo(from: result.from, to: result.to, action: action) }
    }

    private func registerRenameUndo(from: String, to: String, action: String) {
        app?.undoManager?.registerAsyncUndo(withTarget: self, actionName: action, reversal: {
            self.registerRenameUndo(from: to, to: from, action: action)
        }, work: {
            await self.performRename(to, to: from) != nil
        })
    }

    private func performRename(_ from: String, to: String) async -> RenameResult? {
        guard to != from, let renamed = await alerting("Couldn’t Rename “\(from.fileName)”", {
            try await session.call(Rename(from: from, to: to))
        }), let result = renamed else { return nil }
        views?.moved(from: result.from, to: result.to)
        trail.moved(result.from, to: result.to)
        let remap = { (path: String) in remapPath(path, from: result.from, to: result.to) }
        expandedFolders = Set(expandedFolders.map(remap))
        foldedHeadings = Set(foldedHeadings.map { key in key.firstIndex(of: "\t").map { remap(String(key[..<$0])) + key[$0...] } ?? key })
        return result
    }

    func deleteEntry(_ path: String) async {
        guard let original = url(path) else { return }
        let item = UndoableTrash(
            original: original, name: path.fileName, undoManager: app?.undoManager,
            trash: { [weak self] item in await self?.trashEntry(path, item) ?? false },
            changed: { [weak self] in _ = try? await self?.session.call(ReloadTree()) },
            failed: { [weak self] title, error in self?.app?.report(title, error) })
        trashed.append(item)
        await item.moveToTrash()
    }

    private func trashEntry(_ path: String, _ item: UndoableTrash) async -> Bool {
        let title = "Couldn’t Move “\(path.fileName)” to the Trash"
        guard await alerting(title, { try await session.call(PrepareDelete(path: path)) }) == true else { return false }
        do {
            try item.recycle()
        } catch {
            session.send(Deleted(path: path, trashed: false))
            app?.report(title, error)
            return false
        }
        session.send(Deleted(path: path, trashed: true))
        views?.trashed(path)
        return true
    }

    func dropFiles(_ urls: [URL], into dir: String) async {
        var outside: [URL] = []
        for url in urls {
            guard let path = projectPath(url) else { outside.append(url); continue }
            guard path.parentFolder != dir, dir != path, !dir.hasPrefix(path + "/") else { continue }
            await renameEntry(path, to: dir.isEmpty ? path.fileName : "\(dir)/\(path.fileName)", action: String(localized: "Move"))
        }
        if !outside.isEmpty { await importFiles(outside, into: dir) }
    }

    func importFiles(_ urls: [URL], into dir: String = "", conflict: ImportConflict? = nil) async {
        let request = ImportFiles(dir: dir, paths: urls.map { $0.path(percentEncoded: false) }, conflict: conflict)
        guard let clashes = await alerting("Couldn’t Add the Files", { try await session.call(request).existing.map(\.path) }) else { return }
        if conflict == nil, !clashes.isEmpty { importClash = ImportClash(urls: urls, dir: dir, names: clashes) }
    }

    func exportZip(forArxiv: Bool = false) async throws -> URL {
        guard await save() else {
            let name = openPath?.fileName ?? self.name
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "“\(name)” couldn’t be saved, so the archive would be missing its changes."),
            ])
        }
        removeExport()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        exportFolder = folder
        let url = folder.appending(path: "\(name).zip")
        try await session.call(ExportZip(dest: url.path(percentEncoded: false), forArxiv: forArxiv))
        return url
    }

    func removeExport() {
        if let exportFolder { try? FileManager.default.removeItem(at: exportFolder) }
        exportFolder = nil
    }
}

struct ImportClash {
    let urls: [URL]
    let dir: String
    let names: [String]

    var title: String {
        if names.count == 1, let name = names.first { "An item named “\(name.fileName)” already exists in this location." }
        else { "\(names.count) items with these names already exist in this location." }
    }

    var message: String {
        let replace = names.count == 1
            ? "Do you want to replace it with the one you’re copying? The one here goes to the Trash."
            : "Do you want to replace them with the ones you’re copying? The ones here go to the Trash."
        guard names.count > 1 else { return replace }
        let shown = names.prefix(3).map { "“\($0)”" }
        let more = names.count > shown.count ? ["\(names.count - shown.count) more"] : []
        return (shown + more).formatted(.list(type: .and)) + ". " + replace
    }
}

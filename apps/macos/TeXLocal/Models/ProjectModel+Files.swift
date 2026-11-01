import Foundation

extension ProjectModel {
    func createEntry(in folder: String, directory: Bool) async -> String? {
        let name = directory ? "untitled-folder" : "untitled.tex"
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
        window?.undoManager?.registerAsyncUndo(withTarget: self, actionName: action, reversal: {
            self.registerRenameUndo(from: to, to: from, action: action)
        }, work: {
            await self.performRename(to, to: from) != nil
        })
    }

    private func performRename(_ from: String, to: String) async -> RenameResult? {
        guard to != from, let renamed = await alerting("Couldn’t Rename “\(from.fileName)”", {
            try await session.call(Rename(from: from, to: to))
        }), let result = renamed else { return nil }
        trail.moved(result.from, to: result.to)
        let remap = { (path: String) in remapPath(path, from: result.from, to: result.to) }
        expandedFolders = Set(expandedFolders.map(remap))
        foldedHeadings = Set(foldedHeadings.map { key in key.firstIndex(of: "\t").map { remap(String(key[..<$0])) + key[$0...] } ?? key })
        return result
    }

    func deleteEntry(_ path: String) async {
        let item = UndoableTrash(undoManager: window?.undoManager, trash: { [weak self] in
            await self?.trashEntry(path)
        }, putBack: { [weak self] trashed in
            guard let self else { return false }
            return await alerting("Couldn’t Put “\(path.fileName)” Back") {
                try await session.call(PutBack(path: path, trashed: trashed))
            } != nil
        })
        trashed.append(item)
        await item.moveToTrash()
    }

    private func trashEntry(_ path: String) async -> String? {
        let title = "Couldn’t Move “\(path.fileName)” to the Trash"
        guard let trashed = await alerting(title, { try await session.call(Trash(path: path)) }) ?? nil else { return nil }
        views?.trashed(path)
        return trashed
    }

    func dropFiles(_ urls: [URL], into dir: String) async {
        var outside: [URL] = []
        for url in urls {
            guard let path = projectPath(url) else { outside.append(url); continue }
            guard path.parentFolder != dir, !dir.isWithin(path) else { continue }
            await renameEntry(path, to: dir.isEmpty ? path.fileName : "\(dir)/\(path.fileName)", action: String(localized: "Move"))
        }
        if !outside.isEmpty { await importFiles(outside, into: dir) }
    }

    func dropAction(for url: URL) -> DropAction? {
        guard let path = projectPath(url) else { return includeGraphics(url.lastPathComponent) == nil ? nil : .copy }
        guard tree.node(at: path) != nil else { return nil }
        return includeGraphics(path).map(DropAction.insert) ?? .open(path)
    }

    func importFiles(_ urls: [URL], into dir: String = "", conflict: ImportConflict? = nil) async {
        let request = ImportFiles(dir: dir, paths: urls.map { $0.path(percentEncoded: false) }, conflict: conflict)
        guard let clashes = await alerting("Couldn’t Add the Files", { try await session.call(request).existing.map(\.path) }) else { return }
        if conflict == nil, !clashes.isEmpty { importClash = ImportClash(urls: urls, dir: dir, names: clashes) }
    }

    func exportZip(forArxiv: Bool = false) async throws -> URL {
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

enum DropAction: Equatable { case insert(String), copy, open(String) }

struct ImportClash {
    let urls: [URL]
    let dir: String
    let names: [String]

    var title: String {
        if names.count == 1 { "An item named “\(names[0].fileName)” already exists in this location." }
        else { "\(names.count) items with these names already exist in this location." }
    }

    var message: String {
        guard names.count > 1 else { return "Do you want to replace it with the one you’re copying? The one here goes to the Trash." }
        let shown = names.prefix(3).map { "“\($0)”" }
        let more = names.count > shown.count ? ["\(names.count - shown.count) more"] : []
        return (shown + more).formatted(.list(type: .and))
            + ". Do you want to replace them with the ones you’re copying? The ones here go to the Trash."
    }
}

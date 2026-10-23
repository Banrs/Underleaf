import Foundation

/// The session moves and holds documents as they are renamed or trashed; the Trash and undo are the app's.
extension ProjectModel {
    func createEntry(in folder: String, directory: Bool) async -> String? {
        let name = directory ? "untitled folder" : "untitled.tex"
        guard let made = await alerting("Couldn’t Create “\(name)”", {
            try await core.call("create_entry", ["id": id, "path": folder.isEmpty ? name : "\(folder)/\(name)", "dir": directory],
                                as: PathEvent.self).path
        }), !closed else { return nil }
        // For the sidebar's rename that follows, whether or not the open below is overtaken.
        await tree.reload()
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

    /// The session saves first and moves its documents and the sidebar's state, written first; the editor keeps its text
    /// and undo under the new name.
    private func performRename(_ from: String, to: String) async -> RenameResult? {
        guard to != from, let session, !closed else { return nil }
        let (before, wasText) = (openPath, editsText)
        await uiStateWrites?.value
        guard let renamed = await alerting("Couldn’t Rename “\(from.fileName)”", {
            try await core.call("session_rename", ["session": session, "from": from, "to": to], as: RenameResult?.self)
        }), let result = renamed, !closed else { return nil }
        editor.rename(from: result.from, to: result.to)
        let now = before.map { remapPath($0, from: result.from, to: result.to) }
        let moved = now != before && (openPath == before || openPath == now)
        if moved { openPath = now }
        let mainChanged = result.mainFile != settings?.mainFile
        settings?.mainFile = result.mainFile
        await tree.reload()
        showUIState(result.ui)
        if moved, let now, openPath == now, !closed {
            if isText(now) != wasText {
                if wasText { _ = await closeDocument(now) }
                if openPath == now { clearOpenFile() }
                await open(now, focus: false, showsSource: false)
            } else {
                analyze()
            }
        }
        if mainChanged, !closed { mainFileChanged() }
        return result
    }

    func deleteEntry(_ path: String) async {
        guard let original = url(path) else { return }
        let item = UndoableTrash(
            original: original, name: path.fileName, undoManager: app?.undoManager,
            trash: { [weak self] item in await self?.trashEntry(path, item) ?? false },
            changed: { [weak self] in await self?.tree.reload() },
            failed: { [weak self] title, error in self?.app?.report(error, title) })
        trashed.append(item)
        await item.moveToTrash()
    }

    /// The session saves and holds its saves under `path`, so no autosave makes the file again, and refuses the main file.
    private func trashEntry(_ path: String, _ item: UndoableTrash) async -> Bool {
        guard let session, !closed else { return false }
        let title = "Couldn’t Move “\(path.fileName)” to the Trash"
        do {
            guard try await core.call("session_prepare_delete", ["session": session, "path": path], as: Ready.self).ready,
                  !closed else { return false }
        } catch {
            guard !closed else { return false }
            app?.report(error, title)
            return false
        }
        do {
            try item.recycle()
        } catch {
            core.send("session_deleted", ["session": session, "path": path, "trashed": false])
            app?.report(error, title)
            return false
        }
        core.send("session_deleted", ["session": session, "path": path])
        editor.forget(path: path)
        if let open = openPath, open == path || open.hasPrefix(path + "/") { clearOpenFile() }
        return true
    }

    func clearOpenFile() {
        openPath = nil
        analyze()
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

    func importFiles(_ urls: [URL], into dir: String = "", conflict: String? = nil) async {
        let args: [String: any Sendable] = ["id": id, "dir": dir, "paths": urls.map { $0.path(percentEncoded: false) }, "conflict": conflict]
        do {
            let clashes = try await core.call("import_files", args, as: Imported.self).existing.map(\.path)
            if conflict == nil, !clashes.isEmpty { importClash = ImportClash(urls: urls, dir: dir, names: clashes) }
        } catch {
            app?.report(error, "Couldn’t Add the Files")
        }
        // After a failure too: files copied before it are there.
        await tree.reload()
    }

    // MARK: - Export

    /// The core archives the files on disk, so the edits are saved first.
    func exportZip() async throws -> URL {
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
        try await core.call("export_zip", ["id": id, "dest": url.path(percentEncoded: false)])
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

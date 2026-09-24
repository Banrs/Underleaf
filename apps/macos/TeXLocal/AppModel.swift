import AppKit
import Observation

/// The library: projects on disk, TeX availability, and the open project.
@MainActor @Observable
final class AppModel {
    var projects: [ProjectInfo] = []
    var tex: TexStatus?
    var project: ProjectModel?
    var alert: String?

    // Requests from commands to the views that own the matching UI.
    var showNewProject = false
    var prompt: Prompt?
    var searchFocusToken = 0
    var pdfRequest: (action: PDFAction, token: Int)?
    var sidebarVisible = true
    private var pdfToken = 0

    func requestPDF(_ action: PDFAction) {
        pdfToken += 1
        pdfRequest = (action, pdfToken)
    }

    /// One editor for the app's lifetime, handed from project to project.
    let editor = EditorBridge()

    private let core = Core.shared

    func refresh() async {
        do {
            projects = try await core.call("list_projects", as: [ProjectInfo].self)
                .sorted { $0.mtime > $1.mtime }
        } catch {
            alert = error.localizedDescription
        }
        tex = try? await core.call("status", as: TexStatus.self)
    }

    /// While TeX is missing, look again now and then so installing it takes
    /// effect without a restart of this screen.
    func watchForTeX() async {
        while !(tex?.available ?? true), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            tex = try? await core.call("status", as: TexStatus.self)
        }
    }

    func create(name: String, template: String) async {
        do {
            let info = try await core.call("create_project", ["name": name, "template": template], as: ProjectInfo.self)
            await refresh()
            await open(info.id)
        } catch {
            alert = error.localizedDescription
        }
    }

    func rename(_ project: ProjectInfo, to name: String) async {
        do {
            _ = try await core.call("rename_project", ["id": project.id, "name": name], as: ProjectInfo.self)
        } catch {
            alert = error.localizedDescription
        }
        await refresh()
    }

    func delete(_ project: ProjectInfo) async {
        do {
            try await core.perform("delete_project", ["id": project.id])
        } catch {
            alert = error.localizedDescription
        }
        await refresh()
    }

    func open(_ id: String) async {
        guard await close() else { return }
        let model = ProjectModel(id: id, editor: editor, app: self)
        project = model
        await model.load()
    }

    /// Save, then leave the project. Returns false — and stays — when the save
    /// fails, rather than dropping the only copy of the edits.
    @discardableResult
    func close() async -> Bool {
        guard let project else { return true }
        guard await project.flush() else { return false }
        self.project = nil
        await refresh()
        return true
    }
}

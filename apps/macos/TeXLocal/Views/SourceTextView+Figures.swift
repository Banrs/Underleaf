import AppKit

extension SourceTextView {
    private func files(_ board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func dragOperation(_ info: any NSDraggingInfo, textViews own: () -> NSDragOperation) -> NSDragOperation {
        let files = files(info.draggingPasteboard)
        guard !files.isEmpty else { return own() }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return [] }
        if case .open = drop {} else {
            guard isEditable else { return [] }
            _ = own()
        }
        return info.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation { dragOperation(info) { super.draggingEntered(info) } }
    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation { dragOperation(info) { super.draggingUpdated(info) } }

    override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
        let files = files(info.draggingPasteboard)
        guard !files.isEmpty else { return super.performDragOperation(info) }
        guard let drop = files.lazy.compactMap(fileDrop).first else { return false }
        if case .open(let open) = drop {
            open()
            return true
        }
        guard isEditable else { return false }
        setSelectedRange(.caret(characterIndexForInsertion(at: convert(info.draggingLocation, from: nil))))
        window?.makeFirstResponder(self)
        Task.immediate { await insertFigure(drop) }
        return true
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let drop = pasted(NSPasteboard.general) else { return super.paste(sender) }
        Task.immediate { await insertFigure(drop) }
    }

    func pasted(_ board: NSPasteboard) -> FileDrop? {
        let figure = files(board).lazy.compactMap(fileDrop).first { if case .open = $0 { false } else { true } }
        return figure ?? pastedImage(board)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, NSPasteboard.general.availableType(from: [.png, .tiff]) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    private func pastedImage(_ board: NSPasteboard) -> FileDrop? {
        guard board.string(forType: .string) == nil,
              let png = board.data(forType: .png)
                ?? board.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        else { return nil }
        return figure(png, as: "png")
    }

    private func figure(_ data: Data, as type: String) -> FileDrop? {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: String(localized: "Pasted Graphic") + "." + type)
        let gone = { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: file)) != nil, case .copy(let copy) = fileDrop(file) else {
            gone()
            return nil
        }
        return .copy {
            defer { gone() }
            return await copy()
        }
    }

    private static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    /// What Continuity Camera's items can come as; Services return only types the app registered at launch.
    static let imported: [NSPasteboard.PasteboardType] = [.pdf, jpeg, .png, .tiff]

    // Continuity Camera offers Take Photo, Scan Documents and Add Sketch to a requestor for images.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, isEditable, Self.imported.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// A scan's PDF and a photo's JPEG stay as they come, since LaTeX includes both.
    override func readSelection(from board: NSPasteboard) -> Bool {
        guard isEditable, board.string(forType: .string) == nil,
              let drop = board.data(forType: .pdf).flatMap({ figure($0, as: "pdf") })
                ?? board.data(forType: Self.jpeg).flatMap({ figure($0, as: "jpg") }) ?? pastedImage(board)
        else { return super.readSelection(from: board) }
        Task.immediate { await insertFigure(drop) }
        return true
    }

    func insertFigure(_ drop: FileDrop) async {
        let shown = document, at = selection, version = document.version
        let text: String? = switch drop {
        case .open: nil
        case .insert(let text): text
        case .copy(let copy): await copy()
        }
        guard let text else { return }
        guard document === shown, isEditable else { return NSSound.beep() }
        let target = document.version == version ? at : .caret(caret)
        apply([TextEdit(target, text)], named: String(localized: "Insert Figure"),
              selecting: [NSRange(location: target.location, length: (text as NSString).length)])
    }
}

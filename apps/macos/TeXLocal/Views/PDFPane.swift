import SwiftUI

struct PDFEmptyState: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    let project: ProjectModel

    var body: some View {
        content
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.textSurface)
    }

    @ViewBuilder
    private var content: some View {
        if app.installingTeX {
            ContentUnavailableView {
                Label("Installing TinyTeX…", systemImage: "richtext.page")
            } description: {
                Text("This can take a few minutes.")
            } actions: {
                ProgressView()
            }
        } else if app.tex?.available == false {
            ContentUnavailableView {
                Label("TeX Isn’t Installed", systemImage: "richtext.page")
            } description: {
                Text("Install TinyTeX to compile, or get MacTeX, the full TeX distribution.")
            } actions: {
                Button("Install TinyTeX") {
                    Task {
                        do { try await app.installTeX() } catch { window.report("Couldn’t Install TinyTeX", error) }
                    }
                }
                Link("Get MacTeX", destination: Links.mactex)
            }
        } else if project.compiling {
            ContentUnavailableView {
                Label("Compiling…", systemImage: "richtext.page")
            } actions: {
                ProgressView()
            }
        } else if project.result?.failed == true {
            ContentUnavailableView {
                Label("Build Failed", systemImage: "exclamationmark.octagon")
            } description: {
                Text("The build made no PDF. The Issues navigator shows what went wrong.")
            } actions: {
                Button("Show Issues") { project.showNavigator(.issues) }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Yet", systemImage: "richtext.page")
            } description: {
                Text("Compile to preview your document.")
            } actions: {
                Button("Compile") { window.perform(.compileRun, on: project) }
                    .disabled(!app.isEnabled(.compileRun, on: project))
            }
        }
    }
}

struct ScaleMenuItems: View {
    let pdf: PDFController

    var body: some View {
        Picker("Zoom", selection: Binding(get: { shown }, set: pdf.apply)) {
            Text("Fit Width").tag(Zoom.fitWidth)
            Text("Fit Page").tag(Zoom.fitPage)
            Divider()
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { scale in
                Text(scale.formatted(.percent)).tag(Zoom.scale(scale))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var shown: Zoom {
        guard case .scale(let scale) = pdf.zoom else { return pdf.zoom }
        return .scale((scale * 100).rounded() / 100)
    }
}

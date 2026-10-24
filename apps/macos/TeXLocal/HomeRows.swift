import SwiftUI

/// What both Homes show alike: the library unreadable, no projects, a project's row and a template's card.
struct LibraryUnavailable: View {
    @Environment(AppModel.self) private var app
    let problem: AppAlert

    var body: some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(problem.message)
        } actions: {
            Button("Try Again") { Task { await app.retryLibrary() } }
        }
    }
}

/// In the section, not over the list, so the templates stay in view.
struct NoProjects: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "text.document")
            } description: {
                Text("Choose a template above, or open or drop a folder, .tex file or .zip.")
            } actions: {
                Button("Open…") { app.openingProject = true }
            }
        }
    }
}

struct ProjectLabel<Name: View>: View {
    let detail: Text
    var symbol = "text.document"
    var dimmed = false
    let progress: String?
    @ViewBuilder let name: Name

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    name.foregroundStyle(dimmed ? HierarchicalShapeStyle.tertiary : .primary)
                    detail.font(.subheadline).foregroundStyle(dimmed ? HierarchicalShapeStyle.tertiary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } icon: {
                // Grey, as the detail: the hierarchical style would tint it the accent.
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(dimmed ? Color(nsColor: .tertiaryLabelColor) : .secondary)
            }
            if let progress {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(progress)
            }
        }
    }
}

/// A drawing of the template's first page with its name under it.
struct TemplateCard: View {
    let template: ProjectTemplate
    /// A US Letter page, 120 pt wide, its corner drawn to look like paper.
    static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 8) {
            PagePreview(template: template)
                .frame(width: Self.page.width, height: Self.page.height)
                // White paper in either appearance, dimmed a little in dark mode.
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1), in: paper)
                .overlay { paper.strokeBorder(.separator) }
                .environment(\.colorScheme, .light)
                // The card reads as its name ("Blank", not "Add, Blank").
                .accessibilityHidden(true)
            Text(template.title)
        }
        .accessibilityElement(children: .combine)
    }
}

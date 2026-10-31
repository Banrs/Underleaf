import SwiftUI

struct DialogSheet<Fields: View>: View {
    let title: String
    var message: String?
    let action: String
    let enabled: Bool
    let submit: () async throws -> Void
    @ViewBuilder var fields: Fields
    @Environment(\.dismiss) private var dismiss
    @State private var submitting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scenePadding([.horizontal, .top])
            Form {
                Section {
                    fields
                } footer: {
                    if let failure { FailureText(text: failure) }
                }
            }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 390)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(submitting) }
            ToolbarItem(placement: .confirmationAction) {
                Button(action) {
                    (submitting, failure) = (true, nil)
                    Task {
                        do { try await submit(); dismiss() } catch { failure = error.localizedDescription }
                        submitting = false
                    }
                }
                .disabled(!enabled || submitting)
            }
        }
    }
}

struct DialogField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    let focus: FocusState<Bool>.Binding

    var body: some View {
        let fit = typeset(text.isEmpty ? prompt : text, in: .systemFont(ofSize: NSFont.systemFontSize)).width
        HStack {
            Text(label)
                .accessibilityHidden(true)
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .focused(focus)
                .frame(idealWidth: 0, maxWidth: fit.rounded(.up))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct FailureText: View {
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        .onChange(of: text, initial: true) { AccessibilityNotification.Announcement(text).post() }
    }
}

import Testing
@testable import TeXLocal

@MainActor
struct BuildIssueTests {
    @Test func identicalWarningsHaveDistinctStableIDsAcrossFiltering() {
        let warning = LogItem(type: "warning", file: "main.tex", line: 12, message: "Citation undefined.")
        let unrelated = LogItem(type: "warning", file: "main.tex", line: 20, message: "Overfull hbox.")
        let rows = BuildIssueRows(errors: [], warnings: [warning, warning, unrelated])

        let all = rows.visible(filter: "", showWarnings: true)
        let filtered = rows.visible(filter: "citation", showWarnings: true)

        #expect(all.count == 3)
        #expect(all[0].id != all[1].id)
        #expect(filtered.map(\.id) == Array(all.prefix(2)).map(\.id))
        #expect(BuildIssueRows.retainedSelection(all[1].id, in: filtered) == all[1].id)
    }

    @Test func filteringAndWarningToggleClearSelectionWhenIssueIsHidden() {
        let error = LogItem(type: "error", file: "main.tex", line: 5, message: "Undefined command.")
        let warning = LogItem(type: "warning", file: "main.tex", line: 12, message: "Citation undefined.")
        let rows = BuildIssueRows(errors: [error], warnings: [warning])
        let all = rows.visible(filter: "", showWarnings: true)
        let selectedError = all[0].id
        let selectedWarning = all[1].id
        let warningsHidden = rows.visible(filter: "", showWarnings: false)

        #expect(rows.visible(filter: "other", showWarnings: true).isEmpty)
        #expect(BuildIssueRows.retainedSelection(selectedWarning, in: warningsHidden) == nil)
        #expect(BuildIssueRows.retainedSelection(selectedError, in: warningsHidden) == selectedError)
        #expect(BuildIssueRows.retainedSelection(selectedWarning, in: rows.visible(filter: "other", showWarnings: true)) == nil)
        let removed = BuildIssueRows(errors: [error], warnings: []).visible(filter: "", showWarnings: true)
        #expect(BuildIssueRows.retainedSelection(selectedWarning, in: removed) == nil)
    }

    @Test func changedPayloadInANewResultDoesNotRetainSelection() {
        let original = LogItem(type: "warning", file: "main.tex", line: 12, message: "Citation undefined.")
        let changed = LogItem(type: "warning", file: "main.tex", line: 12, message: "Citation now defined.")
        let oldSelection = BuildIssueRows(errors: [], warnings: [original]).visible(filter: "", showWarnings: true)[0].id
        let newVisible = BuildIssueRows(errors: [], warnings: [changed]).visible(filter: "", showWarnings: true)

        #expect(BuildIssueRows.retainedSelection(oldSelection, in: newVisible) == nil)
    }
}

import Foundation
import Testing
@testable import TeXLocal

struct EditorTests {
    @Test func highlightsMapToTheAppsKinds() {
        let document = SourceDocument(text: "\\emph{a} $x$ % note")
        let kinds = Set(document.highlights(in: NSRange(location: 0, length: 19)).map(\.kind))
        #expect(kinds == [.command, .maths, .comment])
    }

    @Test func theCoresAnswersDecode() throws {
        let document = SourceDocument(text: "\\section{Intro}\nSome $x^2$ text\n\\sec")
        let completions = try #require(document.completions(caret: 36, explicit: false))
        #expect(completions.items.contains { $0.label == "\\section" })
        let heading = try #require(document.setHeading(caret: 3, command: "subsection"))
        #expect(heading.edit.text == "\\subsection{Intro}")
        #expect(document.mathAt(caret: 22) == MathPreview(start: 21, tex: "x^2", display: false))
        #expect(document.folds() == [SourceDocument.Fold(line: 1, end: 3)])
        #expect(document.toggleComment([NSRange(location: 0, length: 0)]).first?.text == "% ")
        #expect(document.words(in: NSRange(location: 16, length: 15)) == 2)
    }

    @Test func textStylesSayHowToTakeAStyleOff() {
        let document = SourceDocument(text: "\\textbf{bold} word")
        let styles = document.textStyles(NSRange(location: 9, length: 2))
        #expect(styles.bold?.isEmpty == false)
        #expect(styles.italic == nil)
    }

    @Test func editsChangeTheText() {
        let document = SourceDocument(text: "one\ntwo")
        _ = document.edit(NSRange(location: 4, length: 3), with: "2", changing: nil, mirroring: false)
        #expect(document.text == "one\n2")
        #expect(document.lineCount == 2)
        #expect(document.line(at: 4) == 2)
    }
}

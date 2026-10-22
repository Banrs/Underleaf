import Testing
@testable import TeXLocal

struct VersionHistoryTests {
    @Test func theComparisonIsAUnifiedLineDiffFoldingWhatIsFarFromAChange() {
        let rows = lineDiff("1\n2\n3\n4\n5\n6\n7\n8\n", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\n", context: 1)
        #expect(rows == [.same("1"), .removed("2"), .added("two"), .same("3"), .skipped(4), .same("8"), .added("9")])
    }
}

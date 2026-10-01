import AppKit
import CoreText
import Testing
@testable import TeXLocal

@MainActor
struct ZoomFontTests {
    @Test func tabularDigitsKeepTheNativeSemiboldFont() throws {
        let native = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let nativeTraits = native.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let nativeWeight = try #require(nativeTraits?[.weight] as? NSNumber)
        let tabular = try #require(zoomFontWithTabularNumbers(native))

        #expect(tabular.pointSize == native.pointSize)
        #expect(tabular.fontDescriptor.postscriptName == native.fontDescriptor.postscriptName)
        let tabularTraits = tabular.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        #expect((tabularTraits?[.weight] as? NSNumber) == nativeWeight)

        let features = tabular.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
        #expect(features?.contains {
            $0[.typeIdentifier] == kNumberSpacingType && $0[.selectorIdentifier] == kMonospacedNumbersSelector
        } == true)
    }
}

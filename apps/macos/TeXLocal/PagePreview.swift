import SwiftUI

struct PagePreview: View {
    let template: ProjectTemplate

    var body: some View {
        switch template {
        case .blank:
            Image(systemName: "plus")
                .font(.largeTitle)
                .fontWeight(.light)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .article:
            VStack(spacing: 5) {
                bar(64, 5).padding(.top, 16)
                bar(40, 3)
                bar(52, 3).padding(.bottom, 6)
                ForEach(0..<2, id: \.self) { _ in bar(78, 2) }
                bar(60, 2).padding(.bottom, 4)
                HStack { bar(40, 3); Spacer() }.padding(.horizontal, 16)
                ForEach(0..<4, id: \.self) { _ in bar(88, 2) }
                bar(50, 2)
                Spacer(minLength: 0)
            }
        case .report:
            VStack(spacing: 6) {
                Spacer()
                bar(70, 6)
                bar(46, 3)
                bar(36, 3)
                Spacer()
                bar(30, 2).padding(.bottom, 18)
            }
        case .beamer:
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    Rectangle().fill(.tint.secondary).frame(height: 14)
                    bar(60, 4)
                    bar(40, 3)
                    Spacer()
                }
                .frame(width: 104, height: 58)
                .overlay(Rectangle().strokeBorder(.separator))
                Spacer()
            }
        }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View { Capsule().fill(.tertiary).frame(width: width, height: height) }
}

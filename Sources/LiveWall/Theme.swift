import SwiftUI

/// LiveWall's design language in one place. The brand is "golden hour" — the
/// amber of the app icon's sunset — used sparingly: only things that are
/// selected, playing or primary wear it. Everything else stays neutral so the
/// wallpapers themselves provide the colour.
enum Brand {
    /// Primary accent, sampled from the icon's sky gradient.
    static let accent = Color(red: 0.96, green: 0.62, blue: 0.22)
    /// Lighter tint for highlights on dark imagery.
    static let glow = Color(red: 1.0, green: 0.82, blue: 0.48)

    enum Radius {
        static let hero: CGFloat = 26
        static let card: CGFloat = 16
        static let tile: CGFloat = 14
    }

    enum Spacing {
        static let page: CGFloat = 28
        static let section: CGFloat = 36
        static let gridColumn: CGFloat = 22
        static let gridRow: CGFloat = 28
    }

    enum Font {
        static let display = SwiftUI.Font.system(size: 38, weight: .bold)
        static let section = SwiftUI.Font.system(size: 22, weight: .bold)
        static let eyebrow = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let tileTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        static let meta = SwiftUI.Font.system(size: 12)
    }

    /// The one spring every interactive state change uses, so motion feels
    /// like a single system rather than a collection of effects.
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
}

private struct IsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the library is mid-scroll. Hover effects stand down so
    /// content sliding under a still cursor doesn't light tiles up.
    var isScrolling: Bool {
        get { self[IsScrollingKey.self] }
        set { self[IsScrollingKey.self] = newValue }
    }
}

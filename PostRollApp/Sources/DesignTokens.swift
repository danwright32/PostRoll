import SwiftUI

// MARK: - Colors
// Mirrors the brand palette used in the Python asset generators.

extension Color {
    /// Main window / detail background — warm off-white
    static let cream     = Color(red: 252/255, green: 250/255, blue: 247/255)
    /// Sidebar / secondary surface — slightly deeper cream
    static let creamDeep = Color(red: 237/255, green: 232/255, blue: 224/255)
    /// Dividers, subtle borders
    static let creamEdge = Color(red: 212/255, green: 201/255, blue: 192/255)

    /// Primary accent — rose gold
    static let roseGold  = Color(red: 160/255, green: 105/255, blue:  95/255)
    /// Pressed / active rose gold
    static let roseDeep  = Color(red: 125/255, green:  78/255, blue:  68/255)

    /// Primary text — warm near-black
    static let warmDark  = Color(red:  60/255, green:  55/255, blue:  50/255)
    /// Secondary text — warm mid-tone
    static let warmMid   = Color(red: 122/255, green: 104/255, blue:  96/255)
    /// Placeholder / tertiary
    static let warmFaint = Color(red: 175/255, green: 160/255, blue: 152/255)
}

// MARK: - Fonts

extension Font {
    /// SignPainter: display / event-name headline
    static func signPainter(_ size: CGFloat) -> Font {
        .custom("SignPainter-HouseScript", size: size)
    }

    /// Helvetica Neue Light: UI labels, metadata
    static func light(_ size: CGFloat) -> Font {
        .custom("HelveticaNeue-Light", size: size)
    }
}

// MARK: - Corner Radii

enum Radius {
    static let xs:   CGFloat = 4
    static let sm:   CGFloat = 6
    static let md:   CGFloat = 8
    static let lg:   CGFloat = 12
}

// MARK: - Spacing

enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
}

// MARK: - RoseGold Divider

struct RoseGoldDivider: View {
    var opacity: Double = 0.6
    var body: some View {
        Rectangle()
            .fill(Color.roseGold.opacity(opacity))
            .frame(height: 0.5)
    }
}

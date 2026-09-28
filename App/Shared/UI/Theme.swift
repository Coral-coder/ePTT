import SwiftUI

/// NXTPTT's "Aero × Grid" look: Frutiger Aero glass on a Tron Legacy light grid.
/// Everything is cyan; transmitting is the same cyan pushed to white-hot.
enum NX {
    // MARK: Color

    static let cyan = Color(hex: 0x00E5FF)
    static let ice = Color(hex: 0x6FF6FF)
    static let frost = Color(hex: 0xBFF9FF)
    static let whiteHot = Color(hex: 0xE6FFFF)

    static let text = Color(hex: 0xE6FBFF)
    static let textDim = Color(hex: 0x9FE9F5)
    static let textMuted = Color(hex: 0x8FCFDB)
    /// Text drawn on the glass orb.
    static let ink = Color(hex: 0x022238)

    static let deep = [Color(hex: 0x06223A), Color(hex: 0x03111F), Color(hex: 0x020812), Color(hex: 0x01040A)]
    static let rowFill = Color(hex: 0x0A3350).opacity(0.55)

    // MARK: Type (bundled fonts; system fonts if a face fails to load)

    /// Michroma: the wide wordmark and numerals.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Michroma-Regular", size: size, relativeTo: style)
    }

    /// Exo 2: labels, headings and buttons.
    static func label(_ size: CGFloat, _ weight: LabelWeight = .bold, relativeTo style: Font.TextStyle = .headline) -> Font {
        .custom(weight.postScriptName, size: size, relativeTo: style)
    }

    /// Hind: body copy (a Frutiger-style humanist sans).
    static func body(_ size: CGFloat, _ weight: BodyWeight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.postScriptName, size: size, relativeTo: style)
    }

    enum LabelWeight {
        case medium, semibold, bold
        var postScriptName: String {
            switch self {
            case .medium: return "Exo2-Medium"
            case .semibold: return "Exo2-SemiBold"
            case .bold: return "Exo2-Bold"
            }
        }
    }

    enum BodyWeight {
        case regular, medium, semibold
        var postScriptName: String {
            switch self {
            case .regular: return "Hind-Regular"
            case .medium: return "Hind-Medium"
            case .semibold: return "Hind-SemiBold"
            }
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Glass

/// A Frutiger Aero glass surface: translucent gradient body, a glossy highlight across the top,
/// a light-line border and a soft cyan glow.
struct GlassBackground<S: InsettableShape>: View {
    var shape: S
    var glow: Double = 0.18
    var strong = false

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(
                colors: strong
                    ? [Color(hex: 0x8CE6FF, opacity: 0.30), Color(hex: 0x0A3250, opacity: 0.35)]
                    : [Color(hex: 0x78DCFF, opacity: 0.22), Color(hex: 0x28789F, opacity: 0.12), Color(hex: 0x0A2846, opacity: 0.32)],
                startPoint: .top, endPoint: .bottom))
            GeometryReader { geo in
                shape
                    .fill(LinearGradient(colors: [.white.opacity(strong ? 0.36 : 0.30), .white.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: min(geo.size.height * 0.46, 34))
                    .padding(.horizontal, 10)
                    .padding(.top, 3)
            }
            shape.strokeBorder(LinearGradient(colors: [NX.frost.opacity(0.75), NX.ice.opacity(0.25)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: NX.cyan.opacity(glow), radius: 12)
    }
}

extension View {
    /// Glass panel background in a rounded rectangle.
    func glass(cornerRadius: CGFloat = 22, glow: Double = 0.18, strong: Bool = false) -> some View {
        background(GlassBackground(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                   glow: glow, strong: strong))
    }

    /// Glass capsule background.
    func glassCapsule(glow: Double = 0.18, strong: Bool = false) -> some View {
        background(GlassBackground(shape: Capsule(style: .continuous), glow: glow, strong: strong))
    }

    /// Soft neon glow for text and strokes.
    func neonGlow(_ color: Color = NX.cyan, radius: CGFloat = 8) -> some View {
        shadow(color: color, radius: radius / 2).shadow(color: color.opacity(0.6), radius: radius)
    }
}

/// A small glossy sphere: avatars, the "new" button, the channel icon.
struct GelBead<Content: View>: View {
    var size: CGFloat = 44
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0xBDFCFF), Color(hex: 0x19C6EC), Color(hex: 0x04506F)],
                                         center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: size * 0.7))
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.62, height: size * 0.38)
                .offset(y: -size * 0.24)
            content.foregroundStyle(NX.ink)
        }
        .frame(width: size, height: size)
        .shadow(color: NX.cyan.opacity(0.7), radius: 6)
    }
}

/// Section caption: spaced-out Exo 2 small caps.
struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(NX.label(12, .semibold, relativeTo: .caption))
            .tracking(4)
            .foregroundStyle(NX.ice)
            .accessibilityAddTraits(.isHeader)
    }
}

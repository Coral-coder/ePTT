import SwiftUI
import EPTTCore

// MARK: - Tabs

enum NXTab: String, CaseIterable, Identifiable {
    case talk, channels, pair, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .talk: return "Talk"
        case .channels: return "Channels"
        case .pair: return "Pair"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .talk: return "mic"
        case .channels: return "list.bullet"
        case .pair: return "qrcode"
        case .activity: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Floating glass tab bar with neon-lit selection.
struct NeonTabBar: View {
    @Binding var selection: NXTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NXTab.allCases) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 19, weight: .medium))
                        Text(tab.title)
                            .font(NX.label(11, .semibold, relativeTo: .caption2))
                            .tracking(0.6)
                    }
                    .foregroundStyle(active ? Color(hex: 0xAEFCFF) : Color(hex: 0x6FA9B8))
                    .shadow(color: active ? NX.cyan : .clear, radius: 6)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial)
                GlassBackground(shape: RoundedRectangle(cornerRadius: 26, style: .continuous), glow: 0.2)
            }
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Controls

/// Glossy primary button (gel) and secondary glass button.
struct NXButtonStyle: ButtonStyle {
    enum Kind { case gel, glass }
    var kind: Kind = .glass

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NX.label(14, .bold))
            .tracking(2)
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .frame(maxWidth: .infinity)
            .foregroundStyle(kind == .gel ? NX.ink : Color(hex: 0xCFFBFF))
            .background {
                if kind == .gel {
                    ZStack {
                        Capsule().fill(RadialGradient(colors: [Color(hex: 0xC9FDFF), Color(hex: 0x29CDF2), Color(hex: 0x076A98)],
                                                      center: .top, startRadius: 0, endRadius: 120))
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .center))
                            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 22)
                        Capsule().strokeBorder(Color(hex: 0xC8FAFF, opacity: 0.85), lineWidth: 1)
                    }
                    .shadow(color: NX.cyan.opacity(0.5), radius: 10)
                } else {
                    GlassBackground(shape: Capsule(style: .continuous), glow: 0.15)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A light-cycle toggle: a glowing gel track when on.
struct NeonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn
                              ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x7FF6FF), Color(hex: 0x0AA6D6)], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color(hex: 0x0A283C, opacity: 0.7)))
                        .overlay(Capsule().strokeBorder(configuration.isOn ? Color(hex: 0xC8FAFF, opacity: 0.9) : Color(hex: 0x78B4C8, opacity: 0.4), lineWidth: 1))
                        .shadow(color: configuration.isOn ? NX.cyan.opacity(0.7) : .clear, radius: 6)
                    Circle()
                        .fill(RadialGradient(colors: [.white, Color(hex: 0xBDEFFF), Color(hex: 0x6FB8CC)],
                                             center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: 16))
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .padding(3)
                }
                .frame(width: 56, height: 32)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Small glass pill naming a path to the network.
struct RouteChip: View {
    let title: String
    let symbol: String
    var lit = true

    var body: some View {
        Label(title, systemImage: symbol)
            .font(NX.body(12, .medium, relativeTo: .caption))
            .foregroundStyle(lit ? Color(hex: 0xC6FBFF) : NX.textMuted)
            .padding(.horizontal, 11)
            .frame(minHeight: 26)
            .background(Capsule().fill(Color(hex: lit ? 0x003C5A : 0x00283C, opacity: lit ? 0.35 : 0.25)))
            .overlay(Capsule().strokeBorder(NX.cyan.opacity(lit ? 0.45 : 0.22), lineWidth: 1))
    }
}

/// Initials in a neon ring, for people and groups.
struct InitialsRing: View {
    let name: String
    var size: CGFloat = 44
    var lit = true

    var body: some View {
        Text(initials)
            .font(NX.display(size * 0.28))
            .foregroundStyle(Color(hex: 0xEAFFFF))
            .frame(width: size, height: size)
            .background(Circle().fill(RadialGradient(colors: [Color(hex: 0xA0F5FF, opacity: 0.5), Color(hex: 0x003C5A, opacity: 0.6)],
                                                     center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: size * 0.7)))
            .overlay(Circle().strokeBorder(lit ? NX.cyan : Color(hex: 0x45707C), lineWidth: 2))
            .shadow(color: lit ? NX.cyan.opacity(0.8) : .clear, radius: 6)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// The big screen title: spaced Exo 2.
struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(NX.label(26, .bold, relativeTo: .largeTitle))
            .tracking(2)
            .foregroundStyle(NX.text)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Forms on the grid

extension View {
    /// Settings-style forms: dark glass rows over a calm, still grid.
    func nxForm() -> some View {
        scrollContentBackground(.hidden)
            .background(GridBackground(horizon: 0.96, energy: 0.6, moving: false))
            .tint(NX.cyan)
    }

    /// Glass row background for a form section.
    func nxRows() -> some View {
        listRowBackground(NX.rowFill)
    }
}

enum NXAppearance {
    /// Navigation bar titles in the app's fonts, over a transparent bar.
    static func apply() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        let text = UIColor(red: 0.9, green: 0.98, blue: 1, alpha: 1)
        if let title = UIFont(name: "Exo2-Bold", size: 17) {
            appearance.titleTextAttributes = [.font: title, .foregroundColor: text, .kern: 1.5]
        }
        if let large = UIFont(name: "Michroma-Regular", size: 26) {
            appearance.largeTitleTextAttributes = [.font: large, .foregroundColor: text, .kern: 3]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

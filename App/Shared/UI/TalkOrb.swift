import SwiftUI

/// The push-to-talk control: a glass Aero orb inside a spinning Tron identity-disc ring.
/// Purely visual; the caller attaches the press gesture.
struct TalkOrb: View {
    enum Mode: Equatable {
        case idle, transmitting, receiving, disabled
    }

    var mode: Mode
    /// Outer diameter, rings included.
    var diameter: CGFloat = 300
    var pressed = false
    /// Everyone on the channel has a post-quantum link (protocol 2): the mic becomes a quantum lock.
    var quantumSafe = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = SpinClock()

    private var orbSize: CGFloat { diameter * 0.667 }
    private var hot: Bool { mode == .transmitting }

    private var spinPeriod: Double {
        switch mode {
        case .idle, .disabled: return 26
        case .receiving: return 9
        case .transmitting: return 5
        }
    }

    var body: some View {
        ZStack {
            rings
            // Halo: a blurred disc behind the orb.
            Circle()
                .fill(RadialGradient(colors: [NX.cyan.opacity(glowStrength), Color(hex: 0x00A0FF, opacity: glowStrength * 0.35), .clear],
                                     center: .center, startRadius: orbSize * 0.3, endRadius: diameter * 0.5))
                .frame(width: diameter, height: diameter)
                .blur(radius: diameter * 0.04)
            orb
        }
        .frame(width: diameter, height: diameter)
        .opacity(mode == .disabled ? 0.45 : 1)
        .animation(.easeOut(duration: 0.25), value: mode)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
    }

    private var glowStrength: Double {
        switch mode {
        case .idle, .disabled: return 0.45
        case .receiving: return 0.7
        case .transmitting: return 0.9
        }
    }

    private var rings: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            // Turns so far, advanced at the current speed, so changing speed (idle → talking)
            // never makes the rings jump, and the slower inner ring never snaps back at a lap.
            let turns = reduceMotion ? 0 : spin.advance(to: timeline.date, period: spinPeriod)
            let outer = turns.truncatingRemainder(dividingBy: 1) * 360
            let inner = -(turns * 0.65).truncatingRemainder(dividingBy: 1) * 360
            ZStack {
                // Identity-disc segments.
                Circle()
                    .inset(by: 3)
                    .stroke(hot ? NX.whiteHot : NX.cyan,
                            style: StrokeStyle(lineWidth: hot ? 3 : 2,
                                               dash: fitted([120, 18, 24, 18, 60, 18], radius: diameter / 2 - 3)))
                    .rotationEffect(.degrees(outer))
                // Inner tick ring, counter-rotating.
                Circle()
                    .inset(by: diameter * 0.073)
                    .stroke(NX.frost.opacity(hot ? 0.9 : 0.55),
                            style: StrokeStyle(lineWidth: 1, dash: fitted([3, 9], radius: diameter * (0.5 - 0.073))))
                    .rotationEffect(.degrees(inner))
                // Four index marks.
                ForEach(0..<4) { i in
                    Capsule()
                        .fill(hot ? NX.whiteHot : NX.cyan)
                        .frame(width: 2, height: diameter * 0.06)
                        .offset(y: -diameter * 0.44)
                        .rotationEffect(.degrees(Double(i) * 90 + inner))
                }
            }
            .neonGlow(NX.cyan, radius: hot ? 10 : 6)
        }
    }

    /// Scales dash lengths drawn for a 300 pt ring to this ring's size, then stretches them so
    /// the pattern repeats a whole number of times around the circle (no odd piece where it meets).
    private func fitted(_ values: [CGFloat], radius: CGFloat) -> [CGFloat] {
        let circumference = 2 * .pi * max(1, radius)
        let pattern = values.reduce(0, +) * diameter / 300
        let repeats = max(1, (circumference / pattern).rounded())
        let scale = circumference / (repeats * values.reduce(0, +))
        return values.map { $0 * scale }
    }

    private var orb: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: bodyColors, center: UnitPoint(x: 0.5, y: hot ? 0.38 : 0.3),
                                         startRadius: 0, endRadius: orbSize * 0.62))
            // Inner shading: darker toward the bottom, like a gel button.
            Circle().fill(LinearGradient(colors: [.clear, Color(hex: 0x001430, opacity: 0.45)],
                                         startPoint: .center, endPoint: .bottom))
            // The glossy top highlight.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.92), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                .frame(width: orbSize * 0.7, height: orbSize * 0.39)
                .offset(y: -orbSize * 0.255)
            label.offset(y: orbSize * 0.07)
            Circle().strokeBorder(hot ? .white : Color(hex: 0xC8FAFF, opacity: 0.85), lineWidth: 2)
        }
        .frame(width: orbSize, height: orbSize)
        .scaleEffect(pressed || hot ? 0.96 : 1)
        .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
    }

    private var bodyColors: [Color] {
        hot
            ? [.white, Color(hex: 0xE6FFFF), Color(hex: 0x7FF7FF), Color(hex: 0x00D4F5), Color(hex: 0x0077A8), Color(hex: 0x012A44)]
            : [Color(hex: 0xDFFEFF), Color(hex: 0x6EE8FF), Color(hex: 0x10B3E6), Color(hex: 0x075C8A), Color(hex: 0x02223A)]
    }

    private var label: some View {
        VStack(spacing: orbSize * 0.04) {
            if quantumSafe && mode != .receiving {
                QuantumLock(size: orbSize * 0.2, filled: mode == .transmitting)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: orbSize * 0.2, weight: .medium))
            }
            Text(caption)
                .font(NX.label(max(10, orbSize * 0.065), .bold))
                .tracking(orbSize * 0.016)
        }
        .foregroundStyle(hot ? Color(hex: 0x012A44) : NX.ink)
    }

    private var iconName: String {
        switch mode {
        case .idle, .disabled: return "mic"
        case .transmitting: return "mic.fill"
        case .receiving: return "speaker.wave.2.fill"
        }
    }

    private var caption: String {
        switch mode {
        case .idle: return "HOLD TO TALK"
        case .disabled: return "NO CHANNEL"
        case .transmitting: return "RELEASE"
        case .receiving: return "RECEIVING"
        }
    }
}

/// Decorative activity bars shown while audio flows (not a measured level).
struct ActivityBars: View {
    var count = 24
    var maxHeight: CGFloat = 30
    var active = true
    /// Follow the real audio (AudioLevelMeter) instead of the animated wave.
    var live = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let levels = live ? AudioLevelMeter.shared.recent(count) : []
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    let wave = sin(t * 7 + Double(i) * 0.9) * 0.5 + sin(t * 3.1 + Double(i) * 0.37) * 0.5
                    let amount = live ? Double(i < levels.count ? levels[i] : 0) : 0.25 + 0.75 * abs(wave)
                    let h = active ? max(4, maxHeight * CGFloat(amount)) : 4
                    Capsule()
                        .fill(LinearGradient(colors: [.white, NX.cyan], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: h)
                }
            }
            .frame(height: maxHeight)
            .neonGlow(NX.cyan, radius: 4)
        }
        .accessibilityHidden(true)
    }
}

/// Accumulates rotation at a speed that can change, so the rings keep turning smoothly.
final class SpinClock {
    private var turns: Double = 0
    private var last: Date?

    func advance(to now: Date, period: Double) -> Double {
        if let last {
            let dt = min(max(0, now.timeIntervalSince(last)), 0.25)   // resume without a leap
            turns += dt / period
            // Keep it small; 20 turns is also a whole number (13) of inner-ring turns.
            if turns >= 20 { turns -= 20 }
        }
        last = now
        return turns
    }
}

/// A padlock with two electron orbits around it: the link is post-quantum.
struct QuantumLock: View {
    var size: CGFloat
    var filled = false

    var body: some View {
        ZStack {
            Image(systemName: filled ? "lock.fill" : "lock")
                .font(.system(size: size * 0.62, weight: .semibold))
            ForEach([-35.0, 35.0], id: \.self) { angle in
                Ellipse()
                    .stroke(lineWidth: max(1, size * 0.055))
                    .frame(width: size * 1.35, height: size * 0.5)
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: size * 1.35, height: size * 1.1)
        .accessibilityLabel("Post-quantum link")
    }
}

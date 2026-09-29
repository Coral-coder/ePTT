import SwiftUI

/// The world behind every screen: a deep-blue void with aurora glow and a Tron
/// light grid receding to a glowing horizon. `energy` brightens it while transmitting.
struct GridBackground: View {
    /// Where the horizon sits, as a fraction of the height.
    var horizon: CGFloat = 0.62
    /// 1 at rest, higher while transmitting or receiving.
    var energy: Double = 1
    /// Whether the grid flows toward the viewer.
    var moving = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(stops: [
                    .init(color: NX.deep[0], location: 0),
                    .init(color: NX.deep[1], location: 0.38),
                    .init(color: NX.deep[2], location: 0.62),
                    .init(color: NX.deep[3], location: 1),
                ], startPoint: .top, endPoint: .bottom)

                aurora(in: geo.size)

                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !moving)) { timeline in
                    Canvas { context, size in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        drawGrid(in: &context, size: size, phase: (reduceMotion || !moving) ? 0 : t)
                    }
                }

            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func aurora(in size: CGSize) -> some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x00BEFF, opacity: 0.40), .clear],
                           center: UnitPoint(x: 0.18, y: 0.08), startRadius: 0, endRadius: size.width * 0.75)
            RadialGradient(colors: [Color(hex: 0x00FFD6, opacity: 0.20), .clear],
                           center: UnitPoint(x: 0.88, y: 0.2), startRadius: 0, endRadius: size.width * 0.6)
            RadialGradient(colors: [Color(hex: 0x3CF0FF, opacity: 0.12 * energy), .clear],
                           center: UnitPoint(x: 0.5, y: horizon), startRadius: 0, endRadius: size.width * 0.9)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, phase: TimeInterval) {
        let horizonY = size.height * horizon
        let floor = size.height - horizonY
        let center = CGPoint(x: size.width / 2, y: horizonY)
        let strength = min(1, 0.55 * energy)
        let line = NX.cyan

        // Rungs: spacing grows toward the viewer (1/z perspective) and slide toward the viewer
        // over time, as if flying forward over the grid.
        let rungs = 14
        let speed = 0.35 * energy
        let offset = (phase * speed).truncatingRemainder(dividingBy: 1)
        for i in 0..<rungs {
            let z = (Double(i) + offset) / Double(rungs)               // 0 (horizon) … 1 (viewer)
            guard z > 0, z <= 1 else { continue }
            let y = horizonY + floor * CGFloat(pow(z, 2.2))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(line.opacity(strength * z)), lineWidth: 1)
        }

        // Rails: converge on the vanishing point.
        let rails = 13
        let spread = size.width * 2.6
        for i in 0...rails {
            let x = center.x - spread / 2 + spread * CGFloat(i) / CGFloat(rails)
            var path = Path()
            path.move(to: center)
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [line.opacity(0), line.opacity(strength)]),
                startPoint: center, endPoint: CGPoint(x: x, y: size.height)), lineWidth: 1)
        }

        // The horizon: a light line with a white-hot core.
        let horizonRect = CGRect(x: 0, y: horizonY - 1, width: size.width, height: 2)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 8))
            layer.fill(Path(horizonRect.insetBy(dx: 0, dy: -3)), with: .color(line.opacity(0.7 * min(1.4, energy))))
        }
        context.fill(Path(horizonRect), with: .linearGradient(
            Gradient(colors: [line.opacity(0), line, .white, line, line.opacity(0)]),
            startPoint: CGPoint(x: 0, y: horizonY), endPoint: CGPoint(x: size.width, y: horizonY)))
    }
}

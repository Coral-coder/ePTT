import AVFoundation
import QuartzCore
import SwiftUI
import EPTTCore

/// How two phones pair face to face. All three carry the same 82 bytes (keys and relay mailbox)
/// as light only; names and the signed cards follow through the encrypted relay.
enum OpticalPairingMethod: String, CaseIterable, Identifiable {
    /// A 4 × 4 grid of black/white tiles at the top of the screen (OpticalLink).
    case grid
    /// Sixteen stars that twinkle the same code, and drift to a new constellation each round.
    case constellation
    /// Four short DNA strands whose sixteen base pairs each show one of four greys (A, C, G, T):
    /// two bits each, so rounds take about 6 s. Strands unzip and rearrange between rounds.
    case dna
    /// Phones back to back, each LED blinking at the other's rear camera (BlinkLink). Slow.
    case flashlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .constellation: return "Stars"
        case .dna: return "DNA"
        case .flashlight: return "Flashlight"
        }
    }

    var instructions: String {
        switch self {
        case .grid, .constellation:
            return "Open this on both phones, pick the same method and tap Start on both. Hold them screen to screen, tops together, about a hand apart, until both finish (about 10 seconds)."
        case .dna:
            return "Open this on both phones, pick DNA and tap Start on both. Hold them screen to screen, tops together, about a hand apart, until both finish (about 7 seconds)."
        case .flashlight:
            return "Experimental and slow (about 90 seconds). Pick Flashlight on both phones and tap Start on both. Hold them back to back with the camera bumps lined up, a finger's width apart, and keep still."
        }
    }

    var warning: String {
        switch self {
        case .grid: return "The top of the screen flashes black and white quickly. Don't look at it if flashing lights affect you."
        case .constellation: return "The stars flash quickly. Don't look at them if flashing lights affect you."
        case .dna: return "The strands flash quickly. Don't look at them if flashing lights affect you."
        case .flashlight: return "The flashlight blinks rapidly and brightly. Don't look into it."
        }
    }

    var usesScreen: Bool { self != .flashlight }

    var alphabet: OpticalLink.Alphabet { self == .dna ? .quaternary : .binary }
}

/// DISABLED: the earlier experimental light methods (grid, stars, DNA, flashlight). Face to face
/// now uses Orbit codes (`FacePairView`, OrbitPairView.swift); nothing presents this view any
/// more. The code stays for experiments.
/// Face-to-face pairing over light (PROTOCOL.md §12.1): pick a method, start on both phones.
struct LightPairView: View {
    /// Invite whoever we pair with to this talk group.
    var group: Channel?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = LightPairingSession()
    @AppStorage("facePairingMethod") private var methodName = OpticalPairingMethod.grid.rawValue
    @State private var running = false
    @State private var savedBrightness: CGFloat?

    private var method: OpticalPairingMethod { OpticalPairingMethod(rawValue: methodName) ?? .grid }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if running {
                if method.usesScreen {
                    GeometryReader { geo in
                        Group {
                            if method == .constellation {
                                ConstellationLamp(scheduler: pairing.screenScheduler)
                            } else if method == .dna {
                                HelixLamp(scheduler: pairing.screenScheduler)
                            } else {
                                GridLamp(scheduler: pairing.screenScheduler)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height * 0.56)
                    }
                    .ignoresSafeArea()
                }
                LightCamera(session: pairing, method: method)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            VStack {
                HStack {
                    Button("Close") { dismiss() }
                        .font(NX.label(15, .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                    Spacer()
                    if running {
                        Text(method.title.uppercased())
                            .font(NX.label(12, .semibold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 14)
                Spacer()
                if running {
                    HandshakePanel(pairing: pairing) { dismiss() }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 14)
                } else {
                    intro
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let groupID = group?.id
            pairing.onPaired = { profile in
                model.engine.addLightPaired(profile)
                if let groupID { model.engine.addMember(profile.identity.id, toGroup: groupID) }
            }
            model.engine.lightProfile { data in
                guard let data else { return }
                pairing.prepare(profile: data)
            }
        }
        .onDisappear {
            pairing.stop()
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.map { "ADD TO \($0.name.uppercased())" } ?? "PAIR FACE TO FACE")
                .font(NX.label(17, .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
            if let group {
                Text("You'll pair with them and they'll be added to \(group.name). Only this phone needs to start from the group.")
                    .font(NX.body(13))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Method", selection: $methodName) {
                ForEach(OpticalPairingMethod.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(method.instructions)
                .font(NX.body(15))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Label(method.warning, systemImage: "exclamationmark.triangle")
                .font(NX.body(13))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if method.usesScreen {
                    savedBrightness = UIScreen.main.brightness
                    // Bright enough to read, not so bright it blows out the other camera.
                    UIScreen.main.brightness = 0.7
                }
                pairing.start(method: method)
                running = true
            } label: {
                Text("START")
                    .font(NX.label(15, .bold))
                    .tracking(2)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(!pairing.isReady)
            .opacity(pairing.isReady ? 1 : 0.4)
        }
        .padding(22)
    }
}

// MARK: - Screens

/// The flashing tiles: the current symbol, redrawn every display frame. White and black only.
private struct GridLamp: View {
    let scheduler: RoundScheduler<OpticalLink.Symbol>

    var body: some View {
        TimelineView(.animation) { _ in
            let symbol = scheduler.symbol(at: CACurrentMediaTime()).symbol ?? RoundScheduler<OpticalLink.Symbol>.dark
            Canvas { context, size in
                let gap: CGFloat = 8
                let w = (size.width - gap * CGFloat(OpticalLink.columns + 1)) / CGFloat(OpticalLink.columns)
                let h = (size.height - gap * CGFloat(OpticalLink.rows + 1)) / CGFloat(OpticalLink.rows)
                for j in 0..<OpticalLink.tiles where symbol[j] > 0 {
                    let x = gap + CGFloat(j % OpticalLink.columns) * (w + gap)
                    let y = gap + CGFloat(j / OpticalLink.columns) * (h + gap)
                    context.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(LightLevel.color(symbol[j])))
                }
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }
}

/// The same code as sixteen stars. Each round the constellation drifts to a new shape during the
/// preamble (when every star is on or off together, so moving doesn't matter), then holds still
/// while the other camera calibrates and reads. Faint lines join each star to its nearest
/// neighbour; they don't change within a round, so the reader treats them as background.
private struct ConstellationLamp: View {
    let scheduler: RoundScheduler<OpticalLink.Symbol>

    var body: some View {
        TimelineView(.animation) { _ in
            let now = scheduler.symbol(at: CACurrentMediaTime())
            Canvas { context, size in
                let symbol = now.symbol ?? RoundScheduler<OpticalLink.Symbol>.dark
                // Glide from the last round's shape to this one's over the preamble.
                let glide = min(1, (Double(now.index) + now.fraction) / Double(OpticalLink.preamble.count))
                let t = now.index < OpticalLink.preamble.count ? smooth(glide) : 1
                let from = Self.layout(round: now.round - 1), to = Self.layout(round: now.round)
                let points = zip(from, to).map { a, b in
                    CGPoint(x: (a.x + (b.x - a.x) * t) * size.width, y: (a.y + (b.y - a.y) * t) * size.height)
                }
                // Constellation lines.
                var lines = Path()
                for (i, p) in points.enumerated() {
                    guard let nearest = points.indices.filter({ $0 != i })
                        .min(by: { hypot(points[$0].x - p.x, points[$0].y - p.y) < hypot(points[$1].x - p.x, points[$1].y - p.y) })
                    else { continue }
                    lines.move(to: p)
                    lines.addLine(to: points[nearest])
                }
                context.stroke(lines, with: .color(Color(white: 0.16)), lineWidth: 1.5)
                // Stars.
                let r = size.width * 0.045
                for (j, p) in points.enumerated() {
                    if symbol[j] > 0 {
                        let glow = Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4))
                        context.fill(glow, with: .radialGradient(Gradient(colors: [Color(white: 0.55), Color(white: 0)]),
                                                                center: p, startRadius: r * 0.6, endRadius: r * 2))
                        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                     with: .color(Color(white: 0.95)))
                    } else {
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                                     with: .color(Color(white: 0.14)))
                    }
                }
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }

    private func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// Sixteen well-spread star positions (0…1 in each axis) for a round, the same on every phone.
    static func layout(round: Int) -> [CGPoint] {
        var seed = UInt64(bitPattern: Int64(round)) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var points: [CGPoint] = []
        var attempts = 0
        while points.count < OpticalLink.tiles {
            let p = CGPoint(x: 0.08 + 0.84 * next(), y: 0.1 + 0.8 * next())
            attempts += 1
            let spacing = attempts > 2000 ? 0.12 : 0.17
            if points.allSatisfy({ hypot($0.x - p.x, ($0.y - p.y) * 1.3) > spacing }) { points.append(p) }
        }
        return points
    }
}

/// The greys for levels 0…3, spaced evenly in emitted light (the receiver calibrates the rest).
enum LightLevel {
    static func color(_ level: UInt8) -> Color {
        switch level {
        case 0: return .black
        case 1: return Color(white: 0.56)
        case 2: return Color(white: 0.77)
        default: return Color(white: 0.92)
        }
    }
}

/// DNA: four short double helices, one per column, each with four base pairs; base pair *j* is
/// element *j* and glows at its level (A, C, G, T as four greys). During each round's preamble,
/// when every base pair is dark or full together, the strands unzip, twist and trade places, then
/// zip back together and hold still while the other camera calibrates and reads. The backbones
/// don't change within a round, so the reader treats them as background.
private struct HelixLamp: View {
    let scheduler: RoundScheduler<OpticalLink.Symbol>

    var body: some View {
        TimelineView(.animation) { _ in
            let now = scheduler.symbol(at: CACurrentMediaTime())
            Canvas { context, size in
                let symbol = now.symbol ?? RoundScheduler<OpticalLink.Symbol>.dark
                let preamble = Double(OpticalLink.preamble.count)
                let t = now.index < OpticalLink.preamble.count ? min(1, (Double(now.index) + now.fraction) / preamble) : 1
                let ease = t * t * (3 - 2 * t)
                // Unzip in the first half of the preamble, zip back in the second.
                let open = sin(.pi * t)
                let fromOrder = Self.order(round: now.round - 1), toOrder = Self.order(round: now.round)
                let columnWidth = size.width / CGFloat(OpticalLink.columns)
                let rowHeight = size.height / CGFloat(OpticalLink.rows)
                let twist = Double(now.round) * 1.3 + open * 2.4
                for strand in 0..<OpticalLink.columns {
                    // Where this strand sits: sliding from last round's slot to this round's.
                    let a = Double(fromOrder.firstIndex(of: strand) ?? strand), b = Double(toOrder.firstIndex(of: strand) ?? strand)
                    let slot = a + (b - a) * ease
                    let cx = columnWidth * (CGFloat(slot) + 0.5)
                    let amplitude = columnWidth * (0.30 + 0.22 * open)
                    // Backbones: two sine curves, half a turn apart.
                    for side in [0.0, Double.pi] {
                        var path = Path()
                        for i in 0...60 {
                            let y = size.height * CGFloat(i) / 60
                            let phase = Double(y / rowHeight) * .pi + twist + side + Double(strand)
                            let x = cx + amplitude * CGFloat(sin(phase))
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(path, with: .color(Color(white: 0.18)), lineWidth: 3)
                    }
                    // Base pairs, at the grid rows. They keep full brightness while the strands
                    // move: the preamble is found from overall brightness.
                    for row in 0..<OpticalLink.rows {
                        let j = row * OpticalLink.columns + strand
                        let y = rowHeight * (CGFloat(row) + 0.5)
                        let phase = Double(y / rowHeight) * .pi + twist + Double(strand)
                        let half = max(columnWidth * 0.2, abs(amplitude * CGFloat(sin(phase))))
                        let rung = CGRect(x: cx - half, y: y - rowHeight * 0.22, width: half * 2, height: rowHeight * 0.44)
                        let level = symbol[j]
                        guard level > 0 else { continue }
                        context.fill(Path(roundedRect: rung, cornerRadius: rowHeight * 0.1),
                                     with: .color(LightLevel.color(level)))
                    }
                }
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }

    /// Which strand sits in which column this round (the same on every phone).
    static func order(round: Int) -> [Int] {
        var seed = UInt64(bitPattern: Int64(round)) &* 0x9E37_79B9_7F4A_7C15 &+ 7
        var order = Array(0..<OpticalLink.columns)
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            order.swapAt(i, Int(seed >> 33) % (i + 1))
        }
        return order
    }
}

/// Where the handshake is, as steps and a progress bar. White and grey only.
private struct HandshakePanel: View {
    @ObservedObject var pairing: LightPairingSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pairing.headline.uppercased())
                .font(NX.label(15, .bold))
                .tracking(1.5)
                .foregroundStyle(.white)
            Text(pairing.hint)
                .font(NX.body(13))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: max(8, geo.size.width * pairing.overallProgress))
                        .animation(.easeOut(duration: 0.25), value: pairing.overallProgress)
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("Pairing progress")
            .accessibilityValue("\(Int(pairing.overallProgress * 100)) percent")

            VStack(alignment: .leading, spacing: 7) {
                step("See the other phone", done: pairing.hasSeenPeer, active: pairing.stage == .looking)
                step(pairing.stage == .receiving
                        ? "Receive their keys · \(Int(pairing.receivedProgress * 100))%"
                        : "Receive their keys",
                     done: pairing.hasTheirs, active: pairing.stage == .receiving)
                step("They receive yours", done: pairing.peerHasMine, active: pairing.stage == .waitingForPeer)
                step("Compare the safety code", done: false, active: pairing.stage == .paired)
            }

            if let code = pairing.safetyCode {
                Text(code)
                    .font(NX.display(30))
                    .tracking(4)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Safety code \(code)")
            }
            if pairing.stage == .paired {
                Button(action: close) {
                    Text("DONE")
                        .font(NX.label(14, .bold))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func step(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(.white.opacity(done || active ? 0.85 : 0.3), lineWidth: 1.5)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                } else if active {
                    Circle().fill(.white).frame(width: 7, height: 7)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(NX.body(14, active ? .semibold : .regular))
                .foregroundStyle(.white.opacity(done || active ? 0.95 : 0.45))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : active ? "In progress" : "Not yet")
    }
}

// MARK: - Sending

/// Our transmission: data rounds with our profile, and once we have theirs, data and ack rounds
/// alternating (they may still need ours). Read from the display loop or the torch timer; times
/// are `CACurrentMediaTime()`, the same clock as camera frames.
final class RoundScheduler<S> {
    static var dark: OpticalLink.Symbol { OpticalLink.Symbol(repeating: 0, count: OpticalLink.tiles) }

    private let lock = NSLock()
    private let symbolSeconds: Double
    private var dataLoop: (Data) -> [S]
    private var ackLoop: (Data) -> [S]
    private var payload: Data?
    private var received: Data?
    private var loop: [S] = []
    private var loopStart = 0.0
    private var round = 0
    private var sentAck = true

    init(symbolSeconds: Double, dataLoop: @escaping (Data) -> [S], ackLoop: @escaping (Data) -> [S]) {
        self.symbolSeconds = symbolSeconds
        self.dataLoop = dataLoop
        self.ackLoop = ackLoop
    }

    /// Starts transmitting; `loops` replaces the round builders (e.g. for another alphabet).
    func start(payload: Data, loops: (data: (Data) -> [S], ack: (Data) -> [S])? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let loops { dataLoop = loops.data; ackLoop = loops.ack }
        self.payload = payload
        loopStart = CACurrentMediaTime()
        loop = dataLoop(payload)
        round = 0
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        payload = nil
    }

    func gotTheirs(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        received = data
    }

    /// The symbol showing at `time`, with its round number, index in the round and how far
    /// through the symbol we are. Nil symbol before start.
    func symbol(at time: Double) -> (symbol: S?, round: Int, index: Int, fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let payload, !loop.isEmpty else { return (nil, 0, 0, 0) }
        var position = (time - loopStart) / symbolSeconds
        while position >= Double(loop.count) {
            loopStart += Double(loop.count) * symbolSeconds
            position -= Double(loop.count)
            round += 1
            if let received, !sentAck {
                loop = ackLoop(received)
                sentAck = true
            } else {
                loop = dataLoop(payload)
                sentAck = false
            }
        }
        let index = max(0, Int(position))
        return (loop[index], round, index, position - Double(index))
    }
}

// MARK: - Session

/// The receivers, used on the camera queue under a lock.
private final class LightReader: @unchecked Sendable {
    let lock = NSLock()
    var optical = OpticalLink.Receiver()
    var blink: BlinkLink.Receiver
    var framesSinceProgress = 0
    init(torch: RoundScheduler<Bool>) {
        // Our own LED's state at any moment, so its reflection can be removed.
        blink = BlinkLink.Receiver(ownLight: { torch.symbol(at: $0).symbol ?? false })
    }
}

@MainActor
final class LightPairingSession: ObservableObject {
    enum Stage { case looking, receiving, waitingForPeer, paired }

    @Published private(set) var isReady = false
    @Published private(set) var stage: Stage = .looking
    @Published private(set) var hasSeenPeer = false
    @Published private(set) var hasTheirs = false
    @Published private(set) var receivedProgress = 0.0
    @Published private(set) var peerHasMine = false
    @Published private(set) var failedRounds = 0
    @Published private(set) var safetyCode: String?

    let screenScheduler = RoundScheduler<OpticalLink.Symbol>(
        symbolSeconds: OpticalLink.symbolSeconds,
        dataLoop: { OpticalLink.dataLoop(payload: $0) }, ackLoop: { OpticalLink.ackLoop(for: $0) })
    let torchScheduler: RoundScheduler<Bool>
    var onPaired: ((LightProfile) -> Void)?

    private(set) var method: OpticalPairingMethod = .grid
    private var myPayload = Data()
    private var started = Date()

    private let reader: LightReader

    init() {
        let torch = RoundScheduler<Bool>(
            symbolSeconds: BlinkLink.symbolSeconds,
            dataLoop: { BlinkLink.dataLoop(payload: $0) }, ackLoop: { BlinkLink.ackLoop(for: $0) })
        torchScheduler = torch
        reader = LightReader(torch: torch)
    }

    var overallProgress: Double {
        (hasSeenPeer ? 0.1 : 0) + 0.7 * (hasTheirs ? 1 : receivedProgress) + (peerHasMine ? 0.2 : 0)
    }

    var headline: String {
        switch stage {
        case .looking: return "Looking for the other phone"
        case .receiving: return failedRounds > 0 ? "Missed some, reading again" : "Receiving their keys"
        case .waitingForPeer: return "Got theirs, sending yours"
        case .paired: return "Paired"
        }
    }

    var hint: String {
        let back = method == .flashlight
        switch stage {
        case .looking:
            if Date().timeIntervalSince(started) > 8 {
                return back
                    ? "Both phones on Flashlight with Start tapped, back to back, camera bumps lined up."
                    : "Both phones on the same method with Start tapped, screens facing, tops together, about a hand apart."
            }
            return back ? "Hold the phones back to back, camera bumps lined up." : "Hold the phones screen to screen, tops together, about a hand apart."
        case .receiving:
            if failedRounds > 1 { return back ? "Hold them steadier, bumps closer together." : "Hold them steadier and a little further apart." }
            return back ? "Keep still. This takes about a minute and a half." : "Keep them still until both finish."
        case .waitingForPeer: return "Keep holding them together so the other phone finishes reading yours."
        case .paired: return "Both phones should show this code. If they don't, remove the contact and try again."
        }
    }

    /// Our profile without the name: 82 bytes, which is what the light carries.
    func prepare(profile: Data) {
        guard let full = try? LightProfile(encoded: profile) else { return }
        myPayload = LightProfile(identity: full.identity, name: "", relayMailbox: full.relayMailbox).encoded
        isReady = myPayload.count == OpticalLink.payloadBytes
    }

    func start(method: OpticalPairingMethod) {
        guard isReady else { return }
        self.method = method
        started = Date()
        if method.usesScreen {
            let alphabet = method.alphabet
            reader.lock.lock()
            reader.optical = OpticalLink.Receiver(alphabet: alphabet)
            reader.lock.unlock()
            screenScheduler.start(payload: myPayload, loops: (data: { OpticalLink.dataLoop(payload: $0, alphabet: alphabet) },
                                                              ack: { OpticalLink.ackLoop(for: $0, alphabet: alphabet) }))
        } else {
            torchScheduler.start(payload: myPayload)
        }
    }

    func stop() {
        screenScheduler.stop()
        torchScheduler.stop()
    }

    /// Camera queue: one frame, as 16 × 12 cells of brightness. Returns true on the first sight of
    /// the other phone (the camera locks its exposure then).
    nonisolated func frame(time: Double, cells: [Float], blink: Bool) -> Bool {
        let r = reader
        r.lock.lock()
        let events: [OpticalLink.Receiver.Event]
        let seen: Int
        if blink {
            events = r.blink.add(time: time, level: cells.reduce(0, +) / Float(cells.count))
            seen = r.blink.roundsSeen
        } else {
            events = r.optical.add(time: time, cells: cells)
            seen = r.optical.roundsSeen
        }
        r.framesSinceProgress += 1
        var progress: Double?
        if r.framesSinceProgress >= 6 {
            r.framesSinceProgress = 0
            progress = blink ? r.blink.progress(at: time) : r.optical.progress(at: time)
        }
        r.lock.unlock()
        let first = seen == 1 && events.contains { if case .roundStarted = $0 { return true }; return false }
        if !events.isEmpty || progress != nil {
            Task { @MainActor in self.handle(events, progress: progress) }
        }
        return first
    }

    private func handle(_ events: [OpticalLink.Receiver.Event], progress: Double?) {
        if let progress, !hasTheirs { receivedProgress = progress }
        for event in events {
            switch event {
            case .roundStarted:
                hasSeenPeer = true
            case .roundIncomplete:
                failedRounds += 1
                receivedProgress = 0
            case .payload(let data):
                guard !hasTheirs, let profile = try? LightProfile(encoded: data) else { continue }
                hasTheirs = true
                receivedProgress = 1
                safetyCode = LightCode.safetyCode(myPayload, data)
                screenScheduler.gotTheirs(data)
                torchScheduler.gotTheirs(data)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onPaired?(profile)
            case .ack(let value):
                if value == OpticalLink.ackValue(for: myPayload) { peerHasMine = true }
            }
        }
        let next: Stage = hasTheirs ? (peerHasMine ? .paired : .waitingForPeer) : (hasSeenPeer ? .receiving : .looking)
        if next == .paired && stage != .paired { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        stage = next
    }
}

// MARK: - Camera

/// Front camera (screen methods) or rear camera and flashlight (flashlight method) → 16 × 12
/// cells of average brightness per frame → the session. Exposure is pulled down so bright light
/// doesn't blow out, then locked once the other phone is seen, so brightness means the same thing
/// for a whole round.
private struct LightCamera: UIViewControllerRepresentable {
    let session: LightPairingSession
    let method: OpticalPairingMethod

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.session = session
        controller.method = method
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        var session: LightPairingSession?
        var method: OpticalPairingMethod = .grid
        private let capture = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.eptt.facepair.camera")
        private let torchQueue = DispatchQueue(label: "app.eptt.facepair.torch", qos: .userInteractive)
        private var torchTimer: DispatchSourceTimer?
        private var torchOn = false
        private var device: AVCaptureDevice?
        private var locked = false

        override func viewDidLoad() {
            super.viewDidLoad()
            let position: AVCaptureDevice.Position = method == .flashlight ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device), capture.canAddInput(input) else { return }
            self.device = device
            capture.sessionPreset = .inputPriority
            capture.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(output) else { return }
            capture.addOutput(output)
            configure(device)
        }

        /// 60 fps at a modest size if the camera can, and exposure biased down.
        private func configure(_ device: AVCaptureDevice) {
            guard (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let formats = device.formats.filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width <= 1280 && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
            }
            if let format = formats.max(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }) {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            } else {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            let bias: Float = method == .flashlight ? -2 : -1.5
            device.setExposureTargetBias(max(device.minExposureTargetBias, bias), completionHandler: nil)
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
            if device.isFocusModeSupported(.locked), method == .flashlight { device.focusMode = .locked }
        }

        private func lockExposure() {
            guard !locked, let device, (try? device.lockForConfiguration()) != nil else { return }
            locked = true
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        }

        /// Flashlight: follow the torch schedule, switching the LED at each symbol change.
        private func startTorch() {
            guard method == .flashlight, let device, device.hasTorch, let scheduler = session?.torchScheduler else { return }
            let timer = DispatchSource.makeTimerSource(queue: torchQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let on = scheduler.symbol(at: CACurrentMediaTime()).symbol ?? false
                guard on != self.torchOn, (try? device.lockForConfiguration()) != nil else { return }
                if on { try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) } else { device.torchMode = .off }
                device.unlockForConfiguration()
                self.torchOn = on
            }
            timer.resume()
            torchTimer = timer
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let capture = self.capture
            queue.async { [weak self] in
                capture.startRunning()
                DispatchQueue.main.async { self?.startTorch() }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            torchTimer?.cancel()
            torchTimer = nil
            if let device, device.hasTorch, (try? device.lockForConfiguration()) != nil {
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            let capture = self.capture
            queue.async { capture.stopRunning() }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let session else { return }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let cols = OpticalLink.cellColumns, rows = OpticalLink.cellRows
            var cells = [Float](repeating: 0, count: cols * rows)
            let step = max(1, width / 160)
            for r in 0..<rows {
                let y0 = r * height / rows, y1 = (r + 1) * height / rows
                for c in 0..<cols {
                    let x0 = c * width / cols, x1 = (c + 1) * width / cols
                    var sum = 0, n = 0
                    var y = y0
                    while y < y1 {
                        let row = luma + y * stride
                        var x = x0
                        while x < x1 { sum += Int(row[x]); n += 1; x += step }
                        y += step
                    }
                    cells[r * cols + c] = n > 0 ? Float(sum) / Float(n) : 0
                }
            }
            if session.frame(time: time, cells: cells, blink: method == .flashlight) { lockExposure() }
        }
    }
}

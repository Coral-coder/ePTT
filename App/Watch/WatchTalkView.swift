import SwiftUI

struct WatchTalkView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var pressed = false

    var body: some View {
        NavigationStack {
            ZStack {
                GridBackground(horizon: 0.78, energy: energy)
                VStack(spacing: 4) {
                    NavigationLink {
                        ChannelPicker()
                    } label: {
                        Text(model.selectedName.uppercased())
                            .font(NX.label(13, .bold))
                            .tracking(1.2)
                            .foregroundStyle(NX.text)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .glassCapsule(glow: 0.2)
                    }
                    .buttonStyle(.plain)

                    Text(statusText)
                        .font(NX.body(12, .medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    TalkOrb(mode: orbMode, diameter: 118, pressed: pressed)
                        .contentShape(Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    guard !pressed, available else { return }
                                    pressed = true
                                    model.press()
                                }
                                .onEnded { _ in
                                    guard pressed else { return }
                                    pressed = false
                                    model.release()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Push to talk")
                        .accessibilityAddTraits(.isButton)
                }
                .padding(.horizontal, 4)
            }
        }
        .tint(NX.cyan)
    }

    private var available: Bool { model.phoneReachable || model.isStandalone }

    private var orbMode: TalkOrb.Mode {
        if !available { return .disabled }
        if model.isStandalone {
            switch model.standaloneStatus {
            case .recording: return .transmitting
            case .playing: return .receiving
            default: return .idle
            }
        }
        switch model.state {
        case .transmitting: return .transmitting
        case .receiving: return .receiving
        default: return pressed ? .transmitting : .idle
        }
    }

    private var energy: Double {
        switch orbMode {
        case .transmitting: return 1.8
        case .receiving: return 1.3
        default: return 1
        }
    }

    private var statusText: String {
        if model.isStandalone {
            switch model.standaloneStatus {
            case .idle: return "On your watch · hold to talk"
            case .recording: return "Recording…"
            case .sending: return "Sending…"
            case .sent(let n): return n == 1 ? "Sent" : "Sent to \(n)"
            case .failed(let reason): return reason
            case .playing(let talker): return talker
            }
        }
        switch model.state {
        case .receiving: return model.talker
        case .transmitting: return "Talking"
        case .busy: return "Busy"
        case .offline: return "Open NXTPTT on iPhone"
        case .idle: return "Hold to talk"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .receiving, .transmitting: return NX.frost
        case .busy: return Color(hex: 0xFF8A8A)
        default: return NX.textDim
        }
    }
}

struct ChannelPicker: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(model.channels) { channel in
                Button {
                    model.select(channel)
                    dismiss()
                } label: {
                    HStack {
                        Text(channel.name).font(NX.body(15, .medium)).foregroundStyle(NX.text)
                        Spacer()
                        if channel.id == model.selected { Image(systemName: "checkmark").foregroundStyle(NX.cyan) }
                    }
                }
            }
            Toggle("Play on watch", isOn: Binding(get: { model.listening }, set: { model.setListening($0) }))
                .font(NX.body(15))
        }
        .tint(NX.cyan)
        .navigationTitle("Channels")
    }
}

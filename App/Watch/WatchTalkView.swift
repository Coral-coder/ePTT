import SwiftUI

struct WatchTalkView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var pressed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                NavigationLink {
                    ChannelPicker()
                } label: {
                    Text(model.selectedName).lineLimit(1)
                }

                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Circle()
                    .fill((pressed ? Color.red : Color.orange).gradient)
                    .overlay(Image(systemName: pressed ? "mic.fill" : "mic").font(.title).foregroundStyle(.white))
                    .scaleEffect(pressed ? 0.92 : 1)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !pressed else { return }
                                pressed = true
                                model.press()
                            }
                            .onEnded { _ in
                                pressed = false
                                model.release()
                            }
                    )
                    .opacity(model.phoneReachable || model.isStandalone ? 1 : 0.4)
            }
            .padding(.horizontal)
        }
    }

    private var statusText: String {
        if model.isStandalone {
            switch model.standaloneStatus {
            case .idle: return "Via iCloud · hold to talk"
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
        case .offline: return "Open Chirp on iPhone"
        case .idle: return "Hold to talk"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .receiving: return .green
        case .transmitting, .busy: return .red
        default: return .secondary
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
                        Text(channel.name)
                        Spacer()
                        if channel.id == model.selected { Image(systemName: "checkmark") }
                    }
                }
            }
            Toggle("Play on watch", isOn: Binding(get: { model.listening }, set: { model.setListening($0) }))
        }
        .navigationTitle("Channels")
    }
}

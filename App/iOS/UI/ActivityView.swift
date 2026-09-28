import SwiftUI

/// Recent transmissions and the route each one took (nearby, local network, internet, relay).
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.9, energy: 0.8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom) {
                        ScreenTitle(text: "Activity")
                        Spacer()
                        if !model.snapshot.transfers.isEmpty {
                            Button("CLEAR") { model.engine.clearTransfers() }
                                .font(NX.label(13, .bold))
                                .tracking(2)
                                .foregroundStyle(NX.ice)
                                .frame(minHeight: 44)
                        }
                    }
                    if model.snapshot.transfers.isEmpty {
                        Text("Transmissions you send and receive show up here, with the route each one took.")
                            .font(NX.body(14))
                            .foregroundStyle(NX.textMuted)
                    }
                    ForEach(model.snapshot.transfers) { transfer in
                        TransferRow(transfer: transfer)
                            .padding(14)
                            .glass(cornerRadius: 18, glow: 0.1)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }
}

struct TransferRow: View {
    let transfer: TransferRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: transfer.outgoing ? "arrow.up.right" : "arrow.down.left")
                    .foregroundStyle(transfer.outgoing ? Color.white : NX.cyan)
                    .neonGlow(NX.cyan, radius: 4)
                Text(transfer.channel).font(NX.label(16, .bold)).foregroundStyle(NX.text)
                Spacer()
                Text(transfer.date, style: .relative)
                    .font(NX.body(12))
                    .foregroundStyle(NX.textMuted)
            }
            Text(String(format: "%.1f s", transfer.seconds))
                .font(NX.display(12))
                .foregroundStyle(NX.frost)
            ForEach(transfer.legs, id: \.self) { leg in
                Label {
                    Text(transfer.outgoing ? "\(leg.peer): \(leg.route.label)" : "via \(leg.route.label)")
                } icon: {
                    Image(systemName: leg.route.symbol)
                }
                .font(NX.body(13))
                .foregroundStyle(leg.route == .failed ? Color(hex: 0xFF8A8A) : NX.textDim)
            }
        }
        .padding(.vertical, 2)
    }
}

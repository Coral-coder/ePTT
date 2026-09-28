import SwiftUI

/// Recent transmissions and the route each one took (nearby, local network, internet, relay).
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.snapshot.transfers.isEmpty {
                    Text("Transmissions you send and receive show up here, with the route each one took.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.transfers) { transfer in
                    TransferRow(transfer: transfer)
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                if !model.snapshot.transfers.isEmpty {
                    Button("Clear") { model.engine.clearTransfers() }
                }
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
                    .foregroundStyle(transfer.outgoing ? .orange : .green)
                Text(transfer.channel).font(.headline)
                Spacer()
                Text(transfer.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(format: "%.1f s", transfer.seconds))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(transfer.legs, id: \.self) { leg in
                Label {
                    Text(transfer.outgoing ? "\(leg.peer): \(leg.route.label)" : "via \(leg.route.label)")
                } icon: {
                    Image(systemName: leg.route.symbol)
                }
                .font(.caption)
                .foregroundStyle(leg.route == .failed ? Color.red : Color.primary)
            }
        }
        .padding(.vertical, 2)
    }
}

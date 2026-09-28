import SwiftUI
import EPTTCore

struct ChannelsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var creatingGroup = false

    private var directs: [Channel] { model.snapshot.channels.filter { $0.kind == .direct } }

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.9, energy: 0.8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .bottom) {
                        ScreenTitle(text: "Channels")
                        Spacer()
                        Button {
                            creatingGroup = true
                        } label: {
                            GelBead(size: 44) { Image(systemName: "plus").font(.system(size: 18, weight: .bold)) }
                        }
                        .disabled(model.snapshot.contacts.isEmpty)
                        .opacity(model.snapshot.contacts.isEmpty ? 0.5 : 1)
                        .accessibilityLabel("New talk group")
                    }

                    SectionCaption(text: "Talk groups · scan")
                    if model.groups.isEmpty {
                        Text("No talk groups yet. Tap + to make one; members get the key over their private channels.")
                            .font(NX.body(14))
                            .foregroundStyle(NX.textMuted)
                    }
                    ForEach(model.groups) { group in
                        GroupCard(channel: group)
                    }

                    SectionCaption(text: "Private").padding(.top, 8)
                    if directs.isEmpty {
                        Text("Pair with someone to get a private channel.")
                            .font(NX.body(14))
                            .foregroundStyle(NX.textMuted)
                    }
                    VStack(spacing: 0) {
                        ForEach(directs) { channel in
                            PrivateRow(channel: channel)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $creatingGroup) { NewGroupView() }
    }
}

/// A talk group on glass, with its scan toggle.
struct GroupCard: View {
    @EnvironmentObject private var model: AppModel
    let channel: Channel

    private var selected: Bool { model.snapshot.settings.selectedChannel == channel.id }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.engine.select(channel.id)
                model.tab = .talk
            } label: {
                HStack(spacing: 12) {
                    InitialsRing(name: channel.name, size: 42, lit: channel.isMonitored)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(NX.label(16, .bold))
                            .foregroundStyle(NX.text)
                        Text(detail)
                            .font(NX.body(13))
                            .foregroundStyle(NX.textDim)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Selects this channel")

            Toggle("Scan \(channel.name)", isOn: Binding(
                get: { channel.isMonitored },
                set: { model.engine.setMonitored(channel.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(NeonToggleStyle())
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 72)
        .glass(cornerRadius: 20, glow: selected ? 0.35 : 0.1, strong: selected)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selected ? NX.ice.opacity(0.85) : .clear, lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                model.engine.leaveGroup(channel.id)
            } label: {
                Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private var detail: String {
        let members = "\(channel.members.count + 1) members"
        if selected { return members + " · selected" }
        return members + (channel.isMonitored ? " · scanning" : " · muted")
    }
}

/// A private (1:1) channel: light-line row with an online dot.
struct PrivateRow: View {
    @EnvironmentObject private var model: AppModel
    let channel: Channel

    private var online: Bool { model.isOnline(channel) }

    var body: some View {
        Button {
            model.engine.select(channel.id)
            model.tab = .talk
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(online ? NX.cyan : Color(hex: 0x45707C))
                    .frame(width: 10, height: 10)
                    .shadow(color: online ? NX.cyan : .clear, radius: 5)
                    .accessibilityHidden(true)
                Text(model.displayName(of: channel))
                    .font(NX.body(16, .medium))
                    .foregroundStyle(NX.text)
                Spacer()
                Text(online ? "On the grid" : "Wakes by push")
                    .font(NX.body(12))
                    .foregroundStyle(NX.textMuted)
                if model.snapshot.settings.selectedChannel == channel.id {
                    Image(systemName: "checkmark").foregroundStyle(NX.cyan)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(NX.cyan.opacity(0.18)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct NewGroupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<IdentityID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group name", text: $name)
                        .font(NX.body(17))
                }
                .nxRows()
                Section {
                    ForEach(model.snapshot.contacts) { contact in
                        Button {
                            if selected.contains(contact.id) { selected.remove(contact.id) } else { selected.insert(contact.id) }
                        } label: {
                            HStack {
                                InitialsRing(name: contact.name, size: 32, lit: selected.contains(contact.id))
                                Text(contact.name).font(NX.body(16)).foregroundStyle(NX.text)
                                Spacer()
                                if selected.contains(contact.id) { Image(systemName: "checkmark").foregroundStyle(NX.cyan) }
                            }
                        }
                        .accessibilityAddTraits(selected.contains(contact.id) ? .isSelected : [])
                    }
                } header: {
                    SectionCaption(text: "Members")
                } footer: {
                    Text("Every member gets the group key sealed to their device. Groups are a full mesh, so keep them to about ten people.")
                        .font(NX.body(13))
                }
                .nxRows()
            }
            .nxForm()
            .navigationTitle("New talk group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.engine.createGroup(name: name.trimmingCharacters(in: .whitespaces), members: Array(selected))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

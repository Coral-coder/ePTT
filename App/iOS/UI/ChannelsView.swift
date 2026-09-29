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
                            if model.snapshot.contacts.isEmpty {
                                withAnimation { model.banner = "Pair with someone first, then make a talk group with them." }
                            } else {
                                creatingGroup = true
                            }
                        } label: {
                            GelBead(size: 44) { Image(systemName: "plus").font(.system(size: 18, weight: .bold)) }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
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
                Text(model.connectionStatus(channel))
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
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty && !selected.isEmpty }

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.94, energy: 0.6, moving: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ScreenTitle(text: "New group")
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .font(NX.body(16, .medium))
                            .foregroundStyle(NX.frost)
                    }

                    SectionCaption(text: "Name")
                    TextField("", text: $name, prompt: Text("Group name").foregroundColor(NX.textMuted))
                        .font(NX.body(17))
                        .foregroundStyle(NX.text)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .padding(14)
                        .glass(cornerRadius: 16, glow: 0.1)

                    SectionCaption(text: "Members").padding(.top, 6)
                    VStack(spacing: 8) {
                        ForEach(model.snapshot.contacts) { contact in
                            let on = selected.contains(contact.id)
                            Button {
                                if on { selected.remove(contact.id) } else { selected.insert(contact.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    InitialsRing(name: contact.name, size: 36, lit: on)
                                    Text(contact.name).font(NX.body(16, .medium)).foregroundStyle(NX.text)
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(on ? NX.cyan : NX.textMuted)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 56)
                                .contentShape(Rectangle())
                                .glass(cornerRadius: 16, glow: on ? 0.3 : 0.08)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    Text("Every member gets the group key sealed to their device. Groups are a full mesh, so keep them to about ten people.")
                        .font(NX.body(13))
                        .foregroundStyle(NX.textMuted)

                    Button("CREATE GROUP") {
                        let groupName = trimmedName
                        model.engine.createGroup(name: groupName, members: Array(selected))
                        withAnimation { model.banner = "Talk group \(groupName) created" }
                        dismiss()
                    }
                    .buttonStyle(NXButtonStyle(kind: .gel))
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.5)
                    .padding(.top, 6)
                    if !canCreate {
                        Text(trimmedName.isEmpty ? "Give the group a name." : "Pick at least one member.")
                            .font(NX.body(13))
                            .foregroundStyle(NX.textDim)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if model.snapshot.contacts.count == 1, let only = model.snapshot.contacts.first { selected = [only.id] }
            nameFocused = true
        }
    }
}

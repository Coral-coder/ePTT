import SwiftUI
import EPTTCore

struct ChannelsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var creatingGroup = false
    @State private var joining = false

    private var directs: [Channel] { model.snapshot.channels.filter { $0.kind == .direct } }

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.9, energy: 0.8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .bottom) {
                        ScreenTitle(text: "Channels")
                        Spacer()
                        Menu {
                            Button {
                                creatingGroup = true
                            } label: {
                                Label("New talk group", systemImage: "person.3")
                            }
                            Button {
                                joining = true
                            } label: {
                                Label("Join with a QR code", systemImage: "qrcode.viewfinder")
                            }
                        } label: {
                            GelBead(size: 44) { Image(systemName: "plus").font(.system(size: 18, weight: .bold)) }
                                .contentShape(Circle())
                        }
                        .accessibilityLabel("New or join talk group")
                    }

                    SectionCaption(text: "Talk groups · scan")
                    ForEach(model.snapshot.joinRequests) { request in
                        JoinRequestRow(request: request)
                    }
                    ForEach(model.snapshot.pendingJoins) { join in
                        PendingJoinCard(join: join)
                    }
                    if model.groups.isEmpty && model.snapshot.pendingJoins.isEmpty {
                        Text("No talk groups yet. Tap + to make one or to scan someone's group code.")
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
        .sheet(isPresented: $joining) { AddContactView() }
    }
}

/// "Sam wants to join Crew" with Let in / No, inline (Channels list, the invite sheet).
struct JoinRequestRow: View {
    @EnvironmentObject private var model: AppModel
    let request: JoinRequest

    var body: some View {
        HStack(spacing: 12) {
            InitialsRing(name: request.name, size: 42, lit: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name)
                    .font(NX.label(16, .bold))
                    .foregroundStyle(NX.text)
                    .lineLimit(1)
                Text("Wants to join \(request.group)")
                    .font(NX.body(13))
                    .foregroundStyle(NX.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("No") { model.engine.answerJoinRequest(request.id, allow: false) }
                .font(NX.label(14, .bold))
                .foregroundStyle(NX.textMuted)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
            Button("LET IN") { model.engine.answerJoinRequest(request.id, allow: true) }
                .buttonStyle(NXButtonStyle(kind: .gel))
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 72)
        .glass(cornerRadius: 20, glow: 0.35, strong: true)
    }
}

/// A talk group we asked to join, waiting for the inviter's phone to send its key.
struct PendingJoinCard: View {
    @EnvironmentObject private var model: AppModel
    let join: PendingJoin

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(NX.cyan)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(join.group)
                    .font(NX.label(16, .bold))
                    .foregroundStyle(NX.text)
                Text("Joining: waiting for \(join.inviter) to let you in")
                    .font(NX.body(13))
                    .foregroundStyle(NX.textDim)
            }
            Spacer(minLength: 0)
            Menu {
                Button {
                    model.engine.retryJoin(join.id)
                } label: {
                    Label("Ask again", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    model.engine.cancelJoin(join.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NX.frost)
                    .frame(width: 40, height: 40)
                    .background(GlassBackground(shape: Circle(), glow: 0.2))
            }
            .accessibilityLabel("Options for joining \(join.group)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 72)
        .glass(cornerRadius: 20, glow: 0.1)
    }
}

/// A talk group on glass, with its scan toggle.
struct GroupCard: View {
    @EnvironmentObject private var model: AppModel
    let channel: Channel
    @State private var inviting = false

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

            Button {
                inviting = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NX.frost)
                    .frame(width: 40, height: 40)
                    .background(GlassBackground(shape: Circle(), glow: 0.2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Invite people to \(channel.name) with a QR code")

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
        .sheet(isPresented: $inviting) { GroupInviteView(channel: channel) }
        .contextMenu {
            PinMenuItem(channel: channel.id)
            Button {
                inviting = true
            } label: {
                Label("Invite with QR code", systemImage: "qrcode")
            }
            if !channel.members.isEmpty {
                // Removing someone changes the group key, so they can't hear anything said after.
                Menu {
                    ForEach(channel.members, id: \.self) { member in
                        Button(role: .destructive) {
                            model.engine.removeMember(member, from: channel.id)
                        } label: {
                            Text(model.snapshot.contacts.first { $0.id == member }?.name ?? "Unknown member")
                        }
                    }
                } label: {
                    Label("Remove member", systemImage: "person.badge.minus")
                }
            }
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
        .contextMenu { PinMenuItem(channel: channel.id) }
    }
}

struct NewGroupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<IdentityID> = []
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty }

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
                    if model.snapshot.contacts.isEmpty {
                        Text("No contacts yet, and that's fine: create the group, then tap its QR button to invite people, or add them with an optical handshake from there.")
                            .font(NX.body(14))
                            .foregroundStyle(NX.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    Text("Optional: you can add people later with the group's QR code. Every member gets the group key sealed to their device. Groups are a full mesh, so keep them to about ten people.")
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
                        Text("Give the group a name.")
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

/// A QR code for joining a talk group. It carries no group key: scanning it sends this phone a
/// request, and this phone then sends the key to the new member, sealed to them alone.
struct GroupInviteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: Channel
    @State private var uri: String?
    @State private var expires: Date?
    @State private var faceToFace = false

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.94, energy: 0.6, moving: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        ScreenTitle(text: "Invite")
                        Spacer()
                        Button("Done") { dismiss() }
                            .font(NX.body(16, .medium))
                            .foregroundStyle(NX.frost)
                    }
                    // Someone scanning right now: answer here (the full-screen prompt can't open
                    // over this sheet).
                    ForEach(model.snapshot.joinRequests) { request in
                        JoinRequestRow(request: request)
                    }
                    Text("Scan to join \(channel.name)")
                        .font(NX.label(17, .bold))
                        .foregroundStyle(NX.text)
                    QRFrame(uri: uri)
                        .frame(maxWidth: .infinity)
                    if let expires {
                        Text("Works until \(expires.formatted(date: .omitted, time: .shortened)) \(Calendar.current.isDateInToday(expires) ? "today" : "tomorrow"). Anyone who scans it before then can join, so only show it to people you want in the group.")
                            .font(NX.body(13))
                            .foregroundStyle(NX.textDim)
                    }
                    Text("When someone scans it, your phone asks whether to let them in: straight away nearby or online, otherwise the next time you open NXTPTT. Once you say yes, everyone in the group gets their key, sealed to their device.")
                        .font(NX.body(13))
                        .foregroundStyle(NX.textMuted)
                    Button {
                        faceToFace = true
                    } label: {
                        Label("OPTICAL HANDSHAKE", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    .buttonStyle(NXButtonStyle(kind: .gel))
                    .accessibilityHint("Pair by light with someone in front of you and add them to this group")
                    HStack(spacing: 12) {
                        if let uri {
                            ShareLink(item: uri) { Text("SHARE LINK") }
                                .buttonStyle(NXButtonStyle(kind: .glass))
                        }
                        Button("NEW CODE") { load(fresh: true) }
                            .buttonStyle(NXButtonStyle(kind: .glass))
                            .accessibilityHint("Stops the current code from working and makes a new one")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { load(fresh: false) }
        .fullScreenCover(isPresented: $faceToFace) { FacePairView(group: channel) }
    }

    private func load(fresh: Bool) {
        uri = nil
        model.engine.groupJoinURI(for: channel.id, fresh: fresh) { newURI, newExpiry in
            uri = newURI
            expires = newExpiry
            if newURI == nil { model.banner = "Couldn't make a code for this group" }
        }
    }
}

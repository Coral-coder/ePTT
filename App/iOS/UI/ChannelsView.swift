import SwiftUI
import EPTTCore

struct ChannelsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var creatingGroup = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.groups) { group in
                        ChannelRow(channel: group)
                            .swipeActions {
                                Button("Leave", role: .destructive) { model.engine.leaveGroup(group.id) }
                            }
                    }
                    if model.groups.isEmpty {
                        Text("No talk groups yet").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Talk groups")
                } footer: {
                    Text("Scanned channels play when someone talks on them, even if another channel is selected.")
                }

                Section("Private") {
                    ForEach(model.snapshot.channels.filter { $0.kind == .direct }) { channel in
                        ChannelRow(channel: channel)
                    }
                }
            }
            .navigationTitle("Channels")
            .toolbar {
                Button {
                    creatingGroup = true
                } label: {
                    Label("New talk group", systemImage: "plus")
                }
                .disabled(model.snapshot.contacts.isEmpty)
            }
            .sheet(isPresented: $creatingGroup) { NewGroupView() }
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject private var model: AppModel
    let channel: Channel

    var body: some View {
        HStack {
            Circle()
                .fill(model.isOnline(channel) ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(model.displayName(of: channel))
                if channel.kind == .group {
                    Text("\(channel.members.count + 1) members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.snapshot.settings.selectedChannel == channel.id {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
            Toggle("Scan", isOn: Binding(
                get: { channel.isMonitored },
                set: { model.engine.setMonitored(channel.id, $0) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { model.engine.select(channel.id) }
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
                TextField("Group name", text: $name)
                Section("Members") {
                    ForEach(model.snapshot.contacts) { contact in
                        Button {
                            if selected.contains(contact.id) { selected.remove(contact.id) } else { selected.insert(contact.id) }
                        } label: {
                            HStack {
                                Text(contact.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(contact.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section {
                    Text("Every member gets the group key over their private channel. Groups are a full mesh, so keep them to about ten people.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New talk group")
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
    }
}

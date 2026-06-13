import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

enum MainTab: Hashable { case chat, files, config }

/// Barre d'onglets principale (haut de la colonne gauche), façon app moderne.
struct MainTabBar: View {
    @Binding var selected: MainTab
    var body: some View {
        HStack(spacing: 6) {
            tab(.chat, "Chat", "bubble.left.and.bubble.right")
            tab(.files, "Fichiers", "folder")
            tab(.config, "Config", "gearshape")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func tab(_ t: MainTab, _ label: String, _ icon: String) -> some View {
        let on = selected == t
        Button { selected = t } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(on ? Color.accentColor.opacity(0.18) : Color.clear))
            .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    /// Pseudo-sélection pour la conversation de groupe.
    static let broadcastID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var pairing: PairingService
    @State private var selection: UUID?
    @State private var mainTab: MainTab = .chat
    @State private var showPairingSheet = false
    @State private var showNewChannel = false
    @State private var showNewRoom = false
    @State private var newChannelRoom: Room?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
            MainTabBar(selected: $mainTab)
            Divider()
            List(selection: $selection) {
                if !store.contacts.isEmpty {
                    Section("Groupe") {
                        Label("Tous les contacts", systemImage: "person.3")
                            .tag(Self.broadcastID)
                    }
                    // Rooms façon Slack : chaque room contient ses canaux.
                    ForEach(store.rooms) { room in
                        Section {
                            ForEach(store.channels.filter { $0.roomID == room.id }) { channel in
                                ChannelRow(channel: channel, selection: $selection)
                            }
                            if room.createdBy == store.config.myID {
                                Button {
                                    newChannelRoom = room
                                    showNewChannel = true
                                } label: {
                                    Label("Nouveau canal…", systemImage: "plus.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Label(room.name, systemImage: "building.2")
                                Spacer()
                            }
                            .contextMenu {
                                if room.createdBy == store.config.myID {
                                    Button("Supprimer la room", role: .destructive) {
                                        store.removeRoom(room.id)
                                    }
                                }
                            }
                        }
                    }
                    Section("Canaux") {
                        ForEach(store.channels.filter { $0.roomID == nil }) { channel in
                            ChannelRow(channel: channel, selection: $selection)
                        }
                        Button {
                            newChannelRoom = nil
                            showNewChannel = true
                        } label: {
                            Label("Nouveau canal…", systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        Button {
                            showNewRoom = true
                        } label: {
                            Label("Nouvelle room…", systemImage: "building.2.crop.circle.badge.plus")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Contacts") {
                    ForEach(store.contacts) { contact in
                        ContactRow(contact: contact)
                            .tag(contact.id)
                            .contextMenu {
                                Button("Supprimer le contact", role: .destructive) {
                                    store.removeContact(contact.id)
                                    if selection == contact.id { selection = nil }
                                }
                            }
                    }
                }
            }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { showPairingSheet = true } label: {
                        Label("Ajouter un contact", systemImage: "person.badge.plus")
                    }
                }
            }
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showPairingSheet, onDismiss: { pairing.cancel() }) {
            PairingSheet()
        }
        .sheet(isPresented: $showNewChannel) {
            NewChannelSheet(room: newChannelRoom)
        }
        .sheet(isPresented: $showNewRoom) {
            NewRoomSheet()
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    /// Contenu de droite selon l'onglet principal et la sélection latérale.
    @ViewBuilder
    private var detailContent: some View {
        switch mainTab {
        case .config:
            ConfigTab()
        case .chat:
            if selection == Self.broadcastID {
                GroupChatView()
            } else if let id = selection, let channel = store.channels.first(where: { $0.id == id }) {
                ChannelChatView(channel: channel)
            } else if let id = selection, let contact = store.contacts.first(where: { $0.id == id }) {
                ConversationView(contact: contact)
            } else {
                WelcomeView(showPairingSheet: $showPairingSheet, openConfig: { mainTab = .config })
            }
        case .files:
            if let id = selection, let contact = store.contacts.first(where: { $0.id == id }) {
                ContactFilesView(contact: contact)
            } else {
                ContentPlaceholder(icon: "folder",
                                   text: "Sélectionne un contact à gauche pour voir et télécharger ses fichiers.")
            }
        }
    }
}

/// Message centré quand la zone de détail n'a rien à afficher.
struct ContentPlaceholder: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContactRow: View {
    @EnvironmentObject var store: AppStore
    let contact: Contact

    var body: some View {
        HStack {
            AvatarView(name: contact.name, id: contact.id, size: 24)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(store.isOnline(contact) ? Color.green : Color.gray.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
            Text(contact.name)
            Spacer()
            UnreadBadge(count: store.unreadCount(forContact: contact.id))
            let waiting = store.downloads.filter {
                $0.contactID == contact.id && ($0.status == .waiting || $0.status == .transferring)
            }.count
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
        }
    }
}

/// Avatar rond avec initiales, couleur stable dérivée de l'identité.
struct AvatarView: View {
    let name: String
    let id: UUID
    var size: CGFloat = 28

    static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .cyan, .mint,
    ]

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    var color: Color {
        // Hash stable (le hashValue de Swift change à chaque lancement).
        let stable = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[stable % Self.palette.count]
    }

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Pastille rouge de messages non lus.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: AppStore
    @Binding var showPairingSheet: Bool
    var openConfig: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.person.crop")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("CrocShare").font(.largeTitle.bold())
            Text("Partage de dossier entre contacts, propulsé par croc.\nLes fichiers transitent chiffrés de bout en bout, sans serveur à toi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if store.crocPath == nil {
                Label("croc introuvable — reconstruis l'app avec make-app.sh (croc est normalement embarqué)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if store.config.sharedFolder == nil {
                Button("1. Choisir mon dossier partagé…") { openConfig() }
                    .buttonStyle(.borderedProminent)
            }
            Button(store.config.sharedFolder == nil ? "2. Ajouter un contact…" : "Ajouter un contact…") {
                showPairingSheet = true
            }
        }
        .padding(40)
    }
}

/// En-tête commun d'une conversation / vue fichiers : avatar + nom + présence.
struct ContactHeader: View {
    @EnvironmentObject var store: AppStore
    let contact: Contact
    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: contact.name, id: contact.id, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).font(.headline)
                Text(store.isOnline(contact) ? "en ligne" : "hors ligne")
                    .font(.caption)
                    .foregroundStyle(store.isOnline(contact) ? Color.green : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

/// Onglet Chat pour un contact : en-tête + conversation.
struct ConversationView: View {
    let contact: Contact
    var body: some View {
        VStack(spacing: 0) {
            ContactHeader(contact: contact)
            Divider()
            ChatView(contact: contact)
        }
    }
}

/// Onglet Fichiers pour un contact : en-tête + arborescence du dossier partagé.
struct ContactFilesView: View {
    @EnvironmentObject var store: AppStore
    let contact: Contact

    var manifest: Manifest? { store.manifests[contact.id] }
    var pendings: [PendingDownload] {
        store.downloads.filter { $0.contactID == contact.id }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Arborescence du dossier partagé du contact (dossiers dépliables).
    var fileTree: [FileNode] {
        guard let manifest else { return [] }
        let entries = manifest.files.map { (components: $0.path.split(separator: "/").map(String.init), file: $0) }
        return FileNode.build(entries: entries, prefix: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ContactHeader(contact: contact)
            Divider()
            filesView
        }
    }

    @ViewBuilder
    private var filesView: some View {
        if let manifest, !manifest.files.isEmpty {
            List {
                Section {
                    HStack {
                        Text("\(manifest.files.count) fichiers — liste du \(manifest.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Tout télécharger") {
                            for file in manifest.files {
                                store.enqueueDownload(file: file, contact: contact)
                            }
                        }
                        .font(.caption)
                    }
                }
                OutlineGroup(fileTree, children: \.children) { node in
                    if let file = node.file {
                        RemoteFileRow(file: file, contact: contact)
                    } else {
                        HStack {
                            Label(node.name, systemImage: "folder.fill")
                            Text("\(node.allFiles.count)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                for file in node.allFiles {
                                    store.enqueueDownload(file: file, contact: contact)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Télécharger tout le dossier « \(node.name) »")
                        }
                    }
                }
                if !pendings.isEmpty {
                    Section {
                        ForEach(pendings) { item in
                            PendingRow(item: item)
                        }
                    } header: {
                        HStack {
                            Text("Téléchargements")
                            Spacer()
                            Button("Effacer les terminés") { store.clearFinishedDownloads() }
                                .font(.caption)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: store.isOnline(contact) ? "tray" : "wifi.slash")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text(store.isOnline(contact)
                     ? "Aucun fichier partagé pour le moment."
                     : "Hors ligne — la liste apparaîtra à sa prochaine connexion.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let contact: Contact
    @State private var draft = ""

    var messages: [ChatMessage] {
        (store.chats[contact.id] ?? []).filter { $0.channelID == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(messages: messages, myID: store.config.myID, showSender: false)
            Divider()
            ChatComposer(draft: $draft, placeholder: "Message à \(contact.name)…") { text in
                store.sendMessage(text, to: contact)
            }
            if !store.isOnline(contact) {
                Text("Hors ligne — les messages seront remis à sa prochaine connexion.")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }
        }
        .chatFileDrop(scopeName: contact.name) { attachment in
            store.sendMessage("", attachment: attachment, to: contact)
        }
        .onAppear { store.markRead(contact.id) }
        .onChange(of: messages.count) { _ in store.markRead(contact.id) }
    }
}

struct GroupChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft = ""

    /// Union de toutes les conversations directes, dédoublonnée par id
    /// (un message de groupe a le même id dans chaque conversation).
    var messages: [ChatMessage] {
        var seen = Set<UUID>()
        return store.chats.values.flatMap { $0 }
            .filter { $0.channelID == nil }
            .sorted { $0.date < $1.date }
            .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Tous les contacts", systemImage: "person.3")
                    .font(.title2.bold())
                Spacer()
                Text("Envoyé à chacun de tes \(store.contacts.count) contacts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ChatTranscript(messages: messages, myID: store.config.myID, showSender: true)
            Divider()
            ChatComposer(draft: $draft, placeholder: "Message au groupe…") { text in
                store.broadcast(text)
            }
        }
        .chatFileDrop(scopeName: "Tous") { attachment in
            store.broadcast("", attachment: attachment)
        }
    }
}

struct ChannelChatView: View {
    @EnvironmentObject var store: AppStore
    let channel: Channel
    @State private var draft = ""
    @State private var showMembers = false

    var members: [Contact] {
        store.contacts.filter { channel.memberIDs.contains($0.id) }
    }

    var isCreator: Bool { channel.createdBy == store.config.myID }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(channel.name, systemImage: "number")
                    .font(.title2.bold())
                Spacer()
                Text(members.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                if isCreator {
                    Button {
                        showMembers = true
                    } label: {
                        Label("Inviter", systemImage: "person.badge.plus")
                    }
                    .help("Inviter ou retirer des contacts de ce canal")
                } else if let creator = store.contacts.first(where: { $0.id == channel.createdBy }) {
                    Text("géré par \(creator.name)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding()
            .sheet(isPresented: $showMembers) {
                ChannelMembersSheet(channel: channel)
            }
            Divider()
            ChatTranscript(messages: store.messages(in: channel),
                           myID: store.config.myID, showSender: true)
            Divider()
            ChatComposer(draft: $draft, placeholder: "Message dans #\(channel.name)…") { text in
                store.sendChannelMessage(text, in: channel)
            }
        }
        .chatFileDrop(scopeName: channel.name) { attachment in
            store.sendChannelMessage("", attachment: attachment, in: channel)
        }
        .onAppear { store.markRead(channel.id) }
        .onChange(of: store.messages(in: channel).count) { _ in store.markRead(channel.id) }
    }
}

/// Ligne de canal dans la barre latérale.
struct ChannelRow: View {
    @EnvironmentObject var store: AppStore
    let channel: Channel
    @Binding var selection: UUID?

    var body: some View {
        HStack {
            Label(channel.name, systemImage: "number")
            Spacer()
            UnreadBadge(count: store.unreadCount(forChannel: channel))
        }
        .tag(channel.id)
        .contextMenu {
            Button("Supprimer le canal", role: .destructive) {
                store.channels.removeAll { $0.id == channel.id }
                if selection == channel.id { selection = nil }
            }
        }
    }
}

struct NewRoomSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var selected = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nouvelle room").font(.title3.bold())
            TextField("Nom de la room (ex. studio)", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Membres").font(.headline)
            ForEach(store.contacts) { contact in
                Toggle(contact.name, isOn: Binding(
                    get: { selected.contains(contact.id) },
                    set: { on in
                        if on { selected.insert(contact.id) } else { selected.remove(contact.id) }
                    }
                ))
            }
            Text("La room et ses canaux apparaîtront chez les membres à leur prochaine connexion.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Créer") {
                    store.rooms.append(Room(
                        id: UUID(),
                        name: name.trimmingCharacters(in: .whitespaces),
                        memberIDs: Array(selected),
                        createdBy: store.config.myID
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct NewChannelSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var room: Room?
    @State private var name = ""
    @State private var selected = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(room.map { "Nouveau canal dans « \($0.name) »" } ?? "Nouveau canal")
                .font(.title3.bold())
            TextField("Nom du canal (ex. projet-x)", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Membres").font(.headline)
            ForEach(store.contacts) { contact in
                Toggle(contact.name, isOn: Binding(
                    get: { selected.contains(contact.id) },
                    set: { on in
                        if on { selected.insert(contact.id) } else { selected.remove(contact.id) }
                    }
                ))
            }
            Text("Le canal apparaîtra automatiquement chez les membres à leur prochaine connexion. Pour que chacun voie les messages de tous, les membres doivent être appairés entre eux.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Créer") {
                    store.channels.append(Channel(
                        id: UUID(),
                        name: name.trimmingCharacters(in: .whitespaces),
                        memberIDs: Array(selected),
                        createdBy: store.config.myID,
                        roomID: room?.id
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            // Dans une room, les membres de la room sont présélectionnés.
            if let room { selected = Set(room.memberIDs) }
        }
    }
}

/// Appairage asynchrone : fichier .crocinvite à envoyer par mail/message.
/// Pas besoin d'être en ligne en même temps — la connexion s'établit toute
/// seule à la première présence simultanée.
struct InviteFilePane: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 12) {
            Text("Envoie un fichier d'invitation par mail ou message. Ton contact l'importe quand il veut — pas besoin d'être connectés en même temps : la liaison s'établira automatiquement.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Créer une invitation…") { exportInvite() }
                    .buttonStyle(.borderedProminent)
                Button("Importer une invitation…") { importInvite() }
            }

            if !store.pendingInvites.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.pendingInvites) { invite in
                        HStack {
                            Image(systemName: "hourglass")
                            Text("Invitation du \(invite.createdAt.formatted(date: .abbreviated, time: .shortened)) — en attente d'acceptation")
                                .font(.caption)
                            Button("Révoquer") {
                                store.pendingInvites.removeAll { $0.id == invite.id }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func exportInvite() {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "crocinvite") {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "Invitation CrocShare de \(store.config.myName).crocinvite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let invite = store.makeInvite()
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? (try? enc.encode(invite))?.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func importInvite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "crocinvite") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(InviteFile.self, from: data)
        else { return }
        store.importInvite(file)
    }
}

/// Invitation / retrait de membres d'un canal existant (créateur uniquement).
/// Les invités voient le canal apparaître à leur prochaine connexion.
struct ChannelMembersSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let channel: Channel
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Membres de #\(channel.name)").font(.title3.bold())
            ForEach(store.contacts) { contact in
                Toggle(isOn: Binding(
                    get: { selected.contains(contact.id) },
                    set: { on in
                        if on { selected.insert(contact.id) } else { selected.remove(contact.id) }
                    }
                )) {
                    HStack {
                        Text(contact.name)
                        if !channel.memberIDs.contains(contact.id) {
                            Text("nouveau").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                }
            }
            Text("Les invités verront le canal et son fil apparaître automatiquement à leur prochaine connexion. Un contact décoché perd l'accès au canal.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") {
                    store.updateChannelMembers(channel.id, memberIDs: Array(selected))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { selected = Set(channel.memberIDs) }
    }
}

/// Journal des opérations croc, pour diagnostiquer les soucis de connexion.
struct SyncLogSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Journal de synchronisation").font(.title3.bold())
                Spacer()
                Button("Effacer") { store.syncLog.removeAll() }
                Button("Copier") {
                    let text = store.syncLog.map {
                        "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.contact)] \($0.channel) \($0.ok ? "OK" : "ÉCHEC") \($0.detail)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Fermer") { dismiss() }
            }
            if store.syncLog.isEmpty {
                Text("Aucune opération enregistrée pour le moment.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(store.syncLog.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(entry.ok ? .green : .orange)
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.system(.caption, design: .monospaced))
                        Text("[\(entry.contact)]").font(.caption.bold())
                        Text(entry.channel).font(.caption)
                        Text(entry.detail).font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(minHeight: 320)
            }
            Text("« timeout (personne en face) » est normal quand le contact est hors ligne. Toute autre erreur répétée indique un problème réseau ou de relai.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 640, height: 460)
    }
}

// MARK: - Drag & drop de fichiers dans le chat

extension View {
    /// Dépôt d'un fichier dans une conversation : copié dans le dossier partagé
    /// (Chat/<scope>/) puis envoyé comme pièce jointe.
    func chatFileDrop(scopeName: String, onImport: @escaping (Attachment) -> Void) -> some View {
        modifier(ChatFileDropModifier(scopeName: scopeName, onImport: onImport))
    }
}

struct ChatFileDropModifier: ViewModifier {
    @EnvironmentObject var store: AppStore
    let scopeName: String
    let onImport: (Attachment) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.accentColor.opacity(0.07))
                        .overlay {
                            Label("Déposer pour partager", systemImage: "square.and.arrow.down")
                                .font(.title3)
                        }
                        .padding(6)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.isFileURL else { return }
                        Task { @MainActor in
                            if store.config.sharedFolder == nil {
                                Notifier.notify(title: "Dossier partagé manquant",
                                                body: "Choisis d'abord ton dossier partagé dans les Réglages.")
                                return
                            }
                            if let attachment = store.importChatFile(url, scopeName: scopeName) {
                                onImport(attachment)
                            }
                        }
                    }
                }
                return true
            }
    }
}

struct ChatTranscript: View {
    let messages: [ChatMessage]
    let myID: UUID
    let showSender: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(messages) { msg in
                        ChatBubble(message: msg, isMine: msg.fromID == myID, showSender: showSender)
                            .id(msg.id)
                    }
                }
                .padding()
            }
            .onAppear { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            .onChange(of: messages.count) { _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }
}

struct ChatBubble: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let isMine: Bool
    let showSender: Bool

    /// Rendu Markdown inline : **gras**, _italique_, ~~barré~~, `code`, [liens](…).
    var formattedText: AttributedString {
        (try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 60) }
            if !isMine {
                AvatarView(name: message.fromName, id: message.fromID, size: 28)
                    .padding(.top, 2)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !isMine {
                    Text(message.fromName)
                        .font(.caption.bold())
                        .foregroundStyle(AvatarView(name: message.fromName, id: message.fromID).color)
                }
                if let attachment = message.attachment {
                    AttachmentBubble(message: message, attachment: attachment, isMine: isMine)
                }
                if let riveURL = RiveLinkPreview.riveLink(in: message.text) {
                    RiveLinkPreview(url: riveURL)
                }
                if !message.text.isEmpty {
                    Text(formattedText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.2))
                        )
                        .foregroundStyle(isMine ? Color.white : Color.primary)
                }
                HStack(spacing: 4) {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                    if isMine {
                        Image(systemName: message.delivered ? "checkmark.circle.fill" : "clock")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !isMine { Spacer(minLength: 60) }
        }
        .contextMenu {
            Button(role: .destructive) {
                store.deleteMessage(message)
            } label: {
                Label(isMine ? "Supprimer pour tout le monde" : "Supprimer pour moi",
                      systemImage: "trash")
            }
        }
    }
}

/// Pièce jointe dans une bulle : vidéo lisible sur place, image affichée,
/// sinon bouton de téléchargement (même file d'attente que les fichiers).
struct AttachmentBubble: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let attachment: Attachment
    let isMine: Bool

    var senderContact: Contact? {
        store.contacts.first { $0.id == message.fromID }
    }

    /// Où le fichier vit (ou vivra) sur CE Mac.
    var localURL: URL? {
        if isMine {
            return store.sharedFolderURL?.appendingPathComponent(attachment.relPath)
        }
        guard let contact = senderContact else { return nil }
        return store.downloadFolderURL(for: contact).appendingPathComponent(attachment.relPath)
    }

    var isDownloaded: Bool {
        localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    var pending: PendingDownload? {
        guard let contact = senderContact else { return nil }
        return store.downloads.first {
            $0.contactID == contact.id && $0.filePath == attachment.relPath
                && ($0.status == .waiting || $0.status == .transferring)
        }
    }

    var body: some View {
        Group {
            if isDownloaded, let url = localURL, attachment.isVideo {
                VideoBubble(url: url)
            } else if isDownloaded, let url = localURL, attachment.isRive {
                RiveBubble(url: url)
            } else if isDownloaded, let url = localURL, attachment.isImage,
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { NSWorkspace.shared.open(url) }
            } else if isDownloaded, let url = localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("\(attachment.fileName) (\(formatBytes(attachment.size)))",
                          systemImage: "doc.fill")
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: attachment.isVideo ? "video" : "doc")
                    VStack(alignment: .leading) {
                        Text(attachment.fileName)
                        Text(formatBytes(attachment.size))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let pending {
                        if pending.status == .transferring {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "clock").foregroundStyle(.orange)
                                .help("En attente que l'expéditeur soit en ligne")
                        }
                    } else if let contact = senderContact {
                        Button {
                            store.enqueueDownload(
                                file: RemoteFile(path: attachment.relPath,
                                                 size: attachment.size, mtime: message.date),
                                contact: contact
                            )
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Télécharger")
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
            }
        }
    }
}

struct ChatComposer: View {
    @Binding var draft: String
    let placeholder: String
    let onSend: (String) -> Void
    @FocusState private var focused: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Barre de mise en forme façon Slack : agit sur la sélection.
            HStack(spacing: 12) {
                FormatButton(icon: "bold", help: "Gras") { wrap("**", "**") }
                FormatButton(icon: "italic", help: "Italique") { wrap("_", "_") }
                FormatButton(icon: "strikethrough", help: "Barré") { wrap("~~", "~~") }
                FormatButton(icon: "chevron.left.forwardslash.chevron.right", help: "Code") {
                    wrap("`", "`")
                }
                Divider().frame(height: 14)
                FormatButton(icon: "list.bullet", help: "Liste à puces") { insert("\n• ") }
                FormatButton(icon: "list.number", help: "Liste numérotée") { insert("\n1. ") }
                FormatButton(icon: "link", help: "Lien") { wrap("[", "](https://)") }
                Divider().frame(height: 14)
                FormatButton(icon: "face.smiling", help: "Émojis") {
                    focused = true
                    NSApp.orderFrontCharacterPalette(nil)
                }
                Spacer()
                FormatButton(icon: expanded ? "chevron.down" : "chevron.up",
                             help: expanded ? "Réduire le champ" : "Agrandir le champ") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    focused = true
                }
            }
            .padding(.horizontal, 2)

            HStack(alignment: .bottom) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .lineLimit(expanded ? 18...18 : 3...12)
                    .frame(minHeight: expanded ? 320 : 64, alignment: .top)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        draft = ""
    }

    /// Entoure la sélection des marqueurs (ou les insère au curseur).
    private func wrap(_ prefix: String, _ suffix: String) {
        focused = true
        if !FieldEditor.wrapSelection(prefix, suffix) { draft += prefix + suffix }
    }

    private func insert(_ text: String) {
        focused = true
        if !FieldEditor.insert(text) { draft += text }
    }
}

struct FormatButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Accès à l'éditeur de texte actif (field editor AppKit derrière le TextField)
/// pour manipuler la sélection, comme le fait Slack.
enum FieldEditor {
    static var textView: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    @discardableResult
    static func wrapSelection(_ prefix: String, _ suffix: String) -> Bool {
        guard let tv = textView else { return false }
        let range = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: range)
        tv.insertText(prefix + selected + suffix, replacementRange: range)
        if selected.isEmpty {
            // Place le curseur entre les marqueurs pour taper directement.
            tv.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length,
                                        length: 0))
        }
        return true
    }

    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard let tv = textView else { return false }
        tv.insertText(text, replacementRange: tv.selectedRange())
        return true
    }
}

/// Nœud de l'arborescence des fichiers partagés (dossier ou fichier).
struct FileNode: Identifiable {
    let id: String
    let name: String
    var children: [FileNode]?
    var file: RemoteFile?

    var allFiles: [RemoteFile] {
        if let file { return [file] }
        return (children ?? []).flatMap(\.allFiles)
    }

    static func build(entries: [(components: [String], file: RemoteFile)],
                      prefix: String) -> [FileNode] {
        var folders: [String: [(components: [String], file: RemoteFile)]] = [:]
        var leaves: [FileNode] = []
        for entry in entries {
            if entry.components.count == 1 {
                leaves.append(FileNode(id: prefix + entry.components[0],
                                       name: entry.components[0],
                                       children: nil, file: entry.file))
            } else if let first = entry.components.first {
                folders[first, default: []].append((Array(entry.components.dropFirst()), entry.file))
            }
        }
        let folderNodes = folders.map { name, sub in
            FileNode(id: prefix + name + "/", name: name,
                     children: build(entries: sub, prefix: prefix + name + "/"), file: nil)
        }
        return folderNodes.sorted { $0.name < $1.name }
            + leaves.sorted { $0.name < $1.name }
    }
}

struct RemoteFileRow: View {
    @EnvironmentObject var store: AppStore
    let file: RemoteFile
    let contact: Contact

    var pending: PendingDownload? {
        store.downloads.first {
            $0.contactID == contact.id && $0.filePath == file.path
                && ($0.status == .waiting || $0.status == .transferring)
        }
    }

    /// Le fichier est-il déjà téléchargé localement ?
    var localURL: URL {
        store.downloadFolderURL(for: contact).appendingPathComponent(file.path)
    }
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    var body: some View {
        HStack {
            Image(systemName: "doc")
            VStack(alignment: .leading) {
                Text(file.name)
                Text("\(formatBytes(file.size)) — modifié le \(file.mtime.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloaded {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Déjà téléchargé — afficher dans le Finder")
            } else if let pending {
                switch pending.status {
                case .transferring:
                    ProgressView().controlSize(.small)
                    Text("Transfert…").font(.caption).foregroundStyle(.secondary)
                default:
                    Label("En attente", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Button {
                    store.enqueueDownload(file: file, contact: contact)
                    if !store.isOnline(contact) {
                        Notifier.notify(
                            title: "Mis en attente",
                            body: "\(file.name) sera téléchargé dès que \(contact.name) sera en ligne."
                        )
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help(store.isOnline(contact)
                      ? "Télécharger maintenant"
                      : "Mettre en attente (téléchargement auto à sa connexion)")
            }
        }
        .padding(.vertical, 2)
    }
}

struct PendingRow: View {
    @EnvironmentObject var store: AppStore
    let item: PendingDownload

    var body: some View {
        HStack {
            switch item.status {
            case .waiting: Image(systemName: "clock").foregroundStyle(.orange)
            case .transferring: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text((item.filePath as NSString).lastPathComponent)
            Text(formatBytes(item.size)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if item.status == .waiting {
                Button("Annuler") {
                    store.downloads.removeAll { $0.id == item.id }
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Appairage

struct PairingSheet: View {
    @EnvironmentObject var pairing: PairingService
    @Environment(\.dismiss) var dismiss
    @State private var mode = 0
    @State private var joinCode = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Ajouter un contact").font(.title3.bold())
            Picker("", selection: $mode) {
                Text("Inviter").tag(0)
                Text("Rejoindre").tag(1)
                Text("Par fichier").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(pairing.state != .idle)

            switch pairing.state {
            case .idle:
                if mode == 2 {
                    InviteFilePane()
                } else if mode == 0 {
                    Text("Génère un code et communique-le à ton contact (téléphone, message…). Les clés seront ensuite échangées et gérées automatiquement.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Générer un code d'invitation") { pairing.host() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Saisis le code que ton contact t'a communiqué.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("ex : k7f3m2p9q4r8", text: $joinCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { pairing.join(code: joinCode) }
                    Button("Rejoindre") { pairing.join(code: joinCode) }
                        .buttonStyle(.borderedProminent)
                        .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .hosting(let code):
                Text("Communique ce code à ton contact :").foregroundStyle(.secondary)
                HStack {
                    Text(code).font(.system(.title2, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                }
                ProgressView("En attente du contact… (5 min max)")
            case .joining:
                ProgressView("Connexion à l'hôte…")
            case .success(let name):
                Label("\(name) ajouté ! La synchronisation démarre.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Fermer") { pairing.cancel(); dismiss() }
                    .buttonStyle(.borderedProminent)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                Button("Réessayer") { pairing.cancel() }
            }

            if pairing.state != .idle, !isTerminal {
                Button("Annuler") { pairing.cancel(); dismiss() }
            } else if pairing.state == .idle {
                Button("Fermer") { dismiss() }
            }
        }
        .padding(28)
        .frame(width: 420)
    }

    var isTerminal: Bool {
        if case .success = pairing.state { return true }
        if case .failed = pairing.state { return true }
        return false
    }
}

// MARK: - Réglages

/// Onglet Config : les réglages affichés en place (plus de fenêtre modale).
struct ConfigTab: View {
    var body: some View {
        ScrollView {
            SettingsContent()
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsContent: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var relay = RelayServer.shared
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Réglages").font(.title3.bold())

            LabeledContent("Mon nom") {
                TextField("Nom affiché chez tes contacts", text: Binding(
                    get: { store.config.myName },
                    set: { store.config.myName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            }

            LabeledContent("Dossier partagé") {
                HStack {
                    Text(store.config.sharedFolder ?? "Aucun")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(store.config.sharedFolder == nil ? .secondary : .primary)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button("Choisir…") {
                        if let url = pickFolder() { store.config.sharedFolder = url.path }
                    }
                }
            }

            LabeledContent("Dossier CrocShare (fichiers reçus)") {
                HStack {
                    Text(store.config.downloadFolder ?? "~/CrocShare")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button("Choisir…") {
                        if let url = pickFolder() { store.config.downloadFolder = url.path }
                    }
                }
            }

            LabeledContent("Relai personnalisé") {
                TextField("vide = relai public croc", text: Binding(
                    get: { store.config.customRelay ?? "" },
                    set: { store.config.customRelay = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(store.config.hostRelay ?? false)
            }
            Text("Optionnel : ton propre serveur « croc relay » (ex. monserveur.fr:9009). Tes contacts doivent saisir le même. Sur un même réseau local, croc se connecte en direct, sans relai.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Relai sur ce Mac") {
                Toggle("", isOn: Binding(
                    get: { store.config.hostRelay ?? false },
                    set: { enabled in
                        store.config.hostRelay = enabled
                        if enabled { relay.start() } else { relay.stop() }
                    }
                ))
                .toggleStyle(.switch)
            }
            if store.config.hostRelay ?? false {
                VStack(alignment: .leading, spacing: 4) {
                    Label(relay.running
                          ? "Relai actif — réseau local : \(relay.localIP.isEmpty ? "?" : relay.localIP):\(RelayServer.port)"
                          : "Relai arrêté (croc installé ?)",
                          systemImage: relay.running ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(relay.running ? .green : .red)
                        .font(.caption)
                    Text("Tes contacts saisissent dans « Relai personnalisé » : ton-ip-publique:\(RelayServer.port) (ou \(relay.localIP.isEmpty ? "ip-locale" : relay.localIP):\(RelayServer.port) sur le même réseau). Par Internet, ouvre les ports TCP 9009-9013 de ta box vers ce Mac. Le relai ne voit que des flux chiffrés.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            LabeledContent("croc") {
                if let path = store.crocPath {
                    Label(path, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    HStack {
                        Label("Non installé", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        Button("Re-vérifier") { store.crocPath = CrocService.findCroc() }
                    }
                }
            }
            if store.crocPath == nil {
                Text("croc est normalement embarqué dans l'app ; à défaut : brew install croc")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            LabeledContent("Debug") {
                HStack {
                    Button("Journal de synchronisation…") { showLog = true }
                    if store.hasDebugContact {
                        Button("Retirer le contact fictif") { store.removeDebugContact() }
                    } else {
                        Button("Ajouter un contact fictif") { store.addDebugContact() }
                    }
                }
            }
            Text("Contact « Démo » simulé localement : toujours en ligne, répond aux messages, fichiers téléchargeables (générés sur place). Aucun transfert croc réel.")
                .font(.caption).foregroundStyle(.secondary)

        }
        .padding(28)
        .frame(maxWidth: 600, alignment: .leading)
        .sheet(isPresented: $showLog) { SyncLogSheet() }
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

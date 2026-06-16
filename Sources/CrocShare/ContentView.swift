import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

// Route de navigation (sidebar verticale unifiée — fini les onglets du haut).
enum Route: Hashable {
    case myFiles
    case allSharedFolders
    case contact(String)
    case channel(UUID)
    case settings
}
enum ContactPane: Hashable { case chat, files }

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var p2p: P2PEngine
    @State private var route: Route? = .myFiles
    @State private var contactPane: ContactPane = .chat
    @State private var showInfo = true
    @State private var threadRoot: P2PEngine.P2PMessage?
    @State private var showPairing = false
    @State private var showNewChannel = false

    var body: some View {
        NavigationSplitView {
            UnifiedSidebar(route: $route, contactPane: $contactPane,
                           showPairing: $showPairing, showNewChannel: $showNewChannel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 258)
        } detail: {
            HStack(spacing: 0) {
                mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                rightPanel
            }
            .background(Theme.bgApp)
            .toolbar { toolbarContent }
        }
        .background(WindowConfigurator())
        .sheet(isPresented: $showPairing) { P2PPairingSheet() }
        .sheet(isPresented: $showNewChannel) { P2PChannelSheet(existing: nil) }
        .frame(minWidth: 980, minHeight: 600)
        .onChange(of: route) { _ in threadRoot = nil }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .contact(let key)? = route, p2p.contacts.contains(key) {
            ToolbarItem {
                Picker("", selection: $contactPane) {
                    Image(systemName: "bubble.left").tag(ContactPane.chat)
                    Image(systemName: "folder").tag(ContactPane.files)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showInfo.toggle() } } label: {
                    Image(systemName: showInfo ? "sidebar.trailing" : "sidebar.right")
                }.help("Panneau d'infos")
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch route {
        case .myFiles:
            MyFilesView()
        case .allSharedFolders:
            AllSharedFoldersView(onPick: { key in contactPane = .files; route = .contact(key) })
        case .settings:
            ConfigTab()
        case .channel(let id):
            if let ch = p2p.channels.first(where: { $0.id == id }) {
                P2PChannelView(channel: ch, onOpenThread: { threadRoot = $0 })
            } else { welcome }
        case .contact(let key):
            if p2p.contacts.contains(key) {
                if contactPane == .chat {
                    P2PChatView(contactKey: key, onOpenThread: { threadRoot = $0 })
                } else {
                    P2PFilesView(contactKey: key)
                }
            } else { welcome }
        case nil:
            welcome
        }
    }

    private var welcome: some View {
        WelcomeP2P(showPairing: $showPairing, openConfig: { route = .settings })
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let root = threadRoot {
            Divider()
            ThreadPanel(root: root, scope: route, onClose: { threadRoot = nil })
                .frame(width: 340)
        } else if showInfo, case .contact(let key)? = route, p2p.contacts.contains(key) {
            Divider()
            ProfilePanel(contactKey: key, openFiles: { contactPane = .files })
                .frame(width: 300)
        }
    }
}

/// Sidebar verticale unifiée (style Slack/Discord) : Mes fichiers, Salons,
/// Messages directs, Réglages — tout dans un seul panneau scrollable.
struct UnifiedSidebar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var p2p: P2PEngine
    @Binding var route: Route?
    @Binding var contactPane: ContactPane
    @Binding var showPairing: Bool
    @Binding var showNewChannel: Bool
    @State private var showChannels = true
    @State private var showContacts = true
    @State private var showSharedFolders = true

    private var totalUnread: Int {
        p2p.unread.values.reduce(0, +) + p2p.channelUnread.values.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Button(action: pickAvatar) {
                    AvatarView(
                        name: store.config.myName,
                        id: P2PEngine.uuid(forKey: p2p.myPublicKey.isEmpty ? store.config.myID.uuidString : p2p.myPublicKey),
                        size: 34,
                        photoURL: store.config.avatarPath.map { URL(fileURLWithPath: $0) }
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill").font(.system(size: 8))
                            .padding(3).background(Circle().fill(Theme.accent)).foregroundStyle(.white)
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain).help("Changer ma photo")
                VStack(alignment: .leading, spacing: 0) {
                    Text("CrocShare").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if totalUnread > 0 {
                        Text("\(totalUnread) message\(totalUnread > 1 ? "s" : "") non lu\(totalUnread > 1 ? "s" : "")")
                            .font(Theme.tiny).foregroundStyle(Theme.accent)
                    } else {
                        Text(p2p.myName.isEmpty ? "P2P chiffré" : p2p.myName)
                            .font(Theme.tiny).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
                if totalUnread > 0 { UnreadBadge(count: totalUnread) }
            }
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.md)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    navItem(title: "Mes fichiers partagés", icon: "folder.fill",
                            active: route == .myFiles) { contactPane = .files; route = .myFiles }
                    navItem(title: "Dossiers partagés", icon: "person.2.fill",
                            active: route == .allSharedFolders) { contactPane = .files; route = .allSharedFolders }

                    sectionHeader("SALONS", icon: "number", expanded: $showChannels) { showNewChannel = true }
                    if showChannels {
                        ForEach(p2p.channels) { chan in
                            navItem(title: chan.name, icon: "number", active: route == .channel(chan.id),
                                    badge: p2p.channelUnread[chan.id] ?? 0) { route = .channel(chan.id) }
                                .contextMenu { Button("Supprimer le salon", role: .destructive) { p2p.removeChannel(chan.id) } }
                        }
                        if p2p.channels.isEmpty { emptyHint("Aucun salon") }
                    }

                    sectionHeader("MESSAGES DIRECTS", icon: "bubble.left.fill", expanded: $showContacts) { showPairing = true }
                    if showContacts {
                        ForEach(p2p.contacts, id: \.self) { key in contactItem(key, pane: .chat) }
                        if p2p.contacts.isEmpty { emptyHint("Aucun contact") }
                    }

                    sectionHeader("DOSSIERS PARTAGÉS", icon: "folder.fill", expanded: $showSharedFolders) { showPairing = true }
                    if showSharedFolders {
                        ForEach(p2p.contacts, id: \.self) { key in sharedFolderItem(key) }
                        if p2p.contacts.isEmpty { emptyHint("Aucun contact fichier") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.sm)
            }

            Divider()
            VStack(spacing: 1) {
                navItem(title: "Réglages", icon: "gearshape", active: route == .settings) { route = .settings }
            }
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.sm)
        }
        .background(VisualEffectBackground())
    }

    private func navItem(title: String, icon: String, active: Bool, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: 2).fill(active ? Theme.accent : .clear).frame(width: 3, height: 16)
                Image(systemName: icon).frame(width: 18).foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                Text(title).font(Theme.body).foregroundStyle(active ? Theme.accent : Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 { UnreadBadge(count: badge) }
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(active ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
    }

    private func contactItem(_ key: String, pane: ContactPane) -> some View {
        let active = route == .contact(key) && contactPane == pane
        return Button { contactPane = pane; route = .contact(key) } label: {
            HStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: 2).fill(active ? Theme.accent : .clear).frame(width: 3, height: 18)
                P2PAvatar(contactKey: key, size: 22)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(online: p2p.isOnline(key), size: 8).offset(x: 1, y: 1) }
                Text(p2p.name(for: key)).font(Theme.body).foregroundStyle(active ? Theme.accent : Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                UnreadBadge(count: p2p.unread[key] ?? 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(active ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .contextMenu {
            Button("Supprimer le contact", role: .destructive) {
                p2p.removeContact(key); if route == .contact(key) { route = .myFiles }
            }
        }
    }

    private func sharedFolderItem(_ key: String) -> some View {
        let active = route == .contact(key) && contactPane == .files
        let count = p2p.remoteFiles[key]?.count ?? 0
        return Button {
            contactPane = .files
            route = .contact(key)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: 2).fill(active ? Theme.accent : .clear).frame(width: 3, height: 18)
                PresenceDot(online: p2p.isOnline(key), size: 9)
                    .frame(width: 22, alignment: .center)
                Text(p2p.name(for: key)).font(Theme.body).foregroundStyle(active ? Theme.accent : Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(active ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .contextMenu {
            Button("Supprimer le contact", role: .destructive) {
                p2p.removeContact(key); if route == .contact(key) { route = .myFiles }
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String? = nil, expanded: Binding<Bool>, add: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(Theme.tiny.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(action: add) { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 6).padding(.top, Theme.Space.md).padding(.bottom, 2)
    }

    private func emptyHint(_ t: String) -> some View {
        Text(t).font(Theme.small).foregroundStyle(Theme.textSecondary).padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if let png = UTType(filenameExtension: "png"), let jpg = UTType(filenameExtension: "jpg") {
            panel.allowedContentTypes = [png, jpg, UTType.image]
        }
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dst = P2PEngine.avatarsDir.appendingPathComponent("me-\(UUID().uuidString.prefix(8)).\(src.pathExtension)")
        try? FileManager.default.copyItem(at: src, to: dst)
        store.config.avatarPath = dst.path
        p2p.setMyAvatar(dst.path)
    }
}
struct P2PContactRow: View {
    @EnvironmentObject var p2p: P2PEngine
    let contactKey: String
    var body: some View {
        HStack(spacing: 9) {
            P2PAvatar(contactKey: contactKey, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(p2p.isOnline(contactKey) ? Color.green : Color.gray.opacity(0.6))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
            Text(p2p.name(for: contactKey))
            Spacer()
            UnreadBadge(count: p2p.unread[contactKey] ?? 0)
        }
        .padding(.vertical, 2)
    }
}

/// Écran d'accueil (aucun contact sélectionné).
struct WelcomeP2P: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var p2p: P2PEngine
    @Binding var showPairing: Bool
    var openConfig: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text("CrocShare").font(.largeTitle.bold())
            Text("Partage de dossier et chat en pair-à-pair, chiffré de bout en bout,\nsans serveur ni relai.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if store.config.sharedFolder == nil {
                Button("1. Choisir mon dossier partagé…") { openConfig() }
                    .buttonStyle(.borderedProminent)
            }
            Button(store.config.sharedFolder == nil ? "2. Ajouter un contact…" : "Ajouter un contact…") {
                showPairing = true
            }
            if !p2p.myPublicKey.isEmpty {
                Text("Mon identité : \(p2p.myPublicKey.prefix(16))…")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(40)
    }
}

/// Appairage P2P depuis « Ajouter un contact » (remplace l'appairage croc).
struct P2PPairingSheet: View {
    @EnvironmentObject var p2p: P2PEngine
    @Environment(\.dismiss) var dismiss
    @State private var mode = 0
    @State private var joinCode = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Ajouter un contact").font(.title3.bold())

            switch p2p.pairingState {
            case .joining:
                ProgressView().controlSize(.large)
                Text("Connexion à ton contact…").font(.callout)
                Text("Recherche sur le réseau, ça peut prendre jusqu'à 2 minutes.\nGarde cette fenêtre ouverte.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Annuler") { p2p.resetPairing() }
            case .success(let nm):
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Connecté à \(nm) !").font(.headline)
                Button("Terminer") { p2p.resetPairing(); dismiss() }.buttonStyle(.borderedProminent)
            case .failed(let msg):
                Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.red)
                Text(msg).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Réessayer") { p2p.resetPairing() }.buttonStyle(.borderedProminent)
            case .idle, .hosting:
                Picker("", selection: $mode) {
                    Text("Inviter").tag(0)
                    Text("Rejoindre").tag(1)
                }.pickerStyle(.segmented)

                if mode == 0 {
                    Text("Génère un code et transmets-le à ton contact (message, oral…). La connexion s'établit automatiquement, chiffrée, sans relai.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if p2p.inviteCode.isEmpty {
                        Button("Générer un code") { p2p.createInvite() }.buttonStyle(.borderedProminent)
                    } else {
                        HStack {
                            Text(p2p.inviteCode).font(.system(.title3, design: .monospaced).bold())
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p2p.inviteCode, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("En attente que ton contact saisisse le code…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Saisis le code que ton contact t'a communiqué.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("cs1-…", text: $joinCode).textFieldStyle(.roundedBorder).frame(width: 260)
                        .onSubmit { p2p.acceptInvite(joinCode); joinCode = "" }
                    Button("Rejoindre") { p2p.acceptInvite(joinCode); joinCode = "" }
                        .buttonStyle(.borderedProminent)
                        .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Fermer") { p2p.resetPairing(); dismiss() }
            }
        }
        .padding(28).frame(width: 420)
        .onDisappear { p2p.resetPairing() }
    }
}

/// Regroupe des messages P2P par jour (séparateurs).
func p2pDays(_ messages: [P2PEngine.P2PMessage]) -> [(date: Date, messages: [P2PEngine.P2PMessage])] {
    let cal = Calendar.current
    var out: [(date: Date, messages: [P2PEngine.P2PMessage])] = []
    for m in messages.sorted(by: { $0.date < $1.date }) {
        let day = cal.startOfDay(for: m.date)
        if let last = out.last, cal.isDate(last.date, inSameDayAs: day) {
            out[out.count - 1].messages.append(m)
        } else {
            out.append((date: day, messages: [m]))
        }
    }
    return out
}

/// Bouton + zone de dépôt pour joindre un fichier à un chat/salon P2P.
struct P2PComposerBar: View {
    @EnvironmentObject var p2p: P2PEngine
    let placeholder: String
    let scope: String
    let onSendText: (String) -> Void
    let onAttach: (P2PEngine.P2PAttachment) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { pickAndAttach() } label: {
                Image(systemName: "paperclip").font(.title3)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .help("Joindre un fichier")
            AudioRecordingButton { url in
                if let att = p2p.importChatFile(url, scope: scope) { onAttach(att) }
                try? FileManager.default.removeItem(at: url)
            }
            ChatComposer(draft: $draft, placeholder: placeholder, onSend: onSendText)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func pickAndAttach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let att = p2p.importChatFile(url, scope: scope) { onAttach(att) }
    }
}

/// Conversation P2P (Phase 2) : chat texte chiffré sur le tunnel Hyperswarm,
/// façon Slack (aligné à gauche, avatar+nom, séparateurs par jour).
struct P2PChatView: View {
    @EnvironmentObject var p2p: P2PEngine
    let contactKey: String
    var onOpenThread: (P2PEngine.P2PMessage) -> Void

    var messages: [P2PEngine.P2PMessage] {
        (p2p.chats[contactKey] ?? []).filter { $0.channel == nil }.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderBar(title: p2p.name(for: contactKey),
                                  online: p2p.isOnline(contactKey),
                                  contactKey: contactKey,
                                  subtitle: p2p.isOnline(contactKey) ? "en ligne · chiffré P2P" : "hors ligne")
            Divider()
            P2PTranscript(messages: messages, contactKey: contactKey,
                          targets: [contactKey], onOpenThread: onOpenThread)
            Divider()
            P2PComposerBar(placeholder: "Message P2P à \(p2p.name(for: contactKey))…",
                           scope: p2p.name(for: contactKey),
                           onSendText: { p2p.send($0, to: contactKey) },
                           onAttach: { p2p.send("", attachment: $0, to: contactKey) })
            if !p2p.isOnline(contactKey) {
                Text("Hors ligne — le message partira dès que \(p2p.name(for: contactKey)) sera connecté.")
                    .font(Theme.small).foregroundStyle(Theme.away).padding(.bottom, 6)
            }
        }
        .background(Theme.bgApp)
        .fileDropZone(scope: p2p.name(for: contactKey)) { p2p.send("", attachment: $0, to: contactKey) }
        .onAppear { p2p.markRead(contactKey) }
        .onChange(of: messages.count) { _ in p2p.markRead(contactKey) }
    }
}

/// En-tête de conversation/salon : avatar (ou icône) + titre + sous-titre présence.
struct ConversationHeaderBar: View {
    var title: String
    var online: Bool
    var contactKey: String? = nil
    var avatarID: UUID?
    var icon: String?
    var subtitle: String
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            if let contactKey {
                P2PAvatar(contactKey: contactKey, size: 38)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(online: online).offset(x: 1, y: 1) }
            } else if let avatarID {
                AvatarView(name: title, id: avatarID, size: 38)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(online: online).offset(x: 1, y: 1) }
            } else if let icon {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.surfaceAlt))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.h2).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Theme.small)
                    .foregroundStyle(online ? Theme.success : Theme.textSecondary)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
        .background(Theme.surface)
    }
}

/// Liste de messages P2P (jours + groupage), réutilisée par chat direct et salon.
struct P2PTranscript: View {
    @EnvironmentObject var p2p: P2PEngine
    let messages: [P2PEngine.P2PMessage]   // tous les messages (racines + réponses)
    var contactKey: String? = nil          // nil = salon (afficher les noms)
    var targets: [String] = []             // pairs à notifier (réactions)
    var onOpenThread: (P2PEngine.P2PMessage) -> Void = { _ in }

    private var topLevel: [P2PEngine.P2PMessage] { messages.filter { $0.replyTo == nil } }
    private var replyInfo: [UUID: (count: Int, last: Date)] {
        var d: [UUID: (Int, Date)] = [:]
        for m in messages where m.replyTo != nil {
            let k = m.replyTo!
            if let e = d[k] { d[k] = (e.0 + 1, max(e.1, m.date)) } else { d[k] = (1, m.date) }
        }
        return d
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(p2pDays(topLevel), id: \.date) { day in
                        DayDivider(date: day.date)
                        let items = groupByBundle(day.messages)
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let prevItem: BundledItem? = idx > 0 ? items[idx - 1] : nil
                            let prev = prevItem?.messages.last
                            let first = item.messages.first!
                            let grouped = prev != nil && prev!.fromMe == first.fromMe
                                && prev!.fromName == first.fromName
                                && first.date.timeIntervalSince(prev!.date) < 300
                            let info = replyInfo[first.id]
                            if item.messages.count > 1 {
                                P2PBundleRow(messages: item.messages, contactKey: contactKey,
                                             showHeader: !grouped, targets: targets,
                                             replyCount: info?.count ?? 0,
                                             lastReply: info?.last,
                                             onOpenThread: { onOpenThread(first) })
                                    .id(item.id)
                            } else {
                                P2PRow(message: first, contactKey: contactKey, showHeader: !grouped,
                                       targets: targets, replyCount: info?.count ?? 0,
                                       lastReply: info?.last, onOpenThread: { onOpenThread(first) })
                                    .id(first.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(topLevel.last?.id, anchor: .bottom) }
            .onChange(of: topLevel.count) { _ in
                withAnimation { proxy.scrollTo(topLevel.last?.id, anchor: .bottom) }
            }
        }
    }
}

/// Élément du flux de messages : soit un message unique, soit un lot (plusieurs
/// messages consécutifs partageant le même `bundleId`).
struct BundledItem: Identifiable {
    let id: UUID
    let messages: [P2PEngine.P2PMessage]
}

/// Regroupe les messages consécutifs partageant un bundleId et un expéditeur.
func groupByBundle(_ msgs: [P2PEngine.P2PMessage]) -> [BundledItem] {
    var result: [BundledItem] = []
    var current: [P2PEngine.P2PMessage] = []
    var currentBundle: UUID? = nil
    var currentSender: String? = nil

    func flush() {
        guard !current.isEmpty else { return }
        result.append(BundledItem(id: current[0].id, messages: current))
        current = []
    }

    for m in msgs {
        if let bd = m.bundleId, bd == currentBundle, m.fromName == currentSender {
            current.append(m)
        } else {
            flush()
            currentBundle = m.bundleId
            currentSender = m.fromName
            current = [m]
            if m.bundleId == nil { flush() }
        }
    }
    flush()
    return result
}

/// Bulle « lot de fichiers » façon Slack : grille de vignettes + bouton
/// « Tout télécharger ». Réactions et fil opèrent sur le 1er message du lot.
struct P2PBundleRow: View {
    @EnvironmentObject var p2p: P2PEngine
    let messages: [P2PEngine.P2PMessage]
    var contactKey: String? = nil
    let showHeader: Bool
    var targets: [String] = []
    var replyCount: Int = 0
    var lastReply: Date? = nil
    var onOpenThread: () -> Void = {}

    private var first: P2PEngine.P2PMessage { messages[0] }
    private var senderKey: String { first.fromKey ?? contactKey ?? "" }
    private var displayName: String { first.fromMe ? (p2p.myName.isEmpty ? "Moi" : p2p.myName) : first.fromName }
    private var avatarID: UUID {
        P2PEngine.uuid(forKey: first.fromMe ? p2p.myPublicKey : senderKey)
    }
    private var attachments: [P2PEngine.P2PAttachment] {
        messages.compactMap { $0.attachment }
    }
    private var totalSize: Int64 {
        attachments.reduce(0) { $0 + $1.size }
    }
    private var pendingCount: Int {
        attachments.filter { att in p2p.fileDownloads.contains { $0.relPath == att.relPath && ($0.status == .waiting || $0.status == .transferring) } }.count
    }
    private var allDownloaded: Bool {
        attachments.allSatisfy { att in
            messages.first(where: { $0.attachment?.relPath == att.relPath })
                .map { p2p.attachmentDownloaded($0) } ?? false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showHeader {
                AvatarView(name: displayName, id: avatarID, size: 32).padding(.top, 1)
            } else {
                Color.clear.frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 4) {
                if showHeader {
                    HStack(spacing: 6) {
                        Text(displayName).font(.subheadline.weight(.semibold))
                            .foregroundStyle(AvatarView(name: displayName, id: avatarID).color)
                        Text(first.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !first.text.isEmpty {
                    Text(first.text).font(.system(size: 15)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // En-tête du lot.
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill").font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text("\(attachments.count) fichier\(attachments.count > 1 ? "s" : "") · \(formatBytes(totalSize))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !first.fromMe && !allDownloaded {
                        Button {
                            for m in messages { p2p.downloadAttachment(m) }
                        } label: {
                            Label(pendingCount > 0 ? "Téléchargement…" : "Tout télécharger",
                                  systemImage: pendingCount > 0 ? "arrow.down.circle" : "arrow.down.circle.fill")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(pendingCount > 0)
                    } else if allDownloaded {
                        Label("Téléchargés", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                // Grille de vignettes.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 8)], spacing: 8) {
                    ForEach(messages, id: \.id) { m in
                        BundleAttachmentTile(message: m)
                    }
                }
                .frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, showHeader ? 6 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Vignette dans la grille du lot : aperçu si DL, sinon icône typée + DL solo.
struct BundleAttachmentTile: View {
    @EnvironmentObject var p2p: P2PEngine
    let message: P2PEngine.P2PMessage
    private var att: P2PEngine.P2PAttachment { message.attachment! }
    private var url: URL? { p2p.attachmentURL(message) }
    private var downloaded: Bool { p2p.attachmentDownloaded(message) }
    private var ext: String { (att.fileName as NSString).pathExtension.lowercased() }
    private var icon: String {
        if att.isImage { return "photo" }
        if att.isVideo { return "play.rectangle.fill" }
        if att.isRive { return "sparkles" }
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "txt","md","json","csv","log": return "doc.text.fill"
        case "zip","rar","7z": return "doc.zipper"
        default: return "doc.fill"
        }
    }
    private var iconColor: Color {
        if att.isImage { return .blue }
        if att.isVideo { return .pink }
        if att.isRive { return .purple }
        switch ext {
        case "pdf": return .red
        case "zip","rar","7z": return .orange
        default: return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12))
                if downloaded, let url, att.isImage, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else if downloaded, let url, FileManager.default.fileExists(atPath: url.path) {
                    FileThumbnail(url: url, fallbackIcon: icon, fallbackColor: iconColor, iconSize: 28)
                } else {
                    Image(systemName: icon).font(.system(size: 28)).foregroundStyle(iconColor)
                }
            }
            .frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                if downloaded, let url { NSWorkspace.shared.open(url) }
                else if !message.fromMe { p2p.downloadAttachment(message) }
            }
            Text(att.fileName).font(.caption.weight(.medium)).lineLimit(1)
            Text(formatBytes(att.size)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Onglet Fichiers d'un contact P2P : liste des fichiers partagés + téléchargement.
enum FileStatus { case mine, downloaded, waiting, transferring, remote }

/// Fichiers d'un contact (téléchargeables à la demande, liste persistée hors-ligne).
struct P2PFilesView: View {
    @EnvironmentObject var p2p: P2PEngine
    @EnvironmentObject var store: AppStore
    let contactKey: String

    var files: [RemoteFile] { p2p.remoteFiles[contactKey] ?? [] }

    func status(_ f: RemoteFile) -> FileStatus {
        if p2p.isDownloaded(f.path, from: contactKey) { return .downloaded }
        if let d = p2p.fileDownloads.first(where: { $0.contactKey == contactKey && $0.relPath == f.path }) {
            switch d.status { case .transferring: return .transferring
            case .waiting: return .waiting; default: break }
        }
        return .remote
    }
    func localURL(_ f: RemoteFile) -> URL? {
        store.mirrorRootURL.appendingPathComponent(p2p.name(for: contactKey)).appendingPathComponent(f.path)
    }

    var body: some View {
        FilesBrowser(
            title: "Fichiers de \(p2p.name(for: contactKey))",
            subtitle: p2p.isOnline(contactKey) ? "en ligne" : "hors ligne — liste enregistrée",
            online: p2p.isOnline(contactKey),
            files: files, ownerName: p2p.name(for: contactKey), ownerID: P2PEngine.uuid(forKey: contactKey),
            statusFor: status, localURLFor: localURL,
            onPrimary: { f in
                if p2p.isDownloaded(f.path, from: contactKey) {
                    if let u = localURL(f) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                } else { p2p.downloadFile(f, from: contactKey) }
            },
            headerTrailing: files.isEmpty ? nil : AnyView(
                Button("Tout télécharger") { for f in files { p2p.downloadFile(f, from: contactKey) } }.font(Theme.small)
            ))
        .onAppear { p2p.configure(sharedFolder: store.config.sharedFolder, downloadBase: store.mirrorRootURL.path) }
    }
}

/// Mes fichiers partagés (contenu de mon dossier partagé).
struct MyFilesView: View {
    @EnvironmentObject var p2p: P2PEngine
    @EnvironmentObject var store: AppStore

    var files: [RemoteFile] { p2p.myFiles() }
    func localURL(_ f: RemoteFile) -> URL? {
        store.config.sharedFolder.map { URL(fileURLWithPath: $0).appendingPathComponent(f.path) }
    }

    var body: some View {
        Group {
            if store.config.sharedFolder == nil {
                ContentPlaceholder(icon: "folder.badge.plus",
                                   text: "Choisis ton dossier partagé dans Réglages pour partager des fichiers.")
            } else {
                FilesBrowser(
                    title: "Mes fichiers partagés", subtitle: "visibles par tous tes contacts",
                    online: true, files: files,
                    ownerName: p2p.myName.isEmpty ? "Moi" : p2p.myName,
                    ownerID: P2PEngine.uuid(forKey: p2p.myPublicKey),
                    statusFor: { _ in .mine }, localURLFor: localURL,
                    onPrimary: { f in if let u = localURL(f) { NSWorkspace.shared.activateFileViewerSelecting([u]) } },
                    onShare: { f, contactKey in
                        let att = P2PEngine.P2PAttachment(fileName: f.name, relPath: f.path, size: f.size)
                        p2p.send("", attachment: att, to: contactKey)
                        p2p.recordShare(path: f.path, with: contactKey)
                    },
                    onShareBundle: { files, contactKey in
                        let atts = files.map { P2PEngine.P2PAttachment(fileName: $0.name, relPath: $0.path, size: $0.size) }
                        p2p.sendBundle(atts, to: contactKey)
                        for f in files { p2p.recordShare(path: f.path, with: contactKey) }
                    },
                    shareContacts: p2p.contacts.map { (key: $0, name: p2p.name(for: $0)) },
                    sharedWith: { p2p.sharedWith(path: $0) },
                    onRevokeShare: { path, key in p2p.revokeShare(path: path, with: key) },
                    headerTrailing: store.config.sharedFolder.map { p in AnyView(
                        Button("Ouvrir le dossier") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }.font(Theme.small)
                    )})
            }
        }
        .onAppear { p2p.configure(sharedFolder: store.config.sharedFolder, downloadBase: store.mirrorRootURL.path) }
    }
}

/// Vue racine « Dossiers partagés » : chaque contact apparaît comme un dossier
/// (avatar/point coloré + nom + nombre de fichiers). Clic → entre dans son dossier.
struct AllSharedFoldersView: View {
    @EnvironmentObject var p2p: P2PEngine
    var onPick: (String) -> Void
    @State private var grid = true
    @State private var search = ""

    private var contacts: [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = p2p.contacts.sorted { p2p.name(for: $0).localizedCaseInsensitiveCompare(p2p.name(for: $1)) == .orderedAscending }
        return q.isEmpty ? all : all.filter { p2p.name(for: $0).lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dossiers partagés").font(Theme.h2).foregroundStyle(Theme.textPrimary)
                    Text("Un dossier par contact — clic pour ouvrir").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Text("\(contacts.count)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.surfaceAlt))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Theme.textSecondary)
                    TextField("Rechercher", text: $search).textFieldStyle(.plain).frame(width: 130)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
                Picker("", selection: $grid) {
                    Image(systemName: "square.grid.2x2").tag(true)
                    Image(systemName: "list.bullet").tag(false)
                }.pickerStyle(.segmented).frame(width: 76)
            }
            .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
            .background(Theme.surface)
            Divider()

            if contacts.isEmpty {
                ContentPlaceholder(icon: "person.2",
                    text: search.isEmpty ? "Aucun contact pour le moment." : "Aucun contact pour « \(search) ».")
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 14)], spacing: 14) {
                        ForEach(contacts, id: \.self) { key in
                            ContactFolderCard(contactKey: key, grid: true, onOpen: { onPick(key) })
                        }
                    }.padding(Theme.Space.lg)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(contacts, id: \.self) { key in
                            ContactFolderCard(contactKey: key, grid: false, onOpen: { onPick(key) })
                            Divider().padding(.leading, 44)
                        }
                    }.padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.xs)
                }
            }
        }
        .background(Theme.bgApp)
    }
}

/// Cellule « dossier d'un contact » : avatar + nom + point en-ligne + compteur.
struct ContactFolderCard: View {
    @EnvironmentObject var p2p: P2PEngine
    let contactKey: String
    let grid: Bool
    var onOpen: () -> Void

    private var name: String { p2p.name(for: contactKey) }
    private var count: Int { p2p.remoteFiles[contactKey]?.count ?? 0 }
    private var online: Bool { p2p.isOnline(contactKey) }

    var body: some View {
        if grid {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceAlt)
                    Image(systemName: "folder.fill").font(.system(size: 36)).foregroundStyle(Theme.accent.opacity(0.85))
                    VStack { Spacer(); HStack { Spacer()
                        P2PAvatar(contactKey: contactKey, size: 28)
                            .overlay(alignment: .bottomTrailing) { PresenceDot(online: online, size: 9).offset(x: 1, y: 1) }
                            .padding(8)
                    } }
                }
                .frame(height: 104)
                HStack(spacing: 5) {
                    PresenceDot(online: online, size: 8)
                    Text(name).font(Theme.body.weight(.medium)).lineLimit(1).foregroundStyle(Theme.textPrimary)
                }
                Text(count == 0 ? "Aucun fichier" : "\(count) fichier\(count > 1 ? "s" : "")")
                    .font(Theme.tiny).foregroundStyle(Theme.textSecondary)
            }
            .padding(8).card(radius: Theme.Radius.lg)
            .contentShape(Rectangle()).onTapGesture(perform: onOpen)
            .help("Ouvrir le dossier de \(name)")
        } else {
            HStack(spacing: Theme.Space.md) {
                P2PAvatar(contactKey: contactKey, size: 30)
                    .overlay(alignment: .bottomTrailing) { PresenceDot(online: online, size: 9).offset(x: 1, y: 1) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(online ? "en ligne" : "hors ligne").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(count == 0 ? "—" : "\(count)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, alignment: .trailing)
                Image(systemName: "chevron.right").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 6)
            .contentShape(Rectangle()).onTapGesture(perform: onOpen)
        }
    }
}

/// Navigateur de fichiers réutilisable : barre (titre, compteur, recherche,
/// bascule liste/grille) + grille de cartes OU liste, avec vignettes et métadonnées.
enum FilesSortMode: String, CaseIterable, Identifiable {
    case nameAsc = "Nom A→Z"
    case nameDesc = "Nom Z→A"
    case dateDesc = "Plus récent"
    case dateAsc = "Plus ancien"
    case sizeDesc = "Plus gros"
    case sizeAsc = "Plus petit"
    var id: String { rawValue }
}

struct FilesBrowser: View {
    let title: String
    var subtitle: String = ""
    var online: Bool = true
    let files: [RemoteFile]
    let ownerName: String
    let ownerID: UUID
    var statusFor: (RemoteFile) -> FileStatus
    var localURLFor: (RemoteFile) -> URL?
    var onPrimary: (RemoteFile) -> Void
    var onShare: ((RemoteFile, String) -> Void)? = nil
    var onShareBundle: (([RemoteFile], String) -> Void)? = nil
    var shareContacts: [(key: String, name: String)] = []
    /// Resolveur : chemin → liste de clés de contacts avec qui c'est partagé.
    var sharedWith: ((String) -> [String])? = nil
    /// Révoque le partage d'un fichier avec un contact donné.
    var onRevokeShare: ((String, String) -> Void)? = nil
    var headerTrailing: AnyView? = nil
    @State private var grid = true
    @State private var search = ""
    @State private var currentFolder = ""
    @State private var sortMode: FilesSortMode = .dateDesc
    @State private var selected: RemoteFile?
    @State private var selectedFolder: FileNode?

    var filtered: [RemoteFile] {
        var f = files
        switch sortMode {
        case .nameAsc:  f.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: f.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .dateDesc: f.sort { $0.mtime > $1.mtime }
        case .dateAsc:  f.sort { $0.mtime < $1.mtime }
        case .sizeDesc: f.sort { $0.size > $1.size }
        case .sizeAsc:  f.sort { $0.size < $1.size }
        }
        return search.isEmpty ? f : f.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
    }
    var currentNodes: [FileNode] {
        let entries = filtered.compactMap { file -> (components: [String], file: RemoteFile)? in
            guard search.isEmpty else { return (file.path.split(separator: "/").map(String.init), file) }
            guard currentFolder.isEmpty || file.path.hasPrefix(currentFolder) else { return nil }
            let relative = currentFolder.isEmpty ? file.path : String(file.path.dropFirst(currentFolder.count))
            let components = relative.split(separator: "/").map(String.init)
            return components.isEmpty ? nil : (components, file)
        }
        return FileNode.build(entries: entries, prefix: currentFolder)
    }
    var folderTrail: [(name: String, path: String)] {
        guard !currentFolder.isEmpty else { return [] }
        var path = ""
        return currentFolder.split(separator: "/").map(String.init).map { part in
            path += part + "/"
            return (part, path)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.md) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(Theme.h2).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            if !subtitle.isEmpty {
                                Text(subtitle).font(Theme.small)
                                    .foregroundStyle(online ? Theme.textSecondary : Theme.away)
                            }
                        }
                        Text("\(filtered.count)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.surfaceAlt))
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Theme.textSecondary)
                            TextField("Rechercher", text: $search).textFieldStyle(.plain).frame(width: 130)
                                .onChange(of: search) { _ in currentFolder = "" }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
                        Picker("", selection: $grid) {
                            Image(systemName: "square.grid.2x2").tag(true)
                            Image(systemName: "list.bullet").tag(false)
                        }.pickerStyle(.segmented).frame(width: 76)
                        if let headerTrailing { headerTrailing }
                    }
                    HStack(spacing: Theme.Space.sm) {
                        Menu {
                            ForEach(FilesSortMode.allCases) { mode in
                                Button {
                                    sortMode = mode
                                } label: {
                                    if sortMode == mode { Label(mode.rawValue, systemImage: "checkmark") }
                                    else { Text(mode.rawValue) }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "line.3.horizontal.decrease").font(.caption)
                                Text("Trier : \(sortMode.rawValue)").font(Theme.small)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
                            .foregroundStyle(Theme.textPrimary)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        if search.isEmpty {
                            FolderBreadcrumb(title: title, trail: folderTrail) { currentFolder = $0 }
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
                .background(Theme.surface)
                Divider()

                if filtered.isEmpty {
                    ContentPlaceholder(icon: online ? "tray" : "wifi.slash",
                        text: search.isEmpty ? (online ? "Aucun fichier." : "Hors ligne — la liste apparaîtra à la connexion.")
                                              : "Aucun résultat pour « \(search) ».")
                } else if grid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 14)], spacing: 14) {
                            ForEach(currentNodes) { node in
                                if let f = node.file {
                                    fileCell(f, grid: true)
                                } else {
                                    folderCell(node, grid: true)
                                }
                            }
                        }.padding(Theme.Space.lg)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(currentNodes) { node in
                                if let f = node.file {
                                    fileCell(f, grid: false)
                                } else {
                                    folderCell(node, grid: false)
                                }
                                Divider().padding(.leading, 44)
                            }
                        }.padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.xs)
                    }
                }
            }
            .background(Theme.bgApp)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let f = selected {
                Divider()
                FileInfoPanel(file: f, ownerName: ownerName, ownerID: ownerID,
                              thumbURL: localURLFor(f), status: statusFor(f),
                              shareContacts: shareContacts,
                              sharedWithKeys: sharedWith?(f.path) ?? [],
                              onOpen: { onPrimary(f) },
                              onShare: onShare.map { share in { contactKey in share(f, contactKey) } },
                              onRevokeShare: onRevokeShare.map { revoke in { k in revoke(f.path, k) } },
                              onClose: { selected = nil })
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let node = selectedFolder {
                Divider()
                let folderShares: [String] = {
                    guard let resolver = sharedWith, !node.allFiles.isEmpty else { return [] }
                    let sets = node.allFiles.map { Set(resolver($0.path)) }
                    return Array(sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }).sorted()
                }()
                FolderInfoPanel(node: node,
                                shareContacts: shareContacts,
                                sharedWithKeys: folderShares,
                                onOpen: { currentFolder = node.id; selectedFolder = nil; selected = nil },
                                onShareAll: onShare.map { share in { key in for f in node.allFiles { share(f, key) } } },
                                onRevokeAll: onRevokeShare.map { revoke in { k in for f in node.allFiles { revoke(f.path, k) } } },
                                onClose: { selectedFolder = nil })
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func fileCell(_ f: RemoteFile, grid: Bool) -> some View {
        let isSelected = selected?.path == f.path
        let shares = sharedWith?(f.path) ?? []
        FileItem(file: f, ownerName: ownerName, ownerID: ownerID, grid: grid,
                 thumbURL: localURLFor(f), status: statusFor(f),
                 selected: isSelected,
                 sharedWithKeys: shares,
                 onOpen: { onPrimary(f) },
                 onSelect: { withAnimation(.easeInOut(duration: 0.15)) { selected = f; selectedFolder = nil } })
            .contextMenu { fileContextMenu(path: f.path, shares: shares, share: onShare.map { s in { k in s(f, k) } }, open: { onPrimary(f) }, info: { withAnimation { selected = f } }) }
    }

    @ViewBuilder
    private func folderCell(_ node: FileNode, grid: Bool) -> some View {
        // Un dossier est "partagé avec X" si tous ses fichiers le sont.
        let folderShares: [String] = {
            guard let resolver = sharedWith, !node.allFiles.isEmpty else { return [] }
            let sets = node.allFiles.map { Set(resolver($0.path)) }
            return Array(sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) })
                .sorted()
        }()
        FolderItem(node: node, grid: grid,
                   sharedWithKeys: folderShares,
                   selected: selectedFolder?.id == node.id,
                   onOpen: { currentFolder = node.id; selected = nil; selectedFolder = nil },
                   onSelect: { withAnimation(.easeInOut(duration: 0.15)) { selectedFolder = node; selected = nil } })
            .contextMenu {
                Button("Ouvrir") { currentFolder = node.id; selected = nil }
                if !shareContacts.isEmpty {
                    Menu("Partager le dossier avec…") {
                        ForEach(shareContacts, id: \.key) { c in
                            Button(c.name) {
                                if let bundle = onShareBundle {
                                    bundle(node.allFiles, c.key)
                                } else if let share = onShare {
                                    for f in node.allFiles { share(f, c.key) }
                                }
                            }
                        }
                    }
                }
                if !folderShares.isEmpty, let revoke = onRevokeShare {
                    Menu("Retirer le partage…") {
                        ForEach(folderShares, id: \.self) { k in
                            Button(p2pName(k)) {
                                for f in node.allFiles { revoke(f.path, k) }
                            }
                        }
                    }
                }
            }
    }

    /// Source de nom indirecte (FilesBrowser n'a pas d'accès direct à p2p, donc
    /// on s'appuie sur shareContacts pour résoudre key→nom).
    private func p2pName(_ key: String) -> String {
        shareContacts.first(where: { $0.key == key })?.name ?? String(key.prefix(8))
    }

    @ViewBuilder
    private func fileContextMenu(path: String, shares: [String],
                                 share: ((String) -> Void)?,
                                 open: @escaping () -> Void,
                                 info: @escaping () -> Void) -> some View {
        Button("Ouvrir", action: open)
        Button("Infos", action: info)
        if !shareContacts.isEmpty, let share {
            Menu("Partager avec…") {
                ForEach(shareContacts, id: \.key) { c in
                    let already = shares.contains(c.key)
                    Button {
                        share(c.key)
                    } label: {
                        if already { Label(c.name, systemImage: "checkmark") }
                        else { Text(c.name) }
                    }
                }
            }
        }
        if !shares.isEmpty, let revoke = onRevokeShare {
            Menu("Retirer le partage…") {
                ForEach(shares, id: \.self) { k in
                    Button(p2pName(k)) { revoke(path, k) }
                }
            }
        }
    }
}

struct FolderBreadcrumb: View {
    let title: String
    let trail: [(name: String, path: String)]
    var onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button { onSelect("") } label: {
                Label("Racine", systemImage: "house.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(trail.isEmpty ? Theme.textPrimary : Theme.accent)
            ForEach(trail, id: \.path) { item in
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Button(item.name) { onSelect(item.path) }
                    .buttonStyle(.plain)
                    .foregroundStyle(item.path == trail.last?.path ? Theme.textPrimary : Theme.accent)
            }
            Spacer()
        }
        .font(Theme.small)
    }
}

struct FolderItem: View {
    let node: FileNode
    let grid: Bool
    var sharedWithKeys: [String] = []
    var selected: Bool = false
    var onOpen: () -> Void
    var onSelect: () -> Void = {}

    var body: some View {
        if grid {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceAlt)
                    Image(systemName: "folder.fill").font(.system(size: 36)).foregroundStyle(Theme.away)
                }
                .frame(height: 104)
                .overlay(alignment: .bottomLeading) {
                    if !sharedWithKeys.isEmpty {
                        SharedWithStack(keys: sharedWithKeys, size: 18).padding(6)
                    }
                }
                Text(node.name).font(Theme.body.weight(.medium)).lineLimit(1).foregroundStyle(Theme.textPrimary)
                Text("\(node.allFiles.count) élément\(node.allFiles.count > 1 ? "s" : "")")
                    .font(Theme.tiny).foregroundStyle(Theme.textSecondary)
            }
            .padding(8).card(radius: Theme.Radius.lg)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onSelect() }
            .help("Double-clic pour ouvrir le dossier")
        } else {
            HStack(spacing: Theme.Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceAlt)
                    Image(systemName: "folder.fill").foregroundStyle(Theme.away)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("\(node.allFiles.count) élément\(node.allFiles.count > 1 ? "s" : "")")
                        .font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if !sharedWithKeys.isEmpty {
                    SharedWithStack(keys: sharedWithKeys, size: 16)
                }
                Image(systemName: "chevron.right").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 6)
            .background(selected ? Theme.selected : .clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onSelect() }
        }
    }
}

/// Pile d'avatars compacts (max 3 + "+N") pour montrer avec qui un fichier ou
/// dossier est partagé. Tooltip détaille la liste complète.
struct SharedWithStack: View {
    @EnvironmentObject var p2p: P2PEngine
    let keys: [String]
    var size: CGFloat = 18

    var body: some View {
        let shown = Array(keys.prefix(3))
        let extra = keys.count - shown.count
        HStack(spacing: -size * 0.35) {
            ForEach(shown, id: \.self) { k in
                P2PAvatar(contactKey: k, size: size)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 1.5))
            }
            if extra > 0 {
                ZStack {
                    Circle().fill(Theme.surfaceAlt)
                    Text("+\(extra)").font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Theme.surface, lineWidth: 1.5))
            }
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .background(Capsule().fill(Theme.surface.opacity(0.85)))
        .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5))
        .help("Partagé avec : " + keys.map { p2p.name(for: $0) }.joined(separator: ", "))
    }
}

/// Élément fichier (carte en grille ou ligne en liste) : vignette/icône, nom,
/// taille, date de modif, avatar du propriétaire, état (téléchargé/à télécharger).
struct FileItem: View {
    let file: RemoteFile
    let ownerName: String
    let ownerID: UUID
    let grid: Bool
    let thumbURL: URL?
    let status: FileStatus
    var selected: Bool = false
    var sharedWithKeys: [String] = []
    var onOpen: () -> Void
    var onSelect: () -> Void = {}

    var ext: String { (file.path as NSString).pathExtension.lowercased() }
    var isImage: Bool { ["png","jpg","jpeg","gif","heic","webp","tiff"].contains(ext) }
    var local: Bool { status == .mine || status == .downloaded }
    var iconName: String {
        if isImage { return "photo" }
        switch ext {
        case "mp4","mov","m4v": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "txt","md","rtf","json","csv","log": return "doc.text.fill"
        case "zip","rar","7z": return "doc.zipper"
        case "riv": return "sparkles"
        default: return "doc.fill"
        }
    }
    var iconColor: Color {
        switch ext { case "mp4","mov","m4v": return .pink; case "pdf": return .red; case "riv": return .purple
        case "txt","md","rtf","json","csv","log": return .teal
        case "zip","rar","7z": return .orange; default: return Theme.accent }
    }

    @ViewBuilder var statusBadge: some View {
        switch status {
        case .downloaded, .mine: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .transferring: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "clock.fill").foregroundStyle(Theme.away)
        case .remote: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder var preview: some View {
        if local, let thumbURL {
            FileThumbnail(url: thumbURL, fallbackIcon: iconName, fallbackColor: iconColor,
                          iconSize: grid ? 32 : 18)
        } else {
            Image(systemName: iconName).font(.system(size: grid ? 32 : 18)).foregroundStyle(iconColor)
        }
    }

    var body: some View {
        if grid {
            VStack(alignment: .leading, spacing: 6) {
                ZStack { RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceAlt); preview }
                    .frame(height: 104).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        statusBadge.padding(6).background(Circle().fill(Theme.surface).opacity(0.9)).padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !sharedWithKeys.isEmpty {
                            SharedWithStack(keys: sharedWithKeys, size: 18).padding(6)
                        }
                    }
                Text(file.name).font(Theme.body.weight(.medium)).lineLimit(1).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    AvatarView(name: ownerName, id: ownerID, size: 16)
                    Text(file.mtime.formatted(date: .abbreviated, time: .omitted)).font(Theme.tiny)
                    Spacer()
                    Text(formatBytes(file.size)).font(Theme.tiny)
                }.foregroundStyle(Theme.textSecondary)
            }
            .padding(8).card(radius: Theme.Radius.lg)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onSelect() }
            .help(local ? "Double-clic pour ouvrir dans le Finder" : "Double-clic pour télécharger")
        } else {
            HStack(spacing: Theme.Space.md) {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceAlt); preview }
                    .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(file.path).font(Theme.tiny).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if !sharedWithKeys.isEmpty {
                    SharedWithStack(keys: sharedWithKeys, size: 16)
                }
                AvatarView(name: ownerName, id: ownerID, size: 18)
                Text(file.mtime.formatted(date: .numeric, time: .omitted)).font(Theme.small)
                    .foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .trailing)
                Text(formatBytes(file.size)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .frame(width: 64, alignment: .trailing)
                Button(action: onOpen) { statusBadge }.buttonStyle(.plain).frame(width: 24)
            }
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 6)
            .background(selected ? Theme.selected : .clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onSelect() }
        }
    }
}

/// Panneau latéral droit qui montre les méta-données d'un fichier sélectionné.
/// Visible quand l'utilisateur a cliqué (clic simple) sur un fichier de la
/// grille/liste. Double-clic ouvre directement le fichier (cf. FileItem).
struct FileInfoPanel: View {
    @EnvironmentObject var p2p: P2PEngine
    let file: RemoteFile
    let ownerName: String
    let ownerID: UUID
    let thumbURL: URL?
    let status: FileStatus
    var shareContacts: [(key: String, name: String)] = []
    var sharedWithKeys: [String] = []
    var onOpen: () -> Void
    var onShare: ((String) -> Void)?
    var onRevokeShare: ((String) -> Void)?
    var onClose: () -> Void

    @State private var tag: String = ""

    var ext: String { (file.path as NSString).pathExtension.lowercased() }
    var fallbackIcon: String {
        switch ext {
        case "png","jpg","jpeg","gif","heic","webp","tiff": return "photo"
        case "mp4","mov","m4v": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "txt","md","rtf","json","csv","log": return "doc.text.fill"
        case "zip","rar","7z": return "doc.zipper"
        case "riv": return "sparkles"
        default: return "doc.fill"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text("Infos fichier").font(Theme.body.weight(.semibold))
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .help("Fermer le panneau")
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceAlt)
                    if let thumbURL, status == .downloaded || status == .mine,
                       FileManager.default.fileExists(atPath: thumbURL.path) {
                        RichFilePreview(url: thumbURL, maxHeight: 220)
                    } else {
                        Image(systemName: fallbackIcon).font(.system(size: 48))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(minHeight: 160, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(file.name).font(Theme.body.weight(.semibold)).lineLimit(2)

                VStack(alignment: .leading, spacing: 6) {
                    row("Taille", formatBytes(file.size))
                    row("Modifié le", file.mtime.formatted(date: .abbreviated, time: .shortened))
                    row("Chemin", file.path)
                    row("Type", ext.isEmpty ? "—" : ext.uppercased())
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Propriétaire").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                    HStack {
                        AvatarView(name: ownerName, id: ownerID, size: 22)
                        Text(ownerName).font(Theme.body)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tag").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                    TextField("Ajoute un tag (libre)", text: $tag)
                        .textFieldStyle(.roundedBorder)
                }

                if !shareContacts.isEmpty, let share = onShare {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Partager avec").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                        // Liste des partages actuels avec bouton ×.
                        if !sharedWithKeys.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(sharedWithKeys, id: \.self) { k in
                                    HStack(spacing: 6) {
                                        P2PAvatar(contactKey: k, size: 18)
                                        Text(p2p.name(for: k)).font(Theme.small)
                                        Spacer()
                                        if let revoke = onRevokeShare {
                                            Button {
                                                revoke(k)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                            }
                                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                                            .help("Retirer du partage")
                                        }
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surfaceAlt))
                                }
                            }
                        }
                        // Ajouter un destinataire.
                        let remaining = shareContacts.filter { !sharedWithKeys.contains($0.key) }
                        if !remaining.isEmpty {
                            Menu {
                                ForEach(remaining, id: \.key) { c in
                                    Button(c.name) { share(c.key) }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text(sharedWithKeys.isEmpty ? "Choisir un contact…" : "Ajouter un destinataire…")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
                                .foregroundStyle(Theme.textPrimary)
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                }

                Spacer(minLength: 0)
                Button(action: onOpen) {
                    HStack { Spacer(); Label("Ouvrir", systemImage: "arrow.up.right.square"); Spacer() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.surface)
        .onChange(of: file.path) { _ in tag = "" }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Theme.tiny).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.small).foregroundStyle(Theme.textPrimary).lineLimit(2)
        }
    }
}

/// Panneau d'infos pour un dossier sélectionné (clic simple). Double-clic
/// ouvre le dossier via le bouton ou directement sur la carte.
struct FolderInfoPanel: View {
    @EnvironmentObject var p2p: P2PEngine
    let node: FileNode
    var shareContacts: [(key: String, name: String)] = []
    var sharedWithKeys: [String] = []
    var onOpen: () -> Void
    var onShareAll: ((String) -> Void)?
    var onRevokeAll: ((String) -> Void)?
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text("Infos dossier").font(Theme.body.weight(.semibold))
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .help("Fermer le panneau")
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceAlt)
                    Image(systemName: "folder.fill").font(.system(size: 64))
                        .foregroundStyle(Theme.away)
                }
                .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 12))

                Text(node.name).font(Theme.body.weight(.semibold)).lineLimit(2)

                VStack(alignment: .leading, spacing: 6) {
                    row("Éléments", "\(node.allFiles.count)")
                    row("Taille totale", formatBytes(node.allFiles.reduce(0) { $0 + $1.size }))
                    if let latest = node.allFiles.map(\.mtime).max() {
                        row("Dernière modif.", latest.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if !shareContacts.isEmpty, let share = onShareAll {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Partagé avec").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                        if !sharedWithKeys.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(sharedWithKeys, id: \.self) { k in
                                    HStack(spacing: 6) {
                                        P2PAvatar(contactKey: k, size: 18)
                                        Text(p2p.name(for: k)).font(Theme.small)
                                        Spacer()
                                        if let revoke = onRevokeAll {
                                            Button { revoke(k) } label: {
                                                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                            }
                                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                                            .help("Retirer du partage tous les fichiers du dossier")
                                        }
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surfaceAlt))
                                }
                            }
                        }
                        let remaining = shareContacts.filter { !sharedWithKeys.contains($0.key) }
                        if !remaining.isEmpty {
                            Menu {
                                ForEach(remaining, id: \.key) { c in
                                    Button(c.name) { share(c.key) }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text(sharedWithKeys.isEmpty ? "Choisir un contact…" : "Ajouter un destinataire…")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
                                .foregroundStyle(Theme.textPrimary)
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                }

                Spacer(minLength: 0)
                Button(action: onOpen) {
                    HStack { Spacer(); Label("Ouvrir le dossier", systemImage: "folder"); Spacer() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.surface)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Theme.tiny).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.small).foregroundStyle(Theme.textPrimary).lineLimit(2)
        }
    }
}

struct FileThumbnail: View {
    let url: URL
    let fallbackIcon: String
    let fallbackColor: Color
    let iconSize: CGFloat
    @State private var image: NSImage?

    private var isGIF: Bool { url.pathExtension.lowercased() == "gif" }

    var body: some View {
        ZStack {
            if isGIF {
                AnimatedGIFView(url: url)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: fallbackIcon).font(.system(size: iconSize)).foregroundStyle(fallbackColor)
            }
        }
        .task(id: url) { if !isGIF { await loadThumbnail() } }
    }

    private func loadThumbnail() async {
        if let direct = NSImage(contentsOf: url), isBitmap(url) {
            await MainActor.run { image = direct }
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 220, height: 150),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            await MainActor.run { image = representation.nsImage }
        } catch {
            await MainActor.run { image = nil }
        }
    }

    private func isBitmap(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(url.pathExtension.lowercased())
    }
}

/// Carte fichier (grille façon « file browser ») : vignette image ou icône de
/// type, nom, taille, et pastille d'état (téléchargé / en cours / à télécharger).
struct P2PFileCard: View {
    @EnvironmentObject var p2p: P2PEngine
    @EnvironmentObject var store: AppStore
    let file: RemoteFile
    let contactKey: String

    var ext: String { (file.path as NSString).pathExtension.lowercased() }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(ext) }
    var localURL: URL {
        store.mirrorRootURL.appendingPathComponent(p2p.name(for: contactKey)).appendingPathComponent(file.path)
    }
    var downloaded: Bool { p2p.isDownloaded(file.path, from: contactKey) }
    var pending: P2PEngine.P2PDownload? {
        p2p.fileDownloads.first {
            $0.contactKey == contactKey && $0.relPath == file.path
                && ($0.status == .waiting || $0.status == .transferring)
        }
    }
    var iconName: String {
        if isImage { return "photo" }
        switch ext {
        case "mp4", "mov", "m4v": return "play.rectangle.fill"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z": return "doc.zipper"
        case "riv": return "sparkles"
        default: return "doc.fill"
        }
    }
    var iconColor: Color {
        switch ext {
        case "mp4", "mov", "m4v": return .pink
        case "pdf": return .red
        case "riv": return .purple
        case "zip", "rar", "7z": return .orange
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10))
                if downloaded, isImage, let img = NSImage(contentsOf: localURL) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: iconName).font(.system(size: 34)).foregroundStyle(iconColor)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                Group {
                    if downloaded {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let pending {
                        if pending.status == .transferring { ProgressView().controlSize(.small) }
                        else { Image(systemName: "clock.fill").foregroundStyle(.orange) }
                    } else {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                .padding(6)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).opacity(0.9))
                .padding(6)
            }

            Text(file.name).font(.callout.weight(.medium)).lineLimit(1)
            Text(formatBytes(file.size)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if downloaded { NSWorkspace.shared.activateFileViewerSelecting([localURL]) }
            else if pending == nil { p2p.downloadFile(file, from: contactKey) }
        }
        .help(downloaded ? "Afficher dans le Finder" : "Télécharger")
    }
}

struct P2PRow: View {
    @EnvironmentObject var p2p: P2PEngine
    let message: P2PEngine.P2PMessage
    var contactKey: String? = nil
    let showHeader: Bool
    var targets: [String] = []
    var replyCount: Int = 0
    var lastReply: Date? = nil
    var onOpenThread: () -> Void = {}
    var inThread: Bool = false       // dans le panneau de fil : pas de bouton « N réponses »
    @State private var hovering = false
    @State private var controlsHovering = false
    @State private var showPicker = false

    static let quickEmojis = ["👍", "❤️", "😂", "🎉", "👀", "✅", "🙏", "🔥"]

    var senderKey: String { message.fromKey ?? contactKey ?? "" }
    var displayName: String { message.fromMe ? (p2p.myName.isEmpty ? "Moi" : p2p.myName) : message.fromName }
    var avatarID: UUID {
        P2PEngine.uuid(forKey: message.fromMe ? p2p.myPublicKey : senderKey)
    }
    var formatted: AttributedString {
        (try? AttributedString(markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }
    var reacts: [(emoji: String, count: Int)] {
        (p2p.reactions[message.id] ?? [:]).map { ($0.key, $0.value.count) }.sorted { $0.emoji < $1.emoji }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showHeader {
                AvatarView(name: displayName, id: avatarID, size: 32).padding(.top, 1)
            } else {
                Color.clear.frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showHeader {
                    HStack(spacing: 6) {
                        Text(displayName).font(.subheadline.weight(.semibold))
                            .foregroundStyle(AvatarView(name: displayName, id: avatarID).color)
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        if message.fromMe {
                            Image(systemName: message.delivered ? "checkmark.circle.fill" : "clock")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if message.attachment != nil {
                    P2PAttachmentView(message: message, contactContext: contactKey)
                }
                if !message.text.isEmpty {
                    Text(formatted).textSelection(.enabled)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !reacts.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(reacts, id: \.emoji) { r in
                            let mine = p2p.iReacted(r.emoji, to: message.id)
                            Button { p2p.toggleReaction(r.emoji, on: message, targets: targets) } label: {
                                HStack(spacing: 3) { Text(r.emoji); Text("\(r.count)").font(Theme.tiny) }
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(mine ? Theme.accent.opacity(0.18) : Theme.surfaceAlt))
                                    .overlay(Capsule().stroke(mine ? Theme.accent : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if replyCount > 0 && !inThread {
                    Button(action: onOpenThread) {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.caption2)
                            Text("\(replyCount) réponse\(replyCount > 1 ? "s" : "")").font(.caption.bold())
                            if let d = lastReply {
                                Text("· \(relativeDay(d))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator))
                    }
                    .buttonStyle(.plain).padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, showHeader ? 5 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.hover.opacity(0.5) : .clear)
        .overlay(alignment: .topTrailing) {
            if hovering || showPicker {
                HStack(spacing: 0) {
                    ForEach(Self.quickEmojis, id: \.self) { e in
                        EmojiHoverButton(emoji: e) {
                            p2p.toggleReaction(e, on: message, targets: targets)
                        }
                    }
                    Button { showPicker.toggle() } label: {
                        Image(systemName: "face.smiling").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 20).help("Plus d'émojis")
                    .popover(isPresented: $showPicker, arrowEdge: .top) {
                        EmojiPalette {
                            p2p.toggleReaction($0, on: message, targets: targets)
                            showPicker = false
                        }
                    }
                    if !inThread {
                        Divider().frame(height: 12).padding(.horizontal, 2)
                        Button(action: onOpenThread) {
                            Image(systemName: "bubble.left").font(.system(size: 11))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 20).help("Répondre dans un fil")
                    }
                    // Suppression : pour mes messages → diffusion ; pour ceux
                    // d'un contact → suppression locale seulement.
                    Divider().frame(height: 12).padding(.horizontal, 2)
                    Button {
                        let context = contactKey ?? message.fromKey ?? ""
                        p2p.deleteMessage(message, contactKey: context)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 20)
                    .help(message.fromMe ? "Supprimer pour tout le monde" : "Supprimer pour moi")
                }
                .padding(.horizontal, 3).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(Theme.surface)
                        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                )
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator, lineWidth: 0.5))
                .padding(.trailing, 10)
                .alignmentGuide(.top) { d in d[.top] + 14 }   // déplace la barre vers le haut MAIS conserve sa hit-area
                .zIndex(10)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
                .onHover { inside in
                    controlsHovering = inside
                    if inside { hovering = true }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: showPicker)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovering = true
            } else {
                // Délai plus généreux pour traverser entre messages sans perdre la barre.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !controlsHovering && !showPicker {
                        hovering = false
                    }
                }
            }
        }
    }
}

/// Bouton emoji individuel dans la barre flottante : scale au hover pour
/// retour visuel immédiat (façon Slack).
struct EmojiHoverButton: View {
    let emoji: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 14))
                .scaleEffect(hovering ? 1.25 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: hovering)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 20)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(hovering ? Theme.surfaceAlt : Color.clear))
        .onHover { hovering = $0 }
        .help("Réagir avec \(emoji)")
    }
}

/// Palette emoji étendue (Slack-like) en pop-up : catégories + tap direct.
struct EmojiPalette: View {
    var onPick: (String) -> Void
    static let palette: [(String, [String])] = [
        ("Smileys", ["😀","😁","😂","🤣","😊","😍","😎","🤩","🥰","😘","😜","😇","🤔","🙄","😴","🤤","😭","😱","😡","🤯"]),
        ("Gestes", ["👍","👎","👌","🤝","🙌","👏","🙏","🤞","✌️","🤘","👋","🤙","💪","👀","🫶","🤌"]),
        ("Cœurs", ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","💖","💕","💔","💯"]),
        ("Objets", ["🎉","🔥","✨","⚡️","💡","💎","🎁","🎯","🚀","✅","❌","⚠️","🆗","🆕"]),
        ("Nature", ["🐶","🐱","🦊","🦁","🐼","🐧","🐢","🐳","🌸","🌻","🌈","☀️","🌙","⭐️"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.palette, id: \.0) { (cat, list) in
                Text(cat).font(Theme.tiny).foregroundStyle(Theme.textSecondary).padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 10), spacing: 2) {
                    ForEach(list, id: \.self) { e in
                        Button { onPick(e) } label: { Text(e).font(.system(size: 18)) }
                            .buttonStyle(.plain).frame(width: 28, height: 28)
                    }
                }
            }
        }
        .padding(10).frame(width: 320)
    }
}

/// Pièce jointe d'un message P2P : image/vidéo/Rive lisibles inline une fois
/// téléchargées, sinon bouton de téléchargement (file d'attente hors-ligne).
struct P2PAttachmentView: View {
    @EnvironmentObject var p2p: P2PEngine
    let message: P2PEngine.P2PMessage
    /// Contexte (chat individuel ou salon) pour la synchro des commentaires P2P
    /// d'un attachment image/vidéo. Renseigné par la vue parente.
    var contactContext: String? = nil
    var att: P2PEngine.P2PAttachment { message.attachment! }
    var url: URL? { p2p.attachmentURL(message) }
    var downloaded: Bool { p2p.attachmentDownloaded(message) }
    var pending: Bool {
        p2p.fileDownloads.contains {
            $0.relPath == att.relPath && ($0.status == .waiting || $0.status == .transferring)
        }
    }
    @State private var lightboxURL: URL?
    @State private var videoReviewURL: URL?
    @State private var imageReviewURL: URL?

    private var ext: String { (att.fileName as NSString).pathExtension.lowercased() }
    private var isPDF: Bool { ext == "pdf" }
    private var isText: Bool {
        ["txt","md","markdown","json","csv","log","rtf","xml","yaml","yml","swift","js","ts","py","sh","html","css"].contains(ext)
    }
    private var isAudio: Bool {
        ["m4a","mp3","wav","aac","caf","aiff","aif","ogg","opus"].contains(ext)
    }

    var body: some View {
        Group {
            if downloaded, let url, isAudio {
                AudioBubble(url: url)
            } else if downloaded, let url, att.isVideo {
                VideoBubble(url: url)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 240)
                    .overlay(alignment: .topLeading) {
                        CommentCountBadge(messageID: message.id, isImage: false).padding(8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .onTapGesture { videoReviewURL = url }
                    .help("Clic : ouvrir en grand avec commentaires · Double-clic : app par défaut")
            } else if downloaded, let url, att.isRive {
                RiveBubble(url: url)
                    .frame(maxWidth: 360)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .onTapGesture { lightboxURL = url }
            } else if downloaded, let url, ext == "gif" {
                AnimatedGIFView(url: url)
                    .frame(maxWidth: 360, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        CommentCountBadge(messageID: message.id, isImage: true).padding(8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .onTapGesture { imageReviewURL = url }
                    .help("Clic : agrandir + commenter · Double-clic : ouvrir dans l'app par défaut")
            } else if downloaded, let url, att.isImage, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        CommentCountBadge(messageID: message.id, isImage: true).padding(8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .onTapGesture { imageReviewURL = url }
                    .help("Clic : agrandir + commenter/annoter · Double-clic : ouvrir dans l'app par défaut")
            } else if downloaded, let url, isPDF {
                VStack(alignment: .leading, spacing: 0) {
                    PDFPreview(url: url).frame(width: 360, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .onTapGesture { lightboxURL = url }
                    docFooter(url: url)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
            } else if downloaded, let url, isText {
                VStack(alignment: .leading, spacing: 0) {
                    TextPreview(url: url).frame(width: 360, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .onTapGesture { lightboxURL = url }
                    docFooter(url: url)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
            } else if downloaded, let url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").font(.title3).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(att.fileName).font(.callout.weight(.medium)).lineLimit(1)
                            Text(formatBytes(att.size)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    }
                    .padding(10).frame(maxWidth: 360, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
                }.buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: att.isVideo ? "video.fill" : (att.isImage ? "photo.fill" : (isPDF ? "doc.richtext.fill" : "doc.fill")))
                        .font(.title3)
                        .foregroundStyle(att.isVideo ? .pink : (att.isImage ? .blue : (isPDF ? .red : .gray)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(att.fileName).font(.callout.weight(.medium)).lineLimit(1)
                        Text(formatBytes(att.size)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if pending {
                        ProgressView().controlSize(.small)
                    } else if !message.fromMe {
                        Button { p2p.downloadAttachment(message) } label: {
                            Image(systemName: "arrow.down.circle.fill").font(.title3)
                        }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(10).frame(maxWidth: 360, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
            }
        }
        .sheet(item: Binding(
            get: { lightboxURL.map(IdentifiedURL.init) },
            set: { lightboxURL = $0?.url }
        )) { iu in
            FileLightbox(url: iu.url) { lightboxURL = nil }
                .frame(minWidth: 800, minHeight: 540)
        }
        .sheet(item: Binding(
            get: { videoReviewURL.map(IdentifiedURL.init) },
            set: { videoReviewURL = $0?.url }
        )) { iu in
            VideoReviewSheet(url: iu.url, messageID: message.id,
                             syncTargets: commentSyncTargets()) { videoReviewURL = nil }
                .frame(minWidth: 980, minHeight: 600)
        }
        .sheet(item: Binding(
            get: { imageReviewURL.map(IdentifiedURL.init) },
            set: { imageReviewURL = $0?.url }
        )) { iu in
            ImageReviewSheet(url: iu.url, messageID: message.id,
                             syncTargets: commentSyncTargets()) { imageReviewURL = nil }
                .frame(minWidth: 980, minHeight: 600)
        }
    }

    /// Destinataires P2P pour la synchro des commentaires de cet attachment :
    /// - en chat 1:1, le partenaire (l'autre côté de la conversation)
    /// - en salon, les membres du salon transmis via `contactContext` ??.
    private func commentSyncTargets() -> [String] {
        if let key = contactContext, !key.isEmpty { return [key] }
        if let key = message.fromKey, !message.fromMe { return [key] }
        return []
    }

    @ViewBuilder
    private func docFooter(url: URL) -> some View {
        HStack(spacing: 6) {
            Text(att.fileName).font(.caption.weight(.medium)).lineLimit(1)
            Text(formatBytes(att.size)).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.right.square")
            }.buttonStyle(.plain).help("Ouvrir avec l'app par défaut")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

/// Salon P2P façon Slack : messages diffusés à tous les membres.
struct P2PChannelView: View {
    @EnvironmentObject var p2p: P2PEngine
    let channel: P2PEngine.P2PChannel
    var onOpenThread: (P2PEngine.P2PMessage) -> Void
    @State private var showMembers = false

    var members: [String] { channel.memberKeys }
    var messages: [P2PEngine.P2PMessage] { p2p.messages(in: channel) }

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderBar(
                title: channel.name, online: false, avatarID: nil, icon: "number.square.fill",
                subtitle: members.map { p2p.name(for: $0) }.joined(separator: ", "),
                trailing: channel.createdBy == p2p.myPublicKey
                    ? AnyView(Button { showMembers = true } label: { Label("Membres", systemImage: "person.badge.plus") })
                    : nil)
            Divider()
            P2PTranscript(messages: messages, contactKey: nil,
                          targets: channel.memberKeys, onOpenThread: onOpenThread)
            Divider()
            P2PComposerBar(placeholder: "Message dans #\(channel.name)…",
                           scope: channel.name,
                           onSendText: { p2p.sendChannelMessage($0, in: channel) },
                           onAttach: { p2p.sendChannelMessage("", attachment: $0, in: channel) })
        }
        .background(Theme.bgApp)
        .fileDropZone(scope: channel.name) { p2p.sendChannelMessage("", attachment: $0, in: channel) }
        .onAppear { p2p.markChannelRead(channel.id) }
        .onChange(of: messages.count) { _ in p2p.markChannelRead(channel.id) }
        .sheet(isPresented: $showMembers) { P2PChannelSheet(existing: channel) }
    }
}

/// Panneau de fil de discussion affiché à droite (remplace la fiche contact).
struct ThreadPanel: View {
    @EnvironmentObject var p2p: P2PEngine
    let root: P2PEngine.P2PMessage
    let scope: Route?
    var onClose: () -> Void

    private var contactKey: String? { if case .contact(let k)? = scope { return k }; return nil }
    private var channel: P2PEngine.P2PChannel? {
        if case .channel(let id)? = scope { return p2p.channels.first { $0.id == id } }; return nil
    }
    private var targets: [String] { channel?.memberKeys ?? (contactKey.map { [$0] } ?? []) }
    private var replies: [P2PEngine.P2PMessage] {
        let all: [P2PEngine.P2PMessage]
        if let channel { all = p2p.messages(in: channel) }
        else if let contactKey { all = p2p.chats[contactKey] ?? [] }
        else { all = [] }
        return all.filter { $0.replyTo == root.id }.sorted { $0.date < $1.date }
    }
    private func send(_ text: String, _ att: P2PEngine.P2PAttachment?) {
        if let channel { p2p.sendChannelMessage(text, attachment: att, in: channel, replyTo: root.id) }
        else if let contactKey { p2p.send(text, attachment: att, to: contactKey, replyTo: root.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fil de discussion").font(Theme.h2).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.md)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    P2PRow(message: root, contactKey: targets.first, showHeader: true,
                           targets: targets, inThread: true)
                    HStack(spacing: 8) {
                        Text("\(replies.count) réponse\(replies.count > 1 ? "s" : "")")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        Rectangle().frame(height: 1).foregroundStyle(Theme.separator)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    ForEach(replies) { r in
                        P2PRow(message: r, contactKey: targets.first, showHeader: true,
                               targets: targets, inThread: true)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            P2PComposerBar(placeholder: "Répondre…",
                           scope: channel?.name ?? (contactKey.map { p2p.name(for: $0) } ?? "Fil"),
                           onSendText: { send($0, nil) }, onAttach: { send("", $0) })
        }
        .background(Theme.surface)
    }
}

/// Panneau d'un fil de discussion (réponses à un message).
struct P2PThreadSheet: View {
    @EnvironmentObject var p2p: P2PEngine
    @Environment(\.dismiss) var dismiss
    let root: P2PEngine.P2PMessage
    let replies: [P2PEngine.P2PMessage]
    let targets: [String]
    let scope: String
    var onSend: (String) -> Void
    var onAttach: (P2PEngine.P2PAttachment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fil de discussion").font(Theme.h2)
                Spacer()
                Button("Fermer") { dismiss() }
            }
            .padding(Theme.Space.lg)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    P2PRow(message: root, contactKey: targets.first, showHeader: true,
                           targets: targets, inThread: true)
                    HStack(spacing: 8) {
                        Text("\(replies.count) réponse\(replies.count > 1 ? "s" : "")")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        Rectangle().frame(height: 1).foregroundStyle(Theme.separator)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    ForEach(replies.sorted { $0.date < $1.date }) { r in
                        P2PRow(message: r, contactKey: targets.first, showHeader: true,
                               targets: targets, inThread: true)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            P2PComposerBar(placeholder: "Répondre…", scope: scope,
                           onSendText: onSend, onAttach: onAttach)
        }
        .frame(width: 480, height: 580)
        .background(Theme.bgApp)
    }
}

/// Création / édition des membres d'un salon (créateur uniquement).
struct P2PChannelSheet: View {
    @EnvironmentObject var p2p: P2PEngine
    @Environment(\.dismiss) var dismiss
    var existing: P2PEngine.P2PChannel?
    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Nouveau salon" : "Membres de #\(existing!.name)").font(.title3.bold())
            if existing == nil {
                TextField("Nom du salon (ex. projet-x)", text: $name).textFieldStyle(.roundedBorder)
            }
            Text("Membres").font(.headline)
            ForEach(p2p.contacts, id: \.self) { key in
                Toggle(p2p.name(for: key), isOn: Binding(
                    get: { selected.contains(key) },
                    set: { on in if on { selected.insert(key) } else { selected.remove(key) } }
                ))
            }
            Text("Le salon apparaît chez les membres à leur prochaine connexion. Pour que tout le monde voie tout, les membres doivent être appairés entre eux.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button(existing == nil ? "Créer" : "Enregistrer") {
                    var keys = Array(selected)
                    if !keys.contains(p2p.myPublicKey) { keys.append(p2p.myPublicKey) }
                    if let ex = existing { p2p.updateChannelMembers(ex.id, memberKeys: keys) }
                    else { p2p.createChannel(name: name.trimmingCharacters(in: .whitespaces), memberKeys: keys) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(existing == nil && name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear { if let ex = existing { name = ex.name; selected = Set(ex.memberKeys.filter { $0 != p2p.myPublicKey }) } }
    }
}

/// Panneau de détails du contact (3e colonne) : profil, présence, identité,
/// fichiers partagés — façon Slack/kDrive.
struct ProfilePanel: View {
    @EnvironmentObject var p2p: P2PEngine
    @EnvironmentObject var store: AppStore
    let contactKey: String
    var openFiles: () -> Void

    var files: [RemoteFile] { p2p.remoteFiles[contactKey] ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                P2PAvatar(contactKey: contactKey, size: 76)
                    .overlay(alignment: .bottomTrailing) {
                        PresenceDot(online: p2p.isOnline(contactKey), size: 16).offset(x: 2, y: 2)
                    }
                    .padding(.top, Theme.Space.lg)
                VStack(spacing: 2) {
                    Text(p2p.name(for: contactKey)).font(Theme.h2).foregroundStyle(Theme.textPrimary)
                    Text(p2p.isOnline(contactKey) ? "en ligne · P2P chiffré" : "hors ligne")
                        .font(Theme.small)
                        .foregroundStyle(p2p.isOnline(contactKey) ? Theme.success : Theme.textSecondary)
                }
                Button { openFiles() } label: {
                    Label("Voir ses fichiers", systemImage: "folder")
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.sm)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textPrimary)

                Divider()
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("À PROPOS").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                    infoRow("Identité", String(contactKey.prefix(22)) + "…")
                    infoRow("Fichiers partagés", "\(files.count)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !files.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        HStack {
                            Text("FICHIERS").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("Tout voir") { openFiles() }.font(Theme.small).buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                            ForEach(files.prefix(9)) { f in
                                RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceAlt)
                                    .frame(height: 56)
                                    .overlay(Image(systemName: fileIcon(f.path)).foregroundStyle(Theme.textSecondary))
                                    .help(f.name)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.lg)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.small).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
    private func panelButton(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) { Image(systemName: icon); Text(label).font(Theme.tiny) }
                .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceAlt))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.textPrimary)
    }
    private func fileIcon(_ path: String) -> String {
        let e = (path as NSString).pathExtension.lowercased()
        if ["png","jpg","jpeg","gif","heic","webp","tiff"].contains(e) { return "photo" }
        switch e { case "mp4","mov","m4v": return "play.rectangle"; case "pdf": return "doc.richtext"
        case "riv": return "sparkles"; default: return "doc" }
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

/// Avatar d'un contact P2P (résout la photo + le nom à jour automatiquement).
struct P2PAvatar: View {
    @EnvironmentObject var p2p: P2PEngine
    let contactKey: String
    var size: CGFloat = 28
    var body: some View {
        AvatarView(name: p2p.name(for: contactKey),
                   id: P2PEngine.uuid(forKey: contactKey),
                   size: size,
                   photoURL: p2p.avatarURL(forKey: contactKey))
    }
}

/// Mon avatar (photo si définie sinon initiales).
struct MyAvatar: View {
    @EnvironmentObject var p2p: P2PEngine
    @EnvironmentObject var store: AppStore
    var size: CGFloat = 28
    var body: some View {
        AvatarView(name: p2p.myName.isEmpty ? store.config.myName : p2p.myName,
                   id: P2PEngine.uuid(forKey: p2p.myPublicKey.isEmpty ? store.config.myID.uuidString : p2p.myPublicKey),
                   size: size,
                   photoURL: p2p.myAvatarURL)
    }
}

/// Avatar rond avec initiales, couleur stable dérivée de l'identité.
/// Affiche une photo si `photoURL` est fourni.
struct AvatarView: View {
    let name: String
    let id: UUID
    var size: CGFloat = 28
    var photoURL: URL? = nil

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
        if let url = photoURL, let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
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
    @State private var threadRoot: ChatMessage?

    var messages: [ChatMessage] {
        (store.chats[contact.id] ?? []).filter { $0.channelID == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(allMessages: messages, myID: store.config.myID,
                           onOpenThread: { threadRoot = $0 })
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
        .sheet(item: $threadRoot) { root in
            ThreadSheet(root: root,
                        replies: messages.filter { $0.replyTo == root.id },
                        scopeName: contact.name,
                        onSend: { store.sendMessage($0, to: contact, replyTo: root.id) },
                        onAttach: { store.sendMessage("", attachment: $0, to: contact, replyTo: root.id) })
        }
    }
}

struct GroupChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft = ""
    @State private var threadRoot: ChatMessage?

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
            ChatTranscript(allMessages: messages, myID: store.config.myID,
                           onOpenThread: { threadRoot = $0 })
            Divider()
            ChatComposer(draft: $draft, placeholder: "Message au groupe…") { text in
                store.broadcast(text)
            }
        }
        .chatFileDrop(scopeName: "Tous") { attachment in
            store.broadcast("", attachment: attachment)
        }
        .sheet(item: $threadRoot) { root in
            ThreadSheet(root: root,
                        replies: messages.filter { $0.replyTo == root.id },
                        scopeName: "Tous",
                        onSend: { store.broadcast($0, replyTo: root.id) },
                        onAttach: { store.broadcast("", attachment: $0, replyTo: root.id) })
        }
    }
}

struct ChannelChatView: View {
    @EnvironmentObject var store: AppStore
    let channel: Channel
    @State private var draft = ""
    @State private var showMembers = false
    @State private var threadRoot: ChatMessage?

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
            ChatTranscript(allMessages: store.messages(in: channel),
                           myID: store.config.myID, onOpenThread: { threadRoot = $0 })
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
        .sheet(item: $threadRoot) { root in
            ThreadSheet(root: root,
                        replies: store.messages(in: channel).filter { $0.replyTo == root.id },
                        scopeName: channel.name,
                        onSend: { store.sendChannelMessage($0, in: channel, replyTo: root.id) },
                        onAttach: { store.sendChannelMessage("", attachment: $0, in: channel, replyTo: root.id) })
        }
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

/// Panneau du moteur expérimental P2P (Phase 1) : identité, appairage cs1-,
/// pairs connectés, ping de test, journal en direct.
struct P2PPanel: View {
    @EnvironmentObject var p2p: P2PEngine
    @Environment(\.dismiss) var dismiss
    @State private var joinCode = ""

    var statusText: String {
        switch p2p.status {
        case .stopped: return "Arrêté"
        case .starting: return "Démarrage…"
        case .ready: return "Prêt"
        case .reconnecting(let s): return "Reconnexion (\(s)s)…"
        case .failed(let m): return "Erreur : \(m)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Moteur P2P (expérimental)").font(.title3.bold())
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Button("Fermer") { dismiss() }
            }

            LabeledContent("Mon identité") {
                Text(p2p.myPublicKey.isEmpty ? "—" : p2p.myPublicKey)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }

            Divider()

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inviter").font(.headline)
                    Button("Créer un code cs1-…") { p2p.createInvite() }
                    if !p2p.inviteCode.isEmpty {
                        HStack {
                            Text(p2p.inviteCode)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p2p.inviteCode, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rejoindre").font(.headline)
                    TextField("cs1-…", text: $joinCode)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Rejoindre") { p2p.acceptInvite(joinCode); joinCode = "" }
                        .disabled(joinCode.isEmpty)
                }
            }

            Divider()

            Text("Pairs connectés (\(p2p.peers.count))").font(.headline)
            if p2p.peers.isEmpty {
                Text("Aucun pair connecté.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(p2p.peers) { peer in
                    HStack {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(peer.key).font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Text(peer.direct ? "direct" : "relayé")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ping") { p2p.ping(peer.key) }.font(.caption)
                    }
                }
            }

            Divider()

            HStack {
                Text("Journal").font(.headline)
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p2p.log.joined(separator: "\n"), forType: .string)
                }
                .font(.caption)
                Button("Effacer") { p2p.log.removeAll() }.font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(p2p.log.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))

            Text("Test à DEUX machines : crée le code sur un Mac, saisis-le sur l'AUTRE (P2P activé des deux côtés). Une même app ne peut pas s'appairer avec elle-même.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560, height: 600)
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

// Regroupe des messages par jour (séparateurs façon Slack).
func groupByDay(_ msgs: [ChatMessage]) -> [(date: Date, messages: [ChatMessage])] {
    let cal = Calendar.current
    let sorted = msgs.sorted { $0.date < $1.date }
    var out: [(date: Date, messages: [ChatMessage])] = []
    for m in sorted {
        let day = cal.startOfDay(for: m.date)
        if let last = out.last, cal.isDate(last.date, inSameDayAs: day) {
            out[out.count - 1].messages.append(m)
        } else {
            out.append((date: day, messages: [m]))
        }
    }
    return out
}

func dayLabel(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Aujourd'hui" }
    if cal.isDateInYesterday(date) { return "Hier" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    f.dateFormat = "EEEE d MMMM"
    let s = f.string(from: date)
    return s.prefix(1).uppercased() + s.dropFirst()
}

func relativeDay(_ date: Date) -> String {
    let r = RelativeDateTimeFormatter()
    r.locale = Locale(identifier: "fr_FR")
    r.unitsStyle = .full
    return r.localizedString(for: date, relativeTo: Date())
}

/// Séparateur de jour centré (« Aujourd'hui », « Hier », « jeudi 28 mai »).
struct DayDivider: View {
    let date: Date
    var body: some View {
        HStack(spacing: 8) {
            line
            Text(dayLabel(date))
                .font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(
                    Capsule().fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(Capsule().stroke(.gray.opacity(0.25)))
                )
            line
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
    }
    var line: some View { Rectangle().frame(height: 1).foregroundStyle(.gray.opacity(0.18)) }
}

/// Transcription façon Slack : aligné à gauche, avatar + nom par message,
/// séparateurs par jour, messages consécutifs groupés, fils de réponse.
struct ChatTranscript: View {
    @EnvironmentObject var store: AppStore
    let allMessages: [ChatMessage]
    let myID: UUID
    var onOpenThread: (ChatMessage) -> Void

    private var topLevel: [ChatMessage] { allMessages.filter { $0.replyTo == nil } }
    private var replyInfo: [UUID: (count: Int, last: Date)] {
        var d: [UUID: (Int, Date)] = [:]
        for m in allMessages where m.replyTo != nil {
            let k = m.replyTo!
            if let e = d[k] { d[k] = (e.0 + 1, max(e.1, m.date)) } else { d[k] = (1, m.date) }
        }
        return d
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupByDay(topLevel), id: \.date) { group in
                        DayDivider(date: group.date)
                        ForEach(Array(group.messages.enumerated()), id: \.element.id) { idx, msg in
                            let prev = idx > 0 ? group.messages[idx - 1] : nil
                            let grouped = prev != nil && prev!.fromID == msg.fromID
                                && msg.date.timeIntervalSince(prev!.date) < 300
                            let info = replyInfo[msg.id]
                            MessageRow(message: msg, showHeader: !grouped,
                                       replyCount: info?.count ?? 0, lastReplyDate: info?.last,
                                       onOpenThread: { onOpenThread(msg) })
                                .id(msg.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(topLevel.last?.id, anchor: .bottom) }
            .onChange(of: topLevel.count) { _ in
                withAnimation { proxy.scrollTo(topLevel.last?.id, anchor: .bottom) }
            }
        }
    }
}

/// Corps d'un message (pièce jointe / Rive / texte Markdown) — réutilisé en
/// transcription et dans les fils.
struct MessageBody: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage

    var formattedText: AttributedString {
        (try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let attachment = message.attachment {
                AttachmentBubble(message: message, attachment: attachment,
                                 isMine: message.fromID == store.config.myID)
            }
            if let riveURL = RiveLinkPreview.riveLink(in: message.text) {
                RiveLinkPreview(url: riveURL)
            }
            if !message.text.isEmpty {
                Text(formattedText)
                    .textSelection(.enabled)
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Une ligne de message façon Slack : gouttière avatar + nom + heure, corps,
/// et — pour un message racine ayant des réponses — l'accès au fil.
struct MessageRow: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let showHeader: Bool
    var replyCount: Int = 0
    var lastReplyDate: Date? = nil
    var onOpenThread: () -> Void = {}
    @State private var hovering = false

    var isMine: Bool { message.fromID == store.config.myID }
    var senderColor: Color { AvatarView(name: message.fromName, id: message.fromID).color }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Gouttière : avatar (1er du groupe) ou espace réservé.
            if showHeader {
                AvatarView(name: message.fromName, id: message.fromID, size: 32).padding(.top, 1)
            } else {
                Color.clear.frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                if showHeader {
                    HStack(spacing: 6) {
                        Text(message.fromName).font(.subheadline.weight(.semibold)).foregroundStyle(senderColor)
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        if isMine && !message.delivered {
                            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                MessageBody(message: message)
                if replyCount > 0 {
                    Button(action: onOpenThread) {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.caption2)
                            Text("\(replyCount) réponse\(replyCount > 1 ? "s" : "")").font(.caption.bold())
                            if let d = lastReplyDate {
                                Text("· dernière réponse \(relativeDay(d))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25)))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, showHeader ? 5 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.hover.opacity(0.5) : .clear)
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 1) {
                    Button(action: onOpenThread) {
                        Image(systemName: "bubble.left").font(.system(size: 14))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 26).help("Répondre dans un fil")
                    Divider().frame(height: 14)
                    Button(role: .destructive) { store.deleteMessage(message) } label: {
                        Image(systemName: "trash").font(.system(size: 14))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 26).help(isMine ? "Supprimer pour tout le monde" : "Supprimer pour moi")
                }
                .padding(.horizontal, 2).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator, lineWidth: 0.5))
                .padding(.trailing, 10).offset(y: -3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button { onOpenThread() } label: {
                Label("Répondre dans un fil", systemImage: "arrowshape.turn.up.left")
            }
            Button(role: .destructive) { store.deleteMessage(message) } label: {
                Label(isMine ? "Supprimer pour tout le monde" : "Supprimer pour moi",
                      systemImage: "trash")
            }
        }
    }
}

/// Panneau d'un fil de discussion (réponses à un message), façon Slack.
struct ThreadSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let root: ChatMessage
    let replies: [ChatMessage]
    let scopeName: String
    var onSend: (String) -> Void
    var onAttach: (Attachment) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fil de discussion").font(.headline)
                Spacer()
                Button("Fermer") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MessageRow(message: root, showHeader: true)
                    HStack(spacing: 8) {
                        Text("\(replies.count) réponse\(replies.count > 1 ? "s" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Rectangle().frame(height: 1).foregroundStyle(.gray.opacity(0.2))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    ForEach(replies.sorted { $0.date < $1.date }) { r in
                        MessageRow(message: r, showHeader: true)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            ChatComposer(draft: $draft, placeholder: "Répondre…") { onSend($0) }
        }
        .frame(width: 460, height: 560)
        .chatFileDrop(scopeName: scopeName) { onAttach($0) }
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
    @EnvironmentObject var p2p: P2PEngine
    @State private var showLog = false
    @State private var showP2P = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Réglages").font(.title3.bold())

            // Mon profil : photo + nom modifiables.
            HStack(spacing: Theme.Space.lg) {
                Button { pickAvatar() } label: {
                    ZStack {
                        AvatarView(name: store.config.myName,
                                   id: P2PEngine.uuid(forKey: p2p.myPublicKey.isEmpty ? store.config.myID.uuidString : p2p.myPublicKey),
                                   size: 72,
                                   photoURL: store.config.avatarPath.map { URL(fileURLWithPath: $0) })
                        Circle().fill(Color.black.opacity(0.001)).frame(width: 72, height: 72)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.fill").font(.caption)
                                    .padding(5).background(Circle().fill(Theme.accent)).foregroundStyle(.white)
                            }
                    }
                }
                .buttonStyle(.plain).help("Changer ma photo")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mon profil").font(Theme.tiny).foregroundStyle(Theme.textSecondary)
                    TextField("Mon nom", text: Binding(
                        get: { store.config.myName },
                        set: { store.config.myName = $0; p2p.setMyName($0) }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    if store.config.avatarPath != nil {
                        Button("Retirer ma photo") {
                            store.config.avatarPath = nil; p2p.setMyAvatar(nil)
                        }.font(Theme.small).buttonStyle(.plain).foregroundStyle(Theme.danger)
                    }
                }
                Spacer()
            }
            .padding(.bottom, 4)

            LabeledContent("Dossier partagé") {
                HStack {
                    Text(store.config.sharedFolder ?? "Aucun")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(store.config.sharedFolder == nil ? .secondary : .primary)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button("Choisir…") {
                        if let url = pickFolder() {
                            store.config.sharedFolder = url.path
                            p2p.configure(sharedFolder: url.path, downloadBase: store.mirrorRootURL.path)
                        }
                    }
                }
            }

            LabeledContent("Dossier CrocShare (fichiers reçus)") {
                HStack {
                    Text(store.config.downloadFolder ?? "~/CrocShare")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button("Choisir…") {
                        if let url = pickFolder() {
                            store.config.downloadFolder = url.path
                            p2p.configure(sharedFolder: store.config.sharedFolder, downloadBase: store.mirrorRootURL.path)
                        }
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

            LabeledContent(L10n("settings.language")) {
                Picker("", selection: Binding(
                    get: { LocalizationManager.preferred },
                    set: { LocalizationManager.preferred = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(L10n(lang.displayKey)).tag(lang)
                    }
                }
                .frame(width: 220)
            }
            Text(L10n("settings.language_restart_required"))
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Rétention du chat") {
                Picker("", selection: Binding(
                    get: { store.config.chatRetentionDays ?? 0 },
                    set: { store.config.chatRetentionDays = $0 }
                )) {
                    Text("Jamais (tout garder)").tag(0)
                    Text("3 mois").tag(90)
                    Text("6 mois").tag(180)
                    Text("12 mois").tag(365)
                }
                .frame(width: 220)
                .onChange(of: store.config.chatRetentionDays) { newValue in
                    p2p.purgeOldMessages(olderThanDays: newValue ?? 0)
                }
            }
            Text("Les messages plus vieux que cette durée sont effacés au démarrage de l'app (uniquement chez toi ; tes contacts gardent leur propre historique selon leur réglage).")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            KDriveRelaySettingsSection()

            Divider()

            LabeledContent("Debug") {
                HStack {
                    Button("Journal de synchronisation…") { showLog = true }
                    if p2p.hasBot {
                        Button("Retirer le Robot") { p2p.removeBot() }
                    } else {
                        Button("Ajouter le Robot 🤖") { p2p.addBot() }
                    }
                }
            }
            Text("Contact « Démo » simulé localement : toujours en ligne, répond aux messages, fichiers téléchargeables (générés sur place). Aucun transfert croc réel.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            LabeledContent("Moteur P2P") {
                HStack {
                    Circle().fill(p2p.isReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(p2p.isReady ? "connecté au réseau" : "démarrage…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Diagnostic…") { showP2P = true }
                }
            }
            if !p2p.myPublicKey.isEmpty {
                Text("Mon identité : \(p2p.myPublicKey)")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Text("Connexions pair-à-pair chiffrées de bout en bout (Hyperswarm), sans serveur ni relai.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: 600, alignment: .leading)
        .sheet(isPresented: $showLog) { SyncLogSheet() }
        .sheet(isPresented: $showP2P) { P2PPanel() }
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if let img = UTType(filenameExtension: "png"), let img2 = UTType(filenameExtension: "jpg") {
            panel.allowedContentTypes = [img, img2, UTType.image]
        }
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dst = P2PEngine.avatarsDir.appendingPathComponent("me-\(UUID().uuidString.prefix(8)).\(src.pathExtension)")
        try? FileManager.default.copyItem(at: src, to: dst)
        store.config.avatarPath = dst.path
        p2p.setMyAvatar(dst.path)
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

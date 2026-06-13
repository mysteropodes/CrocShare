import Foundation

/// Un contact appairé : on partage avec lui un secret commun,
/// duquel sont dérivés tous les codes croc (canaux manifest / requête / fichiers).
struct Contact: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var secret: String
}

/// Une entrée de la liste de fichiers distante (le "manifest" d'un contact).
struct RemoteFile: Codable, Identifiable, Hashable {
    var path: String
    var size: Int64
    var mtime: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Pièce jointe d'un message : le fichier est copié dans le dossier partagé
/// de l'expéditeur (sous Chat/<canal ou contact>/) et téléchargeable via croc
/// comme n'importe quel fichier partagé.
struct Attachment: Codable, Hashable {
    var fileName: String
    /// Chemin relatif dans le dossier partagé de l'expéditeur.
    var relPath: String
    var size: Int64

    var isVideo: Bool {
        ["mp4", "mov", "m4v"].contains((fileName as NSString).pathExtension.lowercased())
    }
    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"]
            .contains((fileName as NSString).pathExtension.lowercased())
    }
    var isRive: Bool {
        (fileName as NSString).pathExtension.lowercased() == "riv"
    }
}

/// Une room type Slack (espace de travail) : regroupe des canaux et des membres.
/// Synchronisée à ses membres via les manifests, comme les canaux.
struct Room: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var memberIDs: [UUID]
    var createdBy: UUID
}

/// Un canal de discussion type Slack : un nom et un sous-groupe de contacts.
/// Peut appartenir à une room (roomID) ou être indépendant.
/// La définition du canal est synchronisée à ses membres via les manifests.
struct Channel: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var memberIDs: [UUID]
    var createdBy: UUID
    var roomID: UUID? = nil
}

/// Un message de chat. Les messages voyagent embarqués dans les manifests :
/// même mécanique que les fichiers (file d'attente hors ligne, envoi auto à la reconnexion).
struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var fromID: UUID
    var fromName: String
    var text: String
    var date: Date
    /// Pour mes messages sortants : accusé de réception du contact reçu.
    var delivered: Bool
    /// nil = message direct ; sinon, id du canal.
    var channelID: UUID? = nil
    var attachment: Attachment? = nil
}

/// Payload du canal chat dédié (réactif) : messages en attente + suppressions.
/// La réception réussie via croc vaut accusé de livraison.
struct ChatPayload: Codable {
    var messages: [ChatMessage] = []
    var deleteIDs: [UUID] = []
}

/// La liste des fichiers que quelqu'un partage, échangée périodiquement via croc.
/// Transporte aussi les messages de chat en attente et les accusés de réception.
struct Manifest: Codable {
    var senderID: UUID
    var senderName: String
    var files: [RemoteFile]
    var generatedAt: Date
    var messages: [ChatMessage]? = nil
    var ackIDs: [UUID]? = nil
    /// Canaux dont le destinataire est membre, pour qu'il les voie apparaître.
    var channels: [Channel]? = nil
    /// Rooms dont le destinataire est membre.
    var rooms: [Room]? = nil
}

/// Un téléchargement demandé par l'utilisateur.
/// Reste en `waiting` tant que le contact est hors ligne, puis part automatiquement.
struct PendingDownload: Codable, Identifiable, Hashable {
    var id: UUID
    var contactID: UUID
    var filePath: String
    var size: Int64
    var createdAt: Date
    var status: Status

    enum Status: String, Codable {
        case waiting, transferring, done, failed
    }
}

/// Requête envoyée au contact : "envoie-moi ces fichiers sur le canal <requestID>".
struct FileRequest: Codable {
    var requestID: String
    var paths: [String]
}

/// Fichier d'invitation (.crocinvite) : appairage asynchrone par mail/message.
/// L'invité l'importe quand il veut ; l'accusé revient via croc dès que les
/// deux machines sont en ligne en même temps, sans coordination.
struct InviteFile: Codable {
    var inviteID: UUID
    var secret: String
    var hostID: UUID
    var hostName: String
}

/// Côté hôte : invitation émise, en attente d'acceptation.
struct PendingInvite: Codable, Identifiable, Hashable {
    var id: UUID
    var secret: String
    var createdAt: Date
}

/// Côté invité : accusé d'acceptation à délivrer à l'hôte (réessayé jusqu'au succès).
struct PendingInviteAck: Codable, Identifiable, Hashable {
    var id: UUID
    var secret: String
}

/// Payload échangé lors de l'appairage (le secret n'est présent que côté hôte).
struct PairingPayload: Codable {
    var id: UUID
    var name: String
    var secret: String?
}

struct AppConfig: Codable {
    var myID: UUID = UUID()
    var myName: String = NSFullUserName()
    var sharedFolder: String?
    var downloadFolder: String?
    /// Relai croc auto-hébergé (`croc relay`), ex. "monserveur.fr:9009".
    /// Vide = relai public. Sur le même réseau local, croc se passe de relai.
    var customRelay: String?
    /// Héberger le relai croc directement sur ce Mac (l'app utilise alors 127.0.0.1:9009,
    /// les contacts saisissent l'IP publique de ce Mac dans leur relai personnalisé).
    var hostRelay: Bool? = false
}

func formatBytes(_ bytes: Int64) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    return fmt.string(fromByteCount: bytes)
}

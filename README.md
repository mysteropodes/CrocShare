# CrocShare (macOS)

Messagerie et partage de fichiers **pair-à-pair**, chiffrés de bout en bout,
sans serveur central — avec un workflow de revue vidéo et image inspiré de
Frame.io intégré au chat.

> [!NOTE]
> Cette app utilise [Hyperswarm](https://github.com/holepunchto/hyperswarm)
> (DHT P2P de Holepunch) pour la découverte et le transport, avec
> [croc](https://github.com/schollz/croc) en réserve. Aucun compte, aucun
> serveur à héberger. Embarque ses propres binaires.

## Aperçu

- 🔐 **Chat P2P chiffré** par contact ou par salon, avec accusés de réception,
  réactions emoji, fils de réponse, messages audio (.m4a), pièces jointes
  (image, vidéo, PDF, texte, GIF animé, Rive), bundles multi-fichiers
  « tout télécharger » façon Slack.
- 📁 **Dossiers partagés** : ton dossier local est visible par tes contacts en
  ligne. Navigateur grille/liste avec vignettes, sort, panneau d'infos par
  fichier ou par dossier, clic droit « Partager avec… » + suivi visuel.
- 🎬 **Revue vidéo façon Frame.io** : lecteur grand format, scrubber avec
  markers, commentaires timestampés, threading, validation ✅, annotations à
  main levée pendant la pause. Sync P2P des commentaires entre pairs.
- 🖼 **Revue image** : même workflow (commentaires + dessin) sur les images.
- ☁️ **Relais asynchrone kDrive** (opt-in) : quand un contact est hors ligne,
  les messages peuvent être déposés chiffrés (AES-GCM 256) sur un dossier
  Infomaniak kDrive et livrés à sa reconnexion.
- 🍎 **Vibrancy macOS**, sidebar verticale unifiée, sheets Quick Look-style,
  mises à jour automatiques (Sparkle).

## Installation

Télécharge la dernière release : <https://github.com/mysteropodes/CrocShare/releases/latest>

Glisse `CrocShare.app` dans `/Applications`. Si macOS bloque au premier
lancement (« app non vérifiée par Apple ») :

```sh
xattr -dr com.apple.quarantine /Applications/CrocShare.app
```

Les mises à jour suivantes passent par Sparkle, pas besoin de répéter.

## Premier démarrage

1. Réglages (⚙️) → **choisir ton dossier partagé** (et un dossier de
   téléchargement si tu veux changer le défaut `~/CrocShare`).
2. **Ajouter un contact** (👤+) : génère un code (`cs1-xxxx-xxxx-…`),
   transmets-le par tout canal sûr. Le contact saisit le code dans sa
   propre app. La paire échange identités et secret via Hyperswarm.
3. Une fois appairés, l'icône en barre des menus indique la présence du
   contact en temps réel.

## Workflow de revue (Frame.io-like)

- **Clic** sur une vidéo/image dans le chat → sheet plein écran avec :
  - lecteur grand format (vidéo) ou image agrandie
  - panneau commentaires à droite : ajout au timecode courant, threading,
    pastille de validation cliquable, édition inline
  - bouton crayon → **auto-pause** + palette couleurs/épaisseur + annotation à
    main levée
- **Double-clic** sur la même vignette → ouvre dans l'app par défaut macOS.

Les commentaires se synchronisent automatiquement avec le pair quand les deux
sont en ligne (payload P2P `vcomm`). Persistance locale dans UserDefaults.

## Relais asynchrone kDrive (optionnel)

Si tu veux que tes messages atteignent un contact **même quand il est hors
ligne**, active dans Réglages → Relai kDrive :

1. Crée un Personal Access Token Infomaniak (scope `drive`) depuis le manager.
2. Note l'ID de ton Drive et celui d'un dossier dédié (`crocshare-relay` par
   exemple).
3. Colle PAT + drive ID + folder ID dans Réglages, clique « Tester ».

Le PAT est stocké dans le **Trousseau macOS**, jamais sur disque en clair.
Les messages sont chiffrés AES-GCM 256 (clé HKDF dérivée de la paire P2P)
avant upload — le relais ne voit qu'un blob opaque. Polling adaptatif,
nettoyage automatique > 7 jours par défaut.

## Construire depuis les sources

Prérequis : Xcode 15+, [Node.js](https://nodejs.org) 20+ pour le compagnon
P2P (récupéré par le script), une identité Apple Developer pour la signature
stable (Sparkle l'exige).

```sh
# 1. Récupère les binaires natifs (croc, Node, Sparkle, Rive).
./fetch-croc.sh
./fetch-runtime.sh

# 2. Build "Lab" (signature ad-hoc, bundle id séparé, pas d'auto-update).
LAB=1 ./make-app.sh
open "CrocShare Lab.app"

# 3. Build "prod" signé (nécessite une identité Apple Developer).
export SIGN_IDENTITY="Apple Development: ton.email@example.com (TEAMID)"
./make-app.sh
open CrocShare.app
```

Pour une release Sparkle complète (zip signé EdDSA + appcast), voir
`release.sh`. Tu auras besoin de la clé privée Sparkle dans le Trousseau.

## Architecture

Le code Swift vit dans `Sources/CrocShare/`. Vue rapide :

| Domaine | Fichiers principaux |
|---|---|
| Entrée app | `CrocShareApp.swift` (Scene + menu bar) |
| Modèle | `Models.swift`, `Store.swift` |
| Moteur P2P | `P2PEngine.swift` + extensions `+Bot` `+Relay`, `CoreBridge.swift` |
| Compagnon Node | `core/*.js` (Hyperswarm, pairing, peers) |
| UI principale | `ContentView.swift` |
| Médias | `MediaViews.swift` (vidéo, Rive, PDF, texte, GIF animé) |
| Revue vidéo/image | `VideoReview.swift` (scrubber, annotations, threading) |
| Audio | `AudioMessage.swift` |
| Lightbox | `Lightbox.swift` |
| Relai kDrive | `KDriveRelay.swift`, `KDriveRelayUI.swift` |
| Vibrancy | `VisualEffectBackground.swift` |
| Updates | `UpdateManager.swift` (Sparkle) |
| Croc legacy | `CrocService.swift`, `SyncEngine.swift`, `PairingService.swift`, `Channels.swift` |

### Protocole P2P (chat direct)

Au-dessus d'Hyperswarm (Noise + UDX, déjà chiffré bout-en-bout) on échange des
payloads JSON :

| `k` | Sémantique |
|---|---|
| `msg` | Message texte, optionnellement avec `att` (pièce jointe) |
| `ack` | Accusé de réception (`ids`) |
| `react` | Réaction emoji (toggle) |
| `manifest` | Liste de fichiers partagés |
| `freq` | Requête de fichier (`reqId`, `relPath`) |
| `chan` | Définition de salon |
| `profile` | Nom + avatar |
| `vcomm` | Commentaire vidéo/image (upsert/delete) |

Les attachments sont indexés par `relPath` dans un sous-dossier `Chat/<scope>/`
du dossier partagé.

### Sécurité

- Transport : Noise IK (Hyperswarm) bout-en-bout entre les pairs, jamais en
  clair sur le réseau.
- Stockage local : seed identité dans le Trousseau (`Keychain.swift`), secret
  de contact idem. Aucun mot de passe en clair sur disque.
- Relais kDrive : payload chiffré côté client AES-GCM 256, le serveur ne voit
  qu'un blob opaque + métadonnées de routage (short-key 8 hex).

## Limitations connues

- Pas (encore) de signaling NAT-traversal manuel : si Hyperswarm n'arrive pas
  à percer, configurer un relai croc personnalisé reste possible.
- Sync P2P des commentaires limitée aux pairs en ligne au moment où on les
  écrit (à venir : enqueue via kDrive relay).
- Version Windows / iOS / Android : non développée pour le moment ; le
  protocole est portable, l'UI macOS ne l'est pas.

## Crédits & licences

- [croc](https://github.com/schollz/croc) — MIT, Zack Scholl
- [Hyperswarm](https://github.com/holepunchto/hyperswarm) — Apache 2.0, Holepunch Inc.
- [Sparkle](https://sparkle-project.org) — MIT
- [Rive](https://rive.app) runtime — MIT

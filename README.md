# CrocShare (macOS)

Partage de dossier entre contacts, façon « dossier cloud », propulsé par
[croc](https://github.com/schollz/croc) — transferts chiffrés de bout en bout,
sans serveur à héberger (relai public croc).

## Principe

L'app vit dans la **barre de menus** (icône nuage ☁️) et tourne en arrière-plan.
Le dossier `~/CrocShare/<Contact>/` se comporte comme un dossier cloud :
chaque fichier distant non téléchargé y apparaît comme un fichier d'attente
`nom.ext.croc` avec une icône nuage. **Double-clic** (ou clic droit → Ouvrir)
→ téléchargement via croc, le vrai fichier remplace le fichier d'attente.
Contact hors ligne → mise en attente, téléchargement automatique à sa
reconnexion, notification à l'arrivée.


- Tu choisis un **dossier partagé** local : son contenu est visible par tes contacts.
- Quand deux ordinateurs sont en ligne en même temps, les **listes de fichiers se
  synchronisent automatiquement** (toutes les ~30 s).
- Un clic sur ⬇︎ télécharge le fichier. Si le contact est **hors ligne**, le
  téléchargement est **mis en attente** et démarre **automatiquement** à sa
  reconnexion, avec une **notification macOS**.
- **Clés gérées automatiquement** : un seul code d'appairage à échanger une fois
  (par téléphone/message). Ensuite, tous les canaux croc (liste, requêtes,
  fichiers) sont dérivés par HMAC-SHA256 du secret partagé — rien à gérer.

## Chat

Chaque contact a un onglet **Chat** (et « Tous les contacts » envoie à chacun).
Les messages voyagent embarqués dans les échanges de listes croc : si le
contact est hors ligne, ils sont remis automatiquement à sa reconnexion
(latence ≈ 10-40 s quand les deux sont en ligne). Accusé de réception ✓,
notification à l'arrivée, historique persisté dans
`~/Library/Application Support/CrocShare/chats.json`.

## Prérequis

```sh
brew install croc
```

## Construire et lancer

```sh
./make-app.sh
open CrocShare.app
```

(ou en dev : `swift run`)

## Premier démarrage

1. **Réglages** (⚙️) → choisir ton **dossier partagé** (et éventuellement le
   dossier de téléchargement, par défaut `~/Downloads/CrocShare/<Contact>`).
2. **Ajouter un contact** (👤+) :
   - Toi : onglet **Inviter** → « Générer un code » → communique le code
     (`share-xxxx-xxxx-xxxx`) à ton contact.
   - Lui : onglet **Rejoindre** → saisit le code.
   - Les deux apps échangent identités et secret via croc, puis la synchro démarre.

## Architecture

| Fichier | Rôle |
|---|---|
| `CrocService.swift` | Enveloppe du binaire croc (send/receive avec timeout) |
| `Channels.swift` | Dérivation HMAC des codes croc depuis le secret partagé |
| `SyncEngine.swift` | 4 boucles par contact : publier sa liste, lire celle du contact (= présence), servir ses demandes, traiter la file d'attente |
| `PairingService.swift` | Appairage : échange du secret via un code à usage unique |
| `Store.swift` | État + persistance JSON (`~/Library/Application Support/CrocShare/`) |
| `Notifier.swift` | Notifications (UNUserNotificationCenter, fallback osascript) |

### Protocole (au-dessus de croc)

Pour chaque paire de contacts (secret `S`, identités `A`/`B`) :

- **Manifest** : `A` envoie en boucle sa liste JSON sur le code
  `HMAC(S, "manifest:A:B")` ; `B` la reçoit en boucle. Une réception réussie =
  `A` est en ligne (vert).
- **Requête** : pour télécharger, `B` envoie `{requestID, paths}` sur
  `HMAC(S, "request:B:A")`.
- **Livraison** : `A` vérifie que les chemins restent dans le dossier partagé,
  puis envoie les fichiers sur `HMAC(S, "files:<requestID>")`.

## Limites connues (v1)

- Les transferts passent par le relai public croc (chiffré de bout en bout,
  mais débit dépendant du relai). Un relai privé (`croc relay`) est possible —
  champ à ajouter si besoin.
- Le menu contextuel « Télécharger » natif du Finder (comme iCloud) nécessite
  une extension File Provider signée avec un compte développeur Apple ; ici
  c'est le double-clic sur le fichier d'attente `.croc` qui déclenche le
  téléchargement.
- Version Windows : à faire séparément (C#/WinUI ou portage Go/Wails) — le
  protocole ci-dessus est indépendant de la plateforme, seul le client change.

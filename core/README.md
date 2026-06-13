# crocshare-core — compagnon P2P (Phase 1)

Processus réseau de CrocShare bâti sur **Hyperswarm/Hypercore** (Holepunch).
Remplace à terme le moteur croc : connexions persistantes chiffrées (chat quasi
temps réel), découverte par DHT (zéro serveur de rendez-vous).

En Phase 1, il **coexiste** avec croc derrière le réglage masqué « Moteur
expérimental P2P ». Le chat réel, la file hors-ligne et Hyperdrive sont Phases 2-4.

## Architecture

```
Swift (CoreBridge.swift)  ──stdin/stdout NDJSON──▶  crocshare-core
  identité (Trousseau)                              identity.js  clés Ed25519, topics
  UI / réglages                                     swarm.js     Hyperswarm
                                                    pairing.js   invitations cs1-
                                                    peers.js     connexions persistantes
                                                    rpc.js       protocole stdio
                                                    index.js     orchestrateur
```

Frontière stricte : Swift ne touche jamais au réseau, le Core ne touche jamais
au Trousseau ni à l'UI. Tout passe par le protocole RPC (§5 du brief).

## Identité et clés

- Paire Ed25519 dérivée d'une **seed de 32 octets**.
- La seed est gardée par Swift dans le **Trousseau** (`com.mysteropode.crocshare.identity`)
  et transmise au Core via la requête `init` (jamais en argument de ligne de
  commande, jamais sur disque en clair, jamais dans les logs).
- Les clés publiques des contacts sont persistées dans
  `…/Application Support/CrocShare/core/contacts.json` (rien de secret).

## Appairage (codes `cs1-…`)

1. L'hôte appelle `pairing.createInvite` → secret 16 o aléatoire → topic DHT
   éphémère `hash("crocshare-pairing:" + secret)` → renvoie `cs1-` + z32(secret).
2. L'invité saisit le code → `pairing.acceptInvite` → même topic → connexion
   Hyperswarm chiffrée (Noise). La clé publique distante est authentifiée par
   Noise (pas de signature maison nécessaire).
3. Ensuite, les deux rejoignent le **topic stable du couple**
   `hash("crocshare-peer:" + tri(pubA, pubB))` → reconnexion automatique à chaque
   démarrage via la DHT.

## Lancer les tests

```sh
cd core
npm install
npm test            # ou: npx brittle test/two-peers.test.js
```

`two-peers.test.js` lance deux processus core, les appaire via un code `cs1-…`
sur une **DHT locale** (testnet, hors-ligne) et valide un ping/echo applicatif
(round-trip ~1 ms).

## Runtime embarqué

`fetch-runtime.sh` récupère Node 22 LTS (arm64) dans `runtime/node` ;
`make-app.sh` l'embarque avec `core/` (deps de production) dans
`CrocShare.app/Contents/Resources/`, signé avec entitlements JIT.

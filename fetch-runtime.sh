#!/bin/zsh
# Récupère le runtime Node embarqué pour le compagnon P2P (crocshare-core).
# Place uniquement le binaire `node` dans runtime/, embarqué ensuite par
# make-app.sh dans CrocShare.app/Contents/Resources/runtime/.
# arm64 (Apple Silicon) — cohérent avec le binaire Swift de l'app.
set -e
cd "$(dirname "$0")"

NODE_VERSION="22.11.0"   # LTS
ARCH="arm64"
BASE="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-${ARCH}"

mkdir -p runtime
cd runtime
rm -rf node "node-v${NODE_VERSION}-darwin-${ARCH}" node.tar.gz

curl -sL -o node.tar.gz "${BASE}.tar.gz"
tar xzf node.tar.gz
cp "node-v${NODE_VERSION}-darwin-${ARCH}/bin/node" node
chmod +x node
rm -rf "node-v${NODE_VERSION}-darwin-${ARCH}" node.tar.gz

./node --version
echo "✅ runtime/node prêt (Node ${NODE_VERSION}, ${ARCH})"

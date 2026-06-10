#!/bin/zsh
# Récupère le binaire croc officiel (Intel + Apple Silicon) et le fusionne en
# binaire universel dans vendor/croc, embarqué ensuite dans l'app par make-app.sh.
set -e
cd "$(dirname "$0")"

CROC_VERSION="10.4.4"
BASE="https://github.com/schollz/croc/releases/download/v${CROC_VERSION}"

mkdir -p vendor
cd vendor
rm -rf arm amd croc

curl -sL -o croc-arm.tar.gz "$BASE/croc_v${CROC_VERSION}_macOS-ARM64.tar.gz"
curl -sL -o croc-amd.tar.gz "$BASE/croc_v${CROC_VERSION}_macOS-64bit.tar.gz"
mkdir -p arm amd
tar xzf croc-arm.tar.gz -C arm
tar xzf croc-amd.tar.gz -C amd
lipo -create arm/croc amd/croc -output croc
chmod +x croc
cp arm/LICENSE LICENSE-croc 2>/dev/null || true
rm -rf arm amd croc-arm.tar.gz croc-amd.tar.gz

lipo -info croc
./croc --version
echo "✅ vendor/croc prêt (universel, v${CROC_VERSION})"

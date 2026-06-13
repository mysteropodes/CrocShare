#!/bin/zsh
# Construit « CrocShare Lab » : build de TEST du moteur P2P (Phase 2).
# Identifiant, nom et stockage distincts → s'installe et tourne À CÔTÉ de
# l'app de production sans la toucher. Pas d'auto-update Sparkle.
set -e
cd "$(dirname "$0")"

APP="CrocShare Lab.app"

LAB=1 ./make-app.sh

# Version lisible + re-signature ad-hoc (l'Info.plist vient d'être modifié).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.0-p2p" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

mkdir -p dist
rm -rf dmg-staging "dist/CrocShare-Lab.dmg"
mkdir dmg-staging
cp -R "$APP" dmg-staging/
ln -s /Applications dmg-staging/Applications
hdiutil create -volname "CrocShare Lab" -srcfolder dmg-staging -ov -format UDZO "dist/CrocShare-Lab.dmg" -quiet
rm -rf dmg-staging

echo "✅ dist/CrocShare-Lab.dmg — installe sur les 2 Macs, active Réglages → Config → Moteur expérimental P2P"

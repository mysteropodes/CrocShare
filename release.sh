#!/bin/zsh
# Publie une mise à jour CrocShare (même workflow que RecentDrop) :
# build → zip → signature EdDSA Sparkle → appcast.xml.
# Prérequis : la clé privée Sparkle est dans le trousseau de ce Mac (déjà fait
# pour RecentDrop, même clé), et le repo GitHub mysteropodes/CrocShare existe.
set -e
cd "$(dirname "$0")"

VERSION="1.1"        # version visible — incrémenter à chaque release
BUILD_NUMBER="2"     # +1 à chaque release

PRODUCT="CrocShare"
DIST="dist"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
DOWNLOAD_URL="https://github.com/mysteropodes/CrocShare/releases/download/v${VERSION}/${PRODUCT}-${VERSION}.zip"

# Synchroniser la version dans le bundle
./make-app.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PRODUCT.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PRODUCT.app/Contents/Info.plist"
codesign --force --deep --sign - "$PRODUCT.app"

mkdir -p "$DIST"
ZIP="$DIST/${PRODUCT}-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$PRODUCT.app" "$ZIP"

# sign_update renvoie : sparkle:edSignature="..." length="..."
SIGN_OUT=$("$SPARKLE_BIN/sign_update" "$ZIP")
echo "Signature : $SIGN_OUT"

cat > "$DIST/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CrocShare</title>
    <link>https://raw.githubusercontent.com/mysteropodes/CrocShare/main/appcast.xml</link>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <pubDate>$(date -R)</pubDate>
      <enclosure url="${DOWNLOAD_URL}" ${SIGN_OUT} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST

echo ""
echo "✅ Release prête dans $DIST/ :"
echo "   1) Créer la release GitHub v${VERSION} et y joindre ${ZIP}"
echo "   2) Commit & push dist/appcast.xml → appcast.xml à la racine du repo (branche main)"
echo "   3) Les utilisateurs recevront la notification Sparkle dans les 24 h (ou via le menu)"

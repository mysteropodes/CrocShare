#!/bin/zsh
# Construit CrocShare.app (bundle macOS) à partir du package Swift.
set -e
cd "$(dirname "$0")"

swift build -c release

# LAB=1 → build de test « CrocShare Lab » (id/nom/stockage distincts, sans
# auto-update Sparkle) qui coexiste avec l'app de production.
if [[ "$LAB" == "1" ]]; then
    APP="CrocShare Lab.app"; BUNDLE_ID="com.crocshare.lab"; DISPLAY_NAME="CrocShare Lab"
else
    APP="CrocShare.app"; BUNDLE_ID="com.crocshare.app"; DISPLAY_NAME="CrocShare"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/bin"

cp .build/release/CrocShare "$APP/Contents/MacOS/CrocShare"

# croc embarqué (binaire universel officiel, licence MIT) : récupéré par
# fetch-croc.sh dans vendor/. L'app le préfère à toute install système.
if [[ ! -x vendor/croc ]]; then
    echo "⚠️  vendor/croc manquant — lance ./fetch-croc.sh d'abord"
    exit 1
fi
cp vendor/croc "$APP/Contents/Resources/bin/croc"
cp vendor/LICENSE-croc "$APP/Contents/Resources/bin/LICENSE-croc" 2>/dev/null || true

# ── Compagnon P2P (crocshare-core) + runtime Node embarqués ────
# Le moteur expérimental P2P (Hyperswarm). Coexiste avec croc.
if [[ ! -x runtime/node ]]; then
    echo "⚠️  runtime/node manquant — lance ./fetch-runtime.sh d'abord"
    exit 1
fi
mkdir -p "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/core"
cp runtime/node "$APP/Contents/Resources/runtime/node"
cp core/*.js core/package.json core/package-lock.json "$APP/Contents/Resources/core/"
# Dépendances de production uniquement (sans brittle/hyperdht de test).
( cd "$APP/Contents/Resources/core" && npm ci --omit=dev --silent )

# Sparkle.framework (récupéré via SPM) : embarqué dans le bundle + rpath,
# sinon dyld ne le trouve pas au lancement.
SPARKLE_XCFW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
cp -R "$SPARKLE_XCFW" "$APP/Contents/Frameworks/Sparkle.framework"
RIVE_XCFW=".build/artifacts/rive-ios/RiveRuntime/RiveRuntime.xcframework/macos-arm64_x86_64/RiveRuntime.framework"
cp -R "$RIVE_XCFW" "$APP/Contents/Frameworks/RiveRuntime.framework"
install_name_tool -delete_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/CrocShare" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/CrocShare"
# Nettoyage du rpath résiduel vers le toolchain Xcode (inutile hors machine de dev).
TOOLCHAIN_RPATH=$(otool -l "$APP/Contents/MacOS/CrocShare" | grep -o '/Applications/Xcode.app[^ ]*' | head -1 || true)
if [[ -n "$TOOLCHAIN_RPATH" ]]; then
    install_name_tool -delete_rpath "$TOOLCHAIN_RPATH" "$APP/Contents/MacOS/CrocShare" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CrocShare</string>
    <key>CFBundleIdentifier</key><string>com.crocshare.app</string>
    <key>CFBundleName</key><string>CrocShare</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.1</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <!-- ── Sparkle (mises à jour auto, même clé que RecentDrop) ───── -->
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/mysteropodes/CrocShare/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>Whc8u7dF8m4CqdZodXPFsm/DteW5aHcCE32GcUeSHnQ=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Fichier distant CrocShare</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array><string>com.crocshare.placeholder</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Invitation CrocShare</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array><string>com.crocshare.invite</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.crocshare.placeholder</string>
            <key>UTTypeDescription</key><string>Fichier distant CrocShare</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>croc</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.crocshare.invite</string>
            <key>UTTypeDescription</key><string>Invitation CrocShare</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>crocinvite</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Identité du bundle (prod ou Lab).
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$APP/Contents/Info.plist"
if [[ "$LAB" == "1" ]]; then
    # Pas d'auto-update Sparkle pour le test (sinon il s'écraserait avec la prod).
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# ── Signature ─────────────────────────────────────────────────
if [[ "$LAB" == "1" ]]; then
    # Build de test : signature ad-hoc (aucun accès Trousseau requis), sans
    # hardened runtime → Node/JIT + addons .node tournent ; pas d'auto-update.
    codesign --force --deep --sign - "$APP"
else
# Certificat Apple Development (même que RecentDrop) : signature stable entre
# les builds — indispensable pour Sparkle (l'updater refuse une identité qui
# change) et pour le trousseau/pare-feu. Composants Sparkle signés un par un
# (--deep casse les XPC services de Sparkle).
SIGN_IDENTITY="Apple Development: cyrildrouinm@icloud.com (9D5K76CQ8M)"

SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
XPC_DIR="$SPARKLE_FW/Versions/B/XPCServices"
if [[ -d "$XPC_DIR" ]]; then
    for x in "$XPC_DIR"/*.xpc; do
        [[ -d "$x" ]] && codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$x"
    done
fi
[[ -f "$SPARKLE_FW/Versions/B/Autoupdate" ]] && \
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
[[ -d "$SPARKLE_FW/Versions/B/Updater.app" ]] && \
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/RiveRuntime.framework"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/bin/croc"
# Runtime Node + addons natifs du compagnon (.node) signés un par un.
# Node a besoin d'entitlements JIT (V8) et de pouvoir charger des addons .node
# sous le hardened runtime, sinon il crashe au lancement.
NODE_ENT="$(mktemp -t crocshare-node).entitlements"
cat > "$NODE_ENT" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
ENT
codesign --force --options runtime --timestamp --entitlements "$NODE_ENT" \
    --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/runtime/node"
find "$APP/Contents/Resources/core" -name "*.node" -print0 | while IFS= read -r -d '' n; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$n"
done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

echo "✅ $APP construit. Lance-le avec : open $APP"

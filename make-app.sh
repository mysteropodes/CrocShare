#!/bin/zsh
# Construit CrocShare.app (bundle macOS) à partir du package Swift.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="CrocShare.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

cp .build/release/CrocShare "$APP/Contents/MacOS/CrocShare"

# Sparkle.framework (récupéré via SPM) : embarqué dans le bundle + rpath,
# sinon dyld ne le trouve pas au lancement.
SPARKLE_XCFW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
cp -R "$SPARKLE_XCFW" "$APP/Contents/Frameworks/Sparkle.framework"
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
    <key>LSMinimumSystemVersion</key><string>13.0</string>
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
    </array>
</dict>
</plist>
PLIST

# Signature ad-hoc : nécessaire pour les notifications et Gatekeeper local.
codesign --force --deep --sign - "$APP"

echo "✅ $APP construit. Lance-le avec : open $APP"

#!/bin/sh
# Baut Lumi.app aus dem Swift-Paket (ohne Xcode): Release-Build, App-Bundle
# mit Info.plist (Agent-App ohne Dock-Symbol, Kalender-/Benachrichtigungs-
# Begründungen), Hook-Relay daneben, Ad-hoc-Signatur.
#   mac/scripts/bundle.sh            → mac/build/Lumi.app
#   mac/scripts/bundle.sh --install  → zusätzlich nach ~/Applications kopieren
set -e
cd "$(dirname "$0")/.."

CONFIG=release
swift build -c "$CONFIG" --product Taby
swift build -c "$CONFIG" --product taby-hook-relay
swift build -c "$CONFIG" --product taby-mcp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/Lumi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Taby" "$APP/Contents/MacOS/Taby"
cp "$BIN/taby-hook-relay" "$APP/Contents/MacOS/taby-hook-relay"
cp "$BIN/taby-mcp" "$APP/Contents/MacOS/taby-mcp"
# Lokale Symbole entfernen (vor dem Signieren): Binary rund 25 % kleiner, Verhalten gleich.
strip -x "$APP/Contents/MacOS/Taby" "$APP/Contents/MacOS/taby-mcp"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Kurzer Commit für die Update-Prüfung (leer ohne git). Muss zu publish-dmg.sh passen.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
# Fortlaufende Build-Nummer für die Update-Prüfung (0 ohne git). Muss zu publish-dmg.sh passen.
# +1000: das saubere Repo startete bei Commit 1, Apps aus dem alten Verlauf hatten schon Build 820+.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
[ "$BUILD" -gt 0 ] && BUILD=$((BUILD + 1000))
# Anzeigename "2.<Build>" wie AppUpdate.versionName (ohne Build "2.0").
VERSION_NAME=2.0
[ "$BUILD" -gt 0 ] && VERSION_NAME="2.$BUILD"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>de.felix.taby</string>
  <key>CFBundleName</key><string>Lumi</string>
  <key>CFBundleDisplayName</key><string>Lumi</string>
  <key>CFBundleExecutable</key><string>Taby</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION_NAME</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>TabyCommit</key><string>$COMMIT</string>
  <key>TabyBuild</key><integer>$BUILD</integer>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Lumi liest und schreibt Termine im Kalender, um Konflikte zu prüfen und dein Briefing zusammenzustellen.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Lumi gleicht deine Aufgaben mit Apple Erinnerungen ab, damit sie auf all deinen Geräten gleich sind.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Lumi gleicht deine Aufgaben mit Apple Erinnerungen ab.</string>
  <key>NSContactsUsageDescription</key>
  <string>Lumi sucht Kontakte, wenn du jemandem schreiben oder anrufen willst, und erinnert an Geburtstage.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Lumi liest Termine im Kalender, um Konflikte zu prüfen und dein Briefing zusammenzustellen.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Lumi hört zu, solange du die Sprechen-Taste hältst, und macht aus deinen Worten Aufgaben, Notizen oder Termine. Auf Wunsch schreibt Lumi ein Meeting lokal mit; Ton wird nie gespeichert.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Lumi liest den Bildschirmausschnitt, den du einkreist, um deine Frage dazu zu beantworten.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Lumi wandelt deine Sprache in Text um (wenn möglich direkt auf dem Mac). Die Meeting-Mitschrift läuft nur auf dem Mac.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Lumi liest auf deinen Wunsch Betreff und Absender deiner Mails in Apple Mail, sortiert sie und sendet Antworten erst nach deiner Bestätigung.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.taby.plan-row</string>
      <key>UTTypeDescription</key><string>Lumi Plan-Zeile</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Mit Lumi erfassen</string>
      </dict>
      <key>NSMessage</key>
      <string>captureText</string>
      <key>NSPortName</key>
      <string>Taby</string>
      <key>NSSendTypes</key>
      <array>
        <string>NSStringPboardType</string>
        <string>public.utf8-plain-text</string>
      </array>
    </dict>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Mit Lumi erklären</string>
      </dict>
      <key>NSMessage</key>
      <string>explainText</string>
      <key>NSPortName</key>
      <string>Taby</string>
      <key>NSSendTypes</key>
      <array>
        <string>NSStringPboardType</string>
        <string>public.utf8-plain-text</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Einrichtungs-Skript für Updates (Lumi ruft es nach dem Austausch auf).
cp scripts/friend-setup.command "$APP/Contents/Resources/friend-setup.command"
chmod +x "$APP/Contents/Resources/friend-setup.command"
# Anleitung für „Anleitung öffnen“ in der Einrichtung (Text, kein Skript).
cp docs/ANLEITUNG-FREUNDE.txt "$APP/Contents/Resources/ANLEITUNG-FREUNDE.txt"

# Signatur: lokales Zertifikat (scripts/setup-signing.sh) hält Freigaben über
# Updates stabil; ohne Zertifikat oder mit SIGN_IDENTITY=- ad hoc (z. B. DMG für Freunde).
if [ -z "$SIGN_IDENTITY" ]; then
  if security find-certificate -c "Taby Local Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="Taby Local Signing"
  else
    SIGN_IDENTITY="-"
  fi
fi
echo "Signatur: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/MacOS/taby-hook-relay"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/MacOS/taby-mcp"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
echo "gebaut: $(pwd)/$APP"

if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Lumi.app"
  cp -R "$APP" "$HOME/Applications/Lumi.app"
  echo "installiert: $HOME/Applications/Lumi.app"
fi

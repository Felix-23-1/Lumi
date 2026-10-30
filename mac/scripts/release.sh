#!/bin/sh
# Baut eine weitergebbare Lumi.dmg (Apple Silicon + Intel, ad-hoc signiert,
# ohne Apple-Entwicklerkonto/Notarisierung) mit Anleitung für Freunde.
#   mac/scripts/release.sh   → mac/build/Lumi.dmg
set -e
cd "$(dirname "$0")/.."

# Für Freunde ad hoc signieren (dein lokales Zertifikat gehört nicht auf fremde Macs).
SIGN_IDENTITY=- ./scripts/bundle.sh
APP=build/Lumi-release.app
rm -rf "$APP"
cp -R build/Lumi.app "$APP"

# Zweite Architektur bauen und zu Universal-Binaries zusammenfügen.
for product in Taby taby-hook-relay taby-mcp; do
  swift build -c release --product "$product" --triple x86_64-apple-macosx14.0
done
ARM="$(swift build -c release --show-bin-path)"
X86=.build/x86_64-apple-macosx/release
for bin in Taby taby-hook-relay taby-mcp; do
  lipo -create "$ARM/$bin" "$X86/$bin" -output "$APP/Contents/MacOS/$bin"
done
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/taby-hook-relay"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/taby-mcp"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/Taby"

STAGE=build/dmg
rm -rf "$STAGE" build/Lumi.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Lumi.app"
# Übergang für ältere Installationen: deren Update kopiert <Volume>/Taby.app. Echte Kopie (kein Link),
# im Finder ausgeblendet, damit „Lumi“ allein auffällt.
ditto "$APP" "$STAGE/Taby.app"
if command -v SetFile >/dev/null 2>&1; then SetFile -a V "$STAGE/Taby.app"; fi
ln -s /Applications "$STAGE/Programme"
cp scripts/friend-setup.command "$STAGE/Lumi einrichten.command"
chmod +x "$STAGE/Lumi einrichten.command"
cp docs/ANLEITUNG-FREUNDE.txt "$STAGE/Erst lesen.txt"

hdiutil create -volname "Lumi" -srcfolder "$STAGE" -ov -format UDZO build/Lumi.dmg >/dev/null
rm -rf "$STAGE"
echo "fertig: $(pwd)/build/Lumi.dmg ($(du -h build/Lumi.dmg | cut -f1))"

# Deine eigene build/Lumi.app wieder mit dem lokalen Zertifikat signieren
# (der DMG-Bau oben hat sie ad hoc signiert).
./scripts/bundle.sh >/dev/null

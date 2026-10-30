#!/bin/sh
# Baut die Freunde-DMG und legt sie mit Einrichtungs-Skript und Anleitung in
# den Ordner download/ im Repository. Danach committen und pushen – dann gibt
# es auf GitHub immer die aktuelle Version zum Herunterladen.
#   mac/scripts/publish-dmg.sh
set -e
cd "$(dirname "$0")/.."
git diff --quiet HEAD || { echo "Abbruch: uncommittete Änderungen. Bitte erst committen, dann veröffentlichen." >&2; exit 1; }
# Ohne Schlüssel entstünde eine unsignierte Version; vor dem Bauen abbrechen.
security find-generic-password -s "${TABY_UPDATE_KEY_SERVICE:-taby-update-signing-key}" -a Taby >/dev/null 2>&1 \
  || { echo "Kein Update-Schlüssel – einmal ./scripts/make-update-key.sh ausführen." >&2; exit 1; }
./scripts/release.sh
OUT=../download
mkdir -p "$OUT"
cp build/Lumi.dmg "$OUT/Lumi.dmg"
# Alte Apps laden die Update-Datei weiter als Taby.dmg.
cp build/Lumi.dmg "$OUT/Taby.dmg"
cp scripts/friend-setup.command "$OUT/Lumi einrichten.command"
chmod +x "$OUT/Lumi einrichten.command"
cp scripts/friend-setup.command "$OUT/Taby einrichten.command"
chmod +x "$OUT/Taby einrichten.command"
cp docs/ANLEITUNG-FREUNDE.txt "$OUT/Anleitung.txt"
VERSION="$(git rev-parse --short HEAD)"
printf 'Stand: %s (Commit %s)\n' "$(date '+%Y-%m-%d %H:%M')" "$VERSION" > "$OUT/VERSION.txt"
# Wird von den Lumi-Apps für "Jetzt aktualisieren" gelesen (Commit = TabyCommit in der App).
BUILD=$(($(git rev-list --count HEAD) + 1000))  # gleiche Zählung wie bundle.sh
# Signatur über "<build>\n<commit>\n<sha256>" mit dem Schlüssel aus dem Schlüsselbund (scripts/update-sign.swift).
SIGNED="$(swift scripts/update-sign.swift sign "$BUILD" "$VERSION" "$OUT/Taby.dmg")"
SHA="${SIGNED%% *}"
SIG="${SIGNED#* }"
# Was ist neu (RELEASE-NOTES.txt, Klartext, höchstens 600 Zeichen, Steuerzeichen raus). Nur Anzeige:
# die Signatur deckt sie nicht ab. Fehlt die Datei oder ist sie leer, bleibt version.json im alten Format.
NOTES=""
if [ -s RELEASE-NOTES.txt ]; then
  NOTES="$(python3 -I -c '
import json, unicodedata
text = open("RELEASE-NOTES.txt", encoding="utf-8").read()
text = "".join(c for c in text if c == "\n" or unicodedata.category(c) != "Cc")
text = text.strip()[:600].strip()
print(json.dumps(text, ensure_ascii=False) if text else "")
')"
fi
if [ -n "$NOTES" ]; then
  printf '{"commit":"%s","build":%s,"date":"%s","sha256":"%s","signature":"%s","notes":%s}\n' "$VERSION" "$BUILD" "$(date '+%Y-%m-%dT%H:%M')" "$SHA" "$SIG" "$NOTES" > "$OUT/version.json"
else
  printf '{"commit":"%s","build":%s,"date":"%s","sha256":"%s","signature":"%s"}\n' "$VERSION" "$BUILD" "$(date '+%Y-%m-%dT%H:%M')" "$SHA" "$SIG" > "$OUT/version.json"
fi
echo "download/ aktualisiert ($VERSION)"

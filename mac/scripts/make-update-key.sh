#!/bin/sh
# Einmal ausführen: legt den Update-Schlüssel (Ed25519) im Schlüsselbund an und
# gibt NUR den öffentlichen Schlüssel aus (für AppUpdates.swift, updatePublicKey).
# Existiert der Schlüssel schon, wird nur der öffentliche Teil ausgegeben.
#   mac/scripts/make-update-key.sh
# Neuer Schlüssel wird mit leerer Vertrauensliste (-T "") gespeichert. Ein älterer Eintrag
# ohne diese Sperre: einmal "swift scripts/update-sign.swift lock" ausführen.
set -e
cd "$(dirname "$0")/.."
swift scripts/update-sign.swift keygen
echo "Hinweis: bestehenden Eintrag sperren mit: swift scripts/update-sign.swift lock" >&2

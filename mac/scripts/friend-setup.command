#!/bin/sh
# Lumi einrichten (für Freunde): legt einmalig ein eigenes, selbstsigniertes
# Zertifikat "Taby Local Signing" im Anmelde-Schlüsselbund an und signiert
# /Applications/Lumi.app damit. Danach merkt sich macOS die Freigaben
# (Schlüsselbund, Kalender, Erinnerungen) dauerhaft – auch nach Updates.
# Der Schlüssel ist nicht exportierbar und keinem Programm vorab freigegeben:
# der Schlüsselbund fragt bei jeder Signatur einmal nach. Dort „Erlauben“ wählen,
# nicht „Immer erlauben“.
# Braucht nur Bordmittel von macOS (kein Xcode, kein Apple-Konto).
# Optional: Pfad zu einer anderen Lumi.app als erstes Argument.
set -e
NAME="Taby Local Signing"
if [ -n "$1" ]; then APP="$1"; elif [ -d /Applications/Lumi.app ]; then APP=/Applications/Lumi.app; else APP=/Applications/Taby.app; fi
KEYCHAIN="${TABY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

echo "== Lumi einrichten =="
if [ ! -d "$APP" ]; then
  echo "Lumi.app nicht gefunden unter $APP."
  echo "Bitte zuerst Lumi.app aus der DMG in den Ordner Programme ziehen und dieses Skript erneut öffnen."
  exit 1
fi

# Lumi beenden, falls es läuft.
osascript -e 'tell application id "de.felix.taby" to quit' >/dev/null 2>&1 || true
sleep 1

# SHA-1 des Zertifikats mit exakt diesem Namen (nicht als Teilstring).
find_hash() {
  security find-identity -p codesigning "$KEYCHAIN" | awk -F'"' -v n="$NAME" '$2 == n { print $1; exit }' | awk '{ print $2 }'
}

HASH="$(find_hash)"
if [ -n "$HASH" ]; then
  echo "Zertifikat ist schon vorhanden – wird wiederverwendet."
else
  echo "Lege dein eigenes Zertifikat an (nur für diesen Mac) …"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  # macOS' eigenes openssl (LibreSSL) schreibt PKCS#12 in dem Format, das
  # der Schlüsselbund lesen kann. Leeres Passwort: kein Geheimnis auf der Befehlszeile.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/taby.p12" -passout "pass:"
  security import "$TMP/taby.p12" -k "$KEYCHAIN" -P "" -x >/dev/null
  HASH="$(find_hash)"
  [ -n "$HASH" ] || { echo "Zertifikat wurde nicht gefunden."; exit 1; }
  echo "Zertifikat angelegt."
fi

echo "Signiere Lumi mit deinem Zertifikat …"
echo "Beim Schlüsselbund-Dialog auf „Erlauben“ klicken (nicht „Immer erlauben“)."
# Download-Sperre entfernen (sonst fragt macOS beim ersten Start nach).
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
for helper in taby-hook-relay taby-mcp; do
  if [ -f "$APP/Contents/MacOS/$helper" ]; then
    codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --timestamp=none "$APP/Contents/MacOS/$helper"
  fi
done
codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --timestamp=none "$APP"
codesign --verify "$APP"

echo "Fertig! Lumi startet jetzt."
[ -n "$TABY_NO_OPEN" ] || open "$APP"
echo "Du kannst dieses Fenster schließen."

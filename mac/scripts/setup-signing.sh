#!/bin/sh
# Legt einmalig ein lokales Signatur-Zertifikat "Taby Local Signing" im
# Anmelde-Schlüsselbund an (selbstsigniert, nur für diesen Mac, kein
# Apple-Entwicklerkonto nötig). bundle.sh signiert Lumi dann immer gleich –
# macOS behält dadurch Schlüsselbund- und Datenschutz-Freigaben (Erinnerungen,
# Kalender) auch nach Updates. Entfernen: Schlüsselbundverwaltung → "Taby Local Signing" löschen.
set -e
NAME="Taby Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Zertifikat \"$NAME\" ist schon vorhanden."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 16)"

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

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
# macOS' security liest nur die alten PKCS#12-Algorithmen.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/taby.p12" -passout "pass:$PASS"

security import "$TMP/taby.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -x
echo "Zertifikat \"$NAME\" angelegt."

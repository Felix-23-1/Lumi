#!/usr/bin/env bash
# Baut die offizielle Matrix Rust SDK FFI (Crate matrix-sdk-ffi, Apache-2.0,
# dieselbe Schicht wie Element X) als universelle statische Bibliothek
# (arm64 + x86_64) plus Swift-Bindings nach mac/Vendor/MatrixSDK.
# Das Ergebnis wird NICHT ins Git eingecheckt (siehe mac/.gitignore).
#
# Aufruf:  ./scripts/build-matrix-sdk.sh [--keep]
#   --keep  behält mac/.matrix-build (Quellen und Zwischenstände)
# Idempotent: ist mac/Vendor/MatrixSDK/VERSION mit dem gepinnten Tag gefüllt,
# passiert nichts. Zum Neubauen Vendor/MatrixSDK löschen.
set -euo pipefail

MATRIX_SDK_REPO="https://github.com/matrix-org/matrix-rust-sdk.git"
# Neuester stabiler Release-Tag von matrix-sdk-ffi bei Erstellung (2026-10-14).
MATRIX_SDK_TAG="matrix-sdk-ffi/20260909"
LIB_NAME="matrix_sdk_ffi"
export MACOSX_DEPLOYMENT_TARGET=14.0
# Rust per Homebrew-rustup; Pfade nur ergänzen, falls vorhanden.
export PATH="$(brew --prefix rustup 2>/dev/null)/bin:$HOME/.cargo/bin:$PATH"
# Kleine Bibliothek: Release-Profil auf Größe, ohne Debug-Infos. Jede Variable
# lässt sich von außen überschreiben (z. B. CARGO_PROFILE_RELEASE_OPT_LEVEL=3).
# panic bleibt "unwind": uniffi braucht es, daher nicht auf abort setzen.
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-0}"
export CARGO_PROFILE_RELEASE_OPT_LEVEL="${CARGO_PROFILE_RELEASE_OPT_LEVEL:-z}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-fat}"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-1}"
# Nur die Features, die Taby braucht: SQLite-Store (eingebaut) und rustls.
# Die übrigen Standard-Extras (experimentelle Suche, Push-Geheimnisse, Emojis,
# MSC4274) bleiben weg. Anders setzen mit MATRIX_FFI_FEATURES="a,b" oder
# MATRIX_FFI_FEATURES="default" für die Standardfeatures.
FFI_FEATURES="${MATRIX_FFI_FEATURES:-bundled-sqlite,rustls-aws-lc-rs}"
if [ "$FFI_FEATURES" = "default" ]; then
  FFI_ARGS=()
else
  FFI_ARGS=(--no-default-features --features "$FFI_FEATURES")
fi

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
MAC="$(cd "$SCRIPTS/.." && pwd)"
BUILD="$MAC/.matrix-build"
SRC="$BUILD/src"
OUT="$BUILD/out"
VENDOR="$MAC/Vendor/MatrixSDK"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

say() { echo "==> $*"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
check_disk() {
  local f
  f="$(free_gb)"
  say "Freier Platz: ${f} GB"
  if [ "$f" -lt 5 ]; then
    echo "Abbruch: weniger als 5 GB frei" >&2
    exit 1
  fi
}

if [ -f "$VENDOR/VERSION" ] && [ "$(cat "$VENDOR/VERSION")" = "$MATRIX_SDK_TAG" ] \
   && [ -f "$VENDOR/lib/lib$LIB_NAME.a" ]; then
  say "Schon gebaut ($MATRIX_SDK_TAG), nichts zu tun."
  exit 0
fi

mkdir -p "$BUILD" "$OUT"

# 1. Quellen am gepinnten Tag (flach).
if [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" = "$MATRIX_SDK_TAG" ]; then
  say "Quellen vorhanden: $MATRIX_SDK_TAG"
else
  rm -rf "$SRC"
  say "Klone $MATRIX_SDK_TAG"
  git clone --depth 1 --branch "$MATRIX_SDK_TAG" "$MATRIX_SDK_REPO" "$SRC"
fi

# 2. Je Architektur bauen, die Bibliothek herausholen, den Build-Ordner löschen.
build_arch() {
  local triple="$1" arch="$2" t0 t1 tgt
  if [ -f "$OUT/lib$LIB_NAME-$arch.a" ] && [ -f "$OUT/lib$LIB_NAME-$arch.dylib" ]; then
    say "$arch: Zwischenstand vorhanden"
    return
  fi
  check_disk
  say "Baue $triple ($(date +%H:%M:%S))"
  t0="$(date +%s)"
  ( cd "$SRC" && cargo build -p matrix-sdk-ffi --release --target "$triple" ${FFI_ARGS[@]+"${FFI_ARGS[@]}"} )
  t1="$(date +%s)"
  tgt="$SRC/target/$triple/release"
  cp "$tgt/lib$LIB_NAME.a" "$OUT/lib$LIB_NAME-$arch.a"
  # Die dylib dient nur den Swift-Bindings (uniffi liest die Metadaten daraus).
  cp "$tgt/lib$LIB_NAME.dylib" "$OUT/lib$LIB_NAME-$arch.dylib"
  rm -rf "$SRC/target/$triple"
  say "$arch fertig in $((t1 - t0)) s"
}

build_arch aarch64-apple-darwin aarch64
build_arch x86_64-apple-darwin x86_64

# 3. Swift-Bindings aus der arm64-dylib erzeugen (Crate uniffi-bindgen des Repos).
GEN="$OUT/generated"
rm -rf "$GEN" && mkdir -p "$GEN"
check_disk
say "Erzeuge Swift-Bindings"
( cd "$SRC" && cargo run -p uniffi-bindgen -- generate \
    --library "$OUT/lib$LIB_NAME-aarch64.dylib" \
    --language swift --out-dir "$GEN" )

rm -rf "$VENDOR/include" "$VENDOR/Swift" "$VENDOR/lib"
mkdir -p "$VENDOR/include" "$VENDOR/Swift" "$VENDOR/lib"
mv "$GEN"/*.swift "$VENDOR/Swift/"
mv "$GEN"/*FFI.h "$VENDOR/include/"
# Alle Modulemaps zu einer module.modulemap zusammenführen (wie im Repo-Skript).
for f in "$GEN"/*.modulemap; do cat "$f"; echo; done > "$VENDOR/include/module.modulemap"

# 4. Universelle Bibliothek, Debug-Symbole entfernen.
lipo -create "$OUT/lib$LIB_NAME-aarch64.a" "$OUT/lib$LIB_NAME-x86_64.a" \
  -output "$VENDOR/lib/lib$LIB_NAME.a"
strip -S "$VENDOR/lib/lib$LIB_NAME.a"
echo "$MATRIX_SDK_TAG" > "$VENDOR/VERSION"

say "Größen:"
ls -lh "$OUT/lib$LIB_NAME-aarch64.a" "$OUT/lib$LIB_NAME-x86_64.a" \
  "$VENDOR/lib/lib$LIB_NAME.a" "$VENDOR"/Swift/*.swift | awk '{print $5, $9}'
du -sh "$VENDOR"

if [ "$KEEP" -eq 0 ]; then
  rm -rf "$BUILD"
  say "mac/.matrix-build entfernt (--keep behält es)."
fi
say "Fertig: $VENDOR"

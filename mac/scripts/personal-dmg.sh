#!/bin/sh
# DMG nur für diesen Mac: signiert mit dem lokalen Zertifikat "Taby Local
# Signing" (scripts/setup-signing.sh), damit Schlüsselbund- und Datenschutz-
# Freigaben über Updates erhalten bleiben. Für Freunde: scripts/release.sh.
#   mac/scripts/personal-dmg.sh → mac/build/Lumi-persoenlich.dmg
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh
STAGE=build/dmg-personal
rm -rf "$STAGE" build/Lumi-persoenlich.dmg
mkdir -p "$STAGE"
cp -R build/Lumi.app "$STAGE/Lumi.app"
ln -s /Applications "$STAGE/Programme"
hdiutil create -volname "Lumi" -srcfolder "$STAGE" -ov -format UDZO build/Lumi-persoenlich.dmg >/dev/null
rm -rf "$STAGE"
echo "fertig: $(pwd)/build/Lumi-persoenlich.dmg ($(du -h build/Lumi-persoenlich.dmg | cut -f1))"

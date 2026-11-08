#!/bin/bash
# Baut eine unsignierte .ipa für das Apple TV (zum eigenen Neusignieren). Ergebnis: build-ipa/HomeRollTV.ipa
# Hinweis: SideStore/AltStore unterstützen das Apple TV nicht – siehe README „Install without a Mac“.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
rm -rf build-ipa
xcodebuild -project HomeRollTV.xcodeproj -scheme HomeRollTV -configuration Release \
  -sdk appletvos -destination 'generic/platform=tvOS' -derivedDataPath build-ipa \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=." OTHER_CFLAGS="-ffile-prefix-map=$PWD=." \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES STRIP_STYLE=non-global -quiet build
APP="build-ipa/Build/Products/Release-appletvos/HomeRollTV.app"
[ -d "$APP" ] || { echo "FEHLER: $APP nicht gefunden"; exit 1; }
rm -rf Payload; mkdir Payload; cp -R "$APP" Payload/
# Ad-hoc mit Berechtigungen signieren: Signierwerkzeuge lesen daraus die App-Gruppe (Top-Shelf-Erweiterung)
P=Payload/HomeRollTV.app
codesign -f -s - --entitlements TopShelf/HomeRollTVTopShelf.entitlements "$P/PlugIns/HomeRollTVTopShelf.appex"
codesign -f -s - --entitlements App/HomeRollTV.entitlements "$P"
# Keine Spuren des Bau-Rechners veröffentlichen (Baupfade enthalten sonst den Mac-Benutzernamen)
if grep -raqiF -e "$USER" -e "$HOME" Payload; then
  echo "FEHLER: Benutzername oder Home-Pfad in der App – aus einem neutralen Ordner bauen (z. B. git clone nach /tmp/build)."
  rm -rf Payload; exit 1
fi
zip -qr build-ipa/HomeRollTV.ipa Payload; rm -rf Payload
echo "Fertig: build-ipa/HomeRollTV.ipa"

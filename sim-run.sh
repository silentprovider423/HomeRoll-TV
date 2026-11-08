#!/bin/bash
# Baut HomeRoll TV und startet es im eigenen Apple-TV-Simulator, angemeldet per Token (kein Tippen mit der Fernbedienung).
# Gerät einmalig anlegen und die UDID in .sim-udid ablegen (gitignored):
#   xcrun simctl create "HomeRoll TV Test" com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K com.apple.CoreSimulator.SimRuntime.tvOS-26-2 > .sim-udid
# Aufruf: FOTOS_SERVER=http://<server>:2283 FOTOS_TOKEN_FILE=~/.homeroll-token ./sim-run.sh
set -euo pipefail
cd "$(dirname "$0")"
UDID="${SIM_UDID:-$(cat .sim-udid)}"
xcodegen generate -q
xcodebuild -project HomeRollTV.xcodeproj -scheme HomeRollTV -sdk appletvsimulator \
  -destination "id=$UDID" -derivedDataPath build -quiet build 2>&1 | grep -E "error:" || true
APP=build/Build/Products/Debug-appletvsimulator/HomeRollTV.app
test -d "$APP"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
SIMCTL_CHILD_FOTOS_SERVER="${FOTOS_SERVER:?FOTOS_SERVER fehlt, z. B. http://192.168.1.10:2283}" \
SIMCTL_CHILD_FOTOS_TOKEN="$(cat "${FOTOS_TOKEN_FILE:?Token-Datei fehlt}")" \
  xcrun simctl launch --terminate-running-process "$UDID" org.homeroll.tv ${LAUNCH_ARGS:-} >/dev/null
echo "gestartet auf $UDID"

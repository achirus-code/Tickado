#!/bin/bash
# Baut Tickado.app (Release) im Projektordner.
set -euo pipefail
cd "$(dirname "$0")"

# App-Icon einmalig erzeugen
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift Scripts/make-icon.swift Resources/AppIcon.icns
fi

swift build -c release
APP=Tickado.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tickado "$APP/Contents/MacOS/Tickado"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Fertig: $(pwd)/$APP"

# Mit "./build.sh install" nach /Applications installieren und starten
if [[ "${1:-}" == "install" ]]; then
    pkill -x Tickado || true
    rm -rf "/Applications/$APP"
    ditto "$APP" "/Applications/$APP"
    echo "Installiert: /Applications/$APP"
    open "/Applications/$APP"
fi

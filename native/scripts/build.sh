#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT/build/Bandeja PDF.app"
RUNTIME="${BPDF_GS_RUNTIME:?Define BPDF_GS_RUNTIME con el runtime privado de Ghostscript para desarrollo}"
[ -x "$RUNTIME/bin/gs" ] || { echo 'Falta Ghostscript en el runtime indicado.' >&2; exit 1; }
cd "$PROJECT"
swift build --configuration release --arch arm64
BIN="$(swift build --configuration release --arch arm64 --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/BandejaPDF" "$APP/Contents/MacOS/BandejaPDF"
cp "$BIN/BandejaAgent" "$APP/Contents/Helpers/BandejaAgent"
cp "$BIN/BandejaCLI" "$APP/Contents/Helpers/BandejaCLI"
cp Resources/BandejaPDF.ppd "$APP/Contents/Resources/BandejaPDF.ppd"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/bin/ditto "$RUNTIME" "$APP/Contents/Resources/ghostscript"
# Local development signature, not a Developer ID distribution signature.
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/cupstestppd -q "$APP/Contents/Resources/BandejaPDF.ppd"
printf '%s\n' "$APP"

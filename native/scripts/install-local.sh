#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Install only this local development build. Existing queues are never replaced.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$PROJECT/build/Bandeja PDF.app"
DEST="$HOME/Applications/Bandeja PDF.app"
PLIST="$HOME/Library/LaunchAgents/local.bandejapdf.agent.plist"
STATE="$HOME/Library/Application Support/BandejaPDF"
QUEUE=bandeja_pdf
export CUPS_SERVER=/private/var/run/cupsd
unset LPDEST PRINTER CUPS_USER || true
if /usr/bin/lpstat -p "$QUEUE" >/dev/null 2>&1; then
    echo 'La cola bandeja_pdf ya existe; no se reemplazará.' >&2; exit 1
fi
[ ! -e "$DEST" ] && [ ! -e "$PLIST" ] || { echo 'Ya existe una instalación; no se sobreescribirá.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$SOURCE"
if /usr/sbin/lsof -nP -iTCP:18633 -sTCP:LISTEN >/dev/null; then
    echo 'El puerto de la nueva impresora está ocupado.' >&2; exit 1
fi
DEFAULT_BEFORE=$(/usr/bin/lpstat -d 2>&1 || true)
APP_CREATED=0
PLIST_CREATED=0
SERVICE_STARTED=0
QUEUE_ATTEMPTED=0
COMPLETE=0
rollback() {
    result=$?
    trap - EXIT
    if [ "$COMPLETE" = 0 ]; then
        if [ "$QUEUE_ATTEMPTED" = 1 ] && /usr/bin/lpstat -p "$QUEUE" >/dev/null 2>&1; then
            if [ -n "$(/usr/bin/lpstat -W not-completed -o "$QUEUE" 2>/dev/null)" ]; then
                echo 'Hay trabajos pendientes: se conserva la instalación incompleta para recuperarlos.' >&2
                exit "$result"
            fi
            URI=$(/usr/bin/lpstat -v "$QUEUE" | /usr/bin/sed 's/^[^:]*: //')
            if [ "$URI" != 'ipp://localhost:18633/ipp/print' ]; then
                echo 'La cola cambió; se conserva la instalación para inspección.' >&2
                exit "$result"
            fi
            /usr/sbin/lpadmin -x "$QUEUE" || exit "$result"
        fi
        if [ "$SERVICE_STARTED" = 1 ]; then
            /bin/launchctl bootout "gui/$(id -u)/local.bandejapdf.agent" || true
        fi
        [ "$PLIST_CREATED" = 0 ] || /bin/rm -f "$PLIST"
        [ "$APP_CREATED" = 0 ] || /bin/rm -rf "$DEST"
        echo 'La instalación local se revirtió. Los documentos y registros se conservaron.' >&2
    fi
    exit "$result"
}
trap rollback EXIT
umask 077
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$STATE/logs"
/usr/bin/ditto "$SOURCE" "$DEST"
APP_CREATED=1
/usr/bin/plutil -create xml1 "$PLIST"
PLIST_CREATED=1
/usr/bin/plutil -insert Label -string local.bandejapdf.agent "$PLIST"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$DEST/Contents/Helpers/BandejaAgent" "$PLIST"
/usr/bin/plutil -insert ProgramArguments.1 -string --bundle "$PLIST"
/usr/bin/plutil -insert ProgramArguments.2 -string "$DEST" "$PLIST"
/usr/bin/plutil -insert MachServices -json '{"local.bandejapdf.agent":true}' "$PLIST"
/usr/bin/plutil -insert RunAtLoad -bool YES "$PLIST"
/usr/bin/plutil -insert KeepAlive -bool YES "$PLIST"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$PLIST"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$STATE/logs/agent.log" "$PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$STATE/logs/agent.log" "$PLIST"
chmod 600 "$PLIST"
/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"
SERVICE_STARTED=1
# No printer is created until the real agent answers and the receiver is listening.
READY=0
for i in {1..50}; do
    if /usr/sbin/lsof -nP -iTCP:18633 -sTCP:LISTEN >/dev/null 2>&1; then READY=1; break; fi
    sleep 0.2
done
[ "$READY" = 1 ] || { echo 'No arrancó el receptor; consulta el registro del agente. No se creó la cola.' >&2; exit 1; }
"$DEST/Contents/Helpers/BandejaCLI" snapshot
QUEUE_ATTEMPTED=1
/usr/sbin/lpadmin -p "$QUEUE" -v ipp://localhost:18633/ipp/print \
    -P "$DEST/Contents/Resources/BandejaPDF.ppd" -D 'Bandeja PDF' -L 'Este Mac' \
    -o printer-is-shared=false -o printer-error-policy=stop-printer -o job-sheets-default=none,none
/usr/sbin/cupsenable "$QUEUE"
/usr/sbin/cupsaccept "$QUEUE"
[ "$(/usr/bin/lpstat -d 2>&1 || true)" = "$DEFAULT_BEFORE" ] || { echo 'Cambió el destino predeterminado; revisar.' >&2; exit 1; }
/usr/bin/lpstat -p "$QUEUE" -v "$QUEUE"
COMPLETE=1
printf '%s\n' 'Instalación local lista. La interfaz se abre por separado; el agente queda disponible al iniciar sesión.'

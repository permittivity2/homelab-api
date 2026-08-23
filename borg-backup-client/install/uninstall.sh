#!/usr/bin/env bash
# Stops/disables units and removes installed files. Leaves
# /etc/homelab/borgbackup/config.yml (and its SSH key) in place unless
# --purge is passed. Must be run as root.
set -euo pipefail

ETC_DIR=/etc/homelab/borgbackup
BIN_DEST=/usr/local/sbin/homelab-borgbackup
UNIT_DIR=/etc/systemd/system

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { echo "[uninstall] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "[uninstall] ERROR: must be run as root" >&2
    exit 1
fi

log "stopping and disabling units"
systemctl disable --now homelab-borgbackup.service >/dev/null 2>&1 || true
systemctl disable --now homelab-borgbackup.timer >/dev/null 2>&1 || true
systemctl disable --now homelab-borgbackup-check.service >/dev/null 2>&1 || true
systemctl disable --now homelab-borgbackup-check.timer >/dev/null 2>&1 || true
rm -f "$UNIT_DIR/homelab-borgbackup.service" "$UNIT_DIR/homelab-borgbackup.timer" \
      "$UNIT_DIR/homelab-borgbackup-check.service" "$UNIT_DIR/homelab-borgbackup-check.timer"
systemctl daemon-reload

log "removing $BIN_DEST"
rm -f "$BIN_DEST"

if [ "$PURGE" -eq 1 ]; then
    log "purging $ETC_DIR (config, SSH key, and all)"
    rm -rf "$ETC_DIR"
else
    log "leaving $ETC_DIR in place (pass --purge to remove config/SSH key too)"
fi

log "uninstall complete"

#!/usr/bin/env bash
# Registers one role's SCRAM secret (from homelab-database's
# bootstrap-app-role.sh) into pgbouncer's userlist.txt, so it can
# authenticate through the pooler. Never uses a stored/network admin
# credential -- always root/OS-level auth, local or over SSH:
#
#   1. Local (--pgbouncer-host is this host): edit userlist.txt + reload
#      directly, as root.
#   2. Remote + SSH trust works: the identical action, piped through
#      `ssh <pgbouncer-host> ...` instead of a local shell.
#   3. Neither works: the exact userlist.txt line and reload command are
#      printed for a human to run by hand.
#
# Usage: bootstrap-pgbouncer-entry.sh --role NAME --scram-secret SECRET \
#            --pgbouncer-host HOST [--userlist PATH]
set -euo pipefail

ROLE=""
SCRAM_SECRET=""
PGBOUNCER_HOST=""
USERLIST=/etc/pgbouncer/userlist.txt

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

log()  { echo "[bootstrap-pgbouncer-entry] $*" >&2; }
warn() { echo "[bootstrap-pgbouncer-entry] WARNING: $*" >&2; }
die()  { echo "[bootstrap-pgbouncer-entry] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --scram-secret) SCRAM_SECRET="$2"; shift 2 ;;
        --pgbouncer-host) PGBOUNCER_HOST="$2"; shift 2 ;;
        --userlist) USERLIST="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$ROLE" ] || die "--role is required"
[ -n "$SCRAM_SECRET" ] || die "--scram-secret is required"
[ -n "$PGBOUNCER_HOST" ] || die "--pgbouncer-host is required"

is_local_host() {
    local host=$1
    case "$host" in
        localhost|127.0.0.1|::1) return 0 ;;
    esac
    [ "$host" = "$(hostname)" ] && return 0
    [ "$host" = "$(hostname -f 2>/dev/null || true)" ] && return 0
    return 1
}

# Idempotently add-or-replace the "role" "secret" line in userlist.txt,
# reading the current file from stdin and writing the result to stdout,
# so the same logic works unmodified whether it runs locally (redirected
# to/from real files) or remotely (piped through ssh).
update_userlist() {
    local role=$1 secret=$2
    awk -v role="\"$role\"" -v line="\"$role\" \"$secret\"" '
        $1 == role { print line; found = 1; next }
        { print }
        END { if (!found) print line }
    '
}

run_local() {
    log "registering '$ROLE' locally in $USERLIST"
    [ -f "$USERLIST" ] || : > "$USERLIST"
    local tmp
    tmp=$(mktemp)
    update_userlist "$ROLE" "$SCRAM_SECRET" < "$USERLIST" > "$tmp"
    cat "$tmp" > "$USERLIST"
    rm -f "$tmp"
    chmod 640 "$USERLIST"
    systemctl reload pgbouncer || warn "reload failed -- check 'systemctl status pgbouncer' by hand"
}

run_remote() {
    log "registering '$ROLE' on $PGBOUNCER_HOST via SSH"
    # Positional args ($1/$2/$3) rather than interpolating ROLE/secret
    # into the heredoc text itself -- the secret contains $/:/= characters
    # that would otherwise need fragile escaping to survive both the
    # local->ssh and ssh->remote-shell quoting boundaries.
    ssh "${SSH_OPTS[@]}" "$PGBOUNCER_HOST" \
        "sudo bash -s -- $(printf '%q' "$ROLE") $(printf '%q' "$SCRAM_SECRET") $(printf '%q' "$USERLIST")" <<'REMOTE'
set -e
ROLE="$1"
SECRET="$2"
USERLIST="$3"
[ -f "$USERLIST" ] || : > "$USERLIST"
TMP=$(mktemp)
awk -v role="\"$ROLE\"" -v line="\"$ROLE\" \"$SECRET\"" '
    $1 == role { print line; found = 1; next }
    { print }
    END { if (!found) print line }
' "$USERLIST" > "$TMP"
cat "$TMP" > "$USERLIST"
rm -f "$TMP"
chmod 640 "$USERLIST"
systemctl reload pgbouncer
REMOTE
}

ssh_trust_works() {
    ssh "${SSH_OPTS[@]}" "$PGBOUNCER_HOST" true >/dev/null 2>&1
}

run_manual() {
    warn "cannot register '$ROLE' automatically (not local, and no SSH trust to $PGBOUNCER_HOST)"
    {
        echo
        echo "  On $PGBOUNCER_HOST, have an administrator add this line to $USERLIST"
        echo "  (replacing any existing line for the same role), then reload:"
        echo
        echo "    \"$ROLE\" \"$SCRAM_SECRET\""
        echo
        echo "    sudo systemctl reload pgbouncer"
        echo
    } >&2

    local retry_choice
    while true; do
        if ! read -r -p "Press Enter once that's been done (or 's' to skip): " retry_choice; then
            warn "no input available; skipping"
            return 1
        fi
        case "$retry_choice" in
            s|S) warn "skipping; re-run bootstrap-pgbouncer-entry.sh later to retry"; return 1 ;;
            *) return 0 ;;
        esac
    done
}

main() {
    if is_local_host "$PGBOUNCER_HOST"; then
        run_local || die "local registration failed"
    elif ssh_trust_works; then
        run_remote || die "remote registration over SSH failed"
    else
        run_manual || die "registration skipped"
    fi
    log "done"
}

main

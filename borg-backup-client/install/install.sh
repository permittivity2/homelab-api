#!/usr/bin/env bash
# Installs the homelab-borg-service-backup-client: dependencies, config
# skeleton, SSH trust to borgbackup_server, script, and systemd units.
# Must be run as root. Interactive.
#
# Usage: install.sh [--passphrase-file FILE] [--skip-packages] [--skip-binary]
#   --passphrase-file FILE   Use the passphrase in FILE instead of
#                            auto-generating one. Only consulted on first
#                            install (an existing config.yml is never
#                            overwritten).
#   --skip-packages          Don't apt-install dependencies (used when a
#                            Debian package already declared them).
#   --skip-binary            Don't copy bin/homelab-borg-service-backup-client
#                            into place (used when a Debian package
#                            already put it in $PATH). Systemd units are
#                            still generated/enabled either way.
#
# This script runs in two contexts: a plain git checkout (REPO_ROOT is
# this script's own parent directory: install/, config/, systemd/, bin/
# as siblings) or a Debian package install, invoked as
# `homelab-borg-service-backup-client setup` (REPO_ROOT is the package's
# shared data directory, laid out identically). Detected automatically
# below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGED_DATA_DIR=/usr/share/homelab-borg-service-backup-client
if [ -d "$SCRIPT_DIR/../config" ] && [ -d "$SCRIPT_DIR/../systemd" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    REPO_ROOT="$PACKAGED_DATA_DIR"
fi
CONFIGEDIT="$REPO_ROOT/install/configedit.py"

ETC_DIR=/etc/homelab/borgbackup
CONFIG=$ETC_DIR/config.yml
SSH_DIR=$ETC_DIR/ssh
SSH_KEY=$SSH_DIR/id_ed25519
KEY_ESCROW_DIR=$ETC_DIR/key-escrow
if [ -x /usr/sbin/homelab-borg-service-backup-client ]; then
    BIN_DEST=/usr/sbin/homelab-borg-service-backup-client   # already installed by the .deb
else
    BIN_DEST=/usr/local/sbin/homelab-borg-service-backup-client
fi
UNIT_DIR=/etc/systemd/system

# Set by prompt_config_values() when a new passphrase was generated this
# run, so print_summary() can surface it once. Empty if config.yml
# already had a passphrase (nothing new to escrow).
GENERATED_PASSPHRASE=""

PASSPHRASE_FILE=""
SKIP_PACKAGES=0
SKIP_BINARY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --passphrase-file)
            PASSPHRASE_FILE="$2"
            shift 2
            ;;
        --skip-packages)
            SKIP_PACKAGES=1
            shift
            ;;
        --skip-binary)
            SKIP_BINARY=1
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

cfg_get() { python3 "$CONFIGEDIT" get "$CONFIG" "$1"; }
cfg_get_list() { python3 "$CONFIGEDIT" get-list "$CONFIG" "$1"; }
cfg_set() { python3 "$CONFIGEDIT" set-scalar "$CONFIG" "$1" "$2"; }
cfg_set_list() { local key=$1; shift; python3 "$CONFIGEDIT" set-list "$CONFIG" "$key" "$@"; }
cfg_set_databases() { local key=$1; shift; python3 "$CONFIGEDIT" set-databases "$CONFIG" "$key" "$@"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "must be run as root"
    fi
}

install_packages() {
    if [ "$SKIP_PACKAGES" -eq 1 ]; then
        log "skipping package install (--skip-packages)"
        if ! command -v borg >/dev/null 2>&1; then
            die "borg command not available; --skip-packages assumes a Debian package already declared this dependency"
        fi
        return
    fi

    log "checking required packages"
    local pkgs=()
    dpkg -s borgbackup >/dev/null 2>&1 || pkgs+=(borgbackup)
    dpkg -s python3-yaml >/dev/null 2>&1 || pkgs+=(python3-yaml)
    dpkg -s python3-systemd >/dev/null 2>&1 || pkgs+=(python3-systemd)
    dpkg -s openssh-client >/dev/null 2>&1 || pkgs+=(openssh-client)
    dpkg -s postgresql-client >/dev/null 2>&1 || pkgs+=(postgresql-client)

    if [ "${#pkgs[@]}" -gt 0 ]; then
        log "installing: ${pkgs[*]} (this can take a minute on a fresh host)"
        # DEBIAN_FRONTEND avoids a hung debconf prompt; NEEDRESTART_MODE=a
        # skips needrestart's interactive "which services to restart?"
        # dialog (default on Ubuntu 22.04+) — both can otherwise sit
        # silently waiting for input with no visible output at all,
        # which looks exactly like a hang.
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        apt-get update -qq
        apt-get install -y "${pkgs[@]}"
        log "package install finished"
    else
        log "all required packages already installed"
    fi

    if ! command -v borg >/dev/null 2>&1; then
        die "borg command not available after install; is borgbackup available via apt on this host?"
    fi
}

setup_config_skeleton() {
    mkdir -p "$ETC_DIR"
    chmod 700 "$ETC_DIR"
    if [ ! -f "$CONFIG" ]; then
        log "creating $CONFIG from example"
        cp "$REPO_ROOT/config/config.example.yml" "$CONFIG"
    else
        log "$CONFIG already exists, leaving as-is"
    fi
    chmod 600 "$CONFIG"
    chown root:root "$CONFIG"
}

prompt_if_blank() {
    # prompt_if_blank <dotted.key> <prompt text> <default>
    local key=$1 prompt=$2 default=${3:-}
    local current
    current=$(cfg_get "$key")
    if [ -n "$current" ]; then
        return
    fi
    local answer
    read -r -p "$prompt${default:+ [$default]}: " answer
    answer=${answer:-$default}
    if [ -n "$answer" ]; then
        cfg_set "$key" "$answer"
    fi
}

prompt_config_values() {
    prompt_if_blank borgbackup_server "Address of the centralized borgbackup_server" ""
    [ -n "$(cfg_get borgbackup_server)" ] || die "borgbackup_server is required"

    if [ -z "$(cfg_get encryption.passphrase)" ]; then
        local passphrase
        if [ -n "$PASSPHRASE_FILE" ]; then
            log "reading encryption passphrase from $PASSPHRASE_FILE"
            passphrase=$(cat "$PASSPHRASE_FILE")
            [ -n "$passphrase" ] || die "$PASSPHRASE_FILE is empty"
        else
            # Auto-generated: a per-host unique passphrase beats an
            # admin-chosen one (no reuse across hosts, no weak human
            # passphrases), and it's exported below along with the borg
            # key so it can be escrowed as one unit.
            log "generating a random per-host encryption passphrase"
            passphrase=$(openssl rand -base64 32)
        fi
        cfg_set encryption.passphrase "$passphrase"
        GENERATED_PASSPHRASE="$passphrase"
    fi

    local current_mode
    current_mode=$(cfg_get mode)
    echo "Backup mode (current: ${current_mode:-full_host}):"
    echo "  1) full_host    - everything on the host"
    echo "  2) local_only   - everything except network/virtual mounts"
    echo "  3) homelab_only - homelab app configs + DB dumps only"
    echo "  4) specific     - only paths listed in specific.paths"
    read -r -p "Choose [1-4, blank = keep current]: " mode_choice
    case "$mode_choice" in
        1) cfg_set mode full_host ;;
        2) cfg_set mode local_only ;;
        3) cfg_set mode homelab_only ;;
        4) cfg_set mode specific ;;
        "") ;;
        *) warn "unrecognized choice, keeping current mode" ;;
    esac

    local final_mode
    final_mode=$(cfg_get mode)

    if [ "$final_mode" = "homelab_only" ]; then
        populate_homelab_defaults
    elif [ "$final_mode" = "specific" ]; then
        warn "mode is specific: edit $CONFIG's specific.paths list before the first run"
    fi

    local current_sched
    current_sched=$(cfg_get schedule.mode)
    echo "Schedule (current: ${current_sched:-daily}):"
    echo "  1) hourly"
    echo "  2) daily"
    echo "  3) weekly"
    echo "  4) monthly"
    echo "  5) calendar   - custom systemd OnCalendar= expression"
    echo "  6) continuous - back-to-back runs, no timer"
    read -r -p "Choose [1-6, blank = keep current]: " sched_choice
    case "$sched_choice" in
        1) cfg_set schedule.mode hourly ;;
        2) cfg_set schedule.mode daily ;;
        3) cfg_set schedule.mode weekly ;;
        4) cfg_set schedule.mode monthly ;;
        5)
            cfg_set schedule.mode calendar
            read -r -p "systemd OnCalendar= expression (see man systemd.time): " cal_expr
            cfg_set schedule.calendar "$cal_expr"
            ;;
        6) cfg_set schedule.mode continuous ;;
        "") ;;
        *) warn "unrecognized choice, keeping current schedule" ;;
    esac

    prompt_database_values
}

# Optional: record one row per backup/check run to PostgreSQL, for a
# later homelab-api/homelab-cli phase to read back out (that read side
# doesn't exist yet). Off by default. database.enabled is only ever set
# to true once bootstrap_database() actually succeeds -- see below --
# so this function's three states are: never attempted (fresh prompt),
# succeeded (database.enabled true, no-op re-run), or attempted-but-not-
# yet-successful (database.host set, enabled still false -- offer to
# retry with the saved settings instead of silently doing nothing or
# re-asking for everything from scratch).
prompt_database_values() {
    local current_enabled current_host
    current_enabled=$(cfg_get database.enabled)
    if [ "$current_enabled" = "true" ]; then
        log "database.enabled already true, leaving database settings as-is"
        return
    fi

    local db_host db_port db_name db_user db_password
    current_host=$(cfg_get database.host)
    if [ -n "$current_host" ]; then
        warn "a previous database setup did not complete (saved host: $current_host)"
        local resume_choice
        read -r -p "Retry with saved settings [r], reconfigure from scratch [c], or skip for now [s]? [r/c/s]: " resume_choice
        case "$resume_choice" in
            c|C)
                ;;  # fall through to the fresh prompts below
            s|S)
                log "skipping database setup"
                return
                ;;
            *)
                db_host=$current_host
                db_port=$(cfg_get database.port); db_port=${db_port:-5432}
                db_name=$(cfg_get database.dbname); db_name=${db_name:-homelab}
                db_user=$(cfg_get database.user)
                read -r -s -p "Database password (for $db_user@$db_host): " db_password; echo
                install_psycopg2_if_needed
                if retry_bootstrap_database "$db_host" "$db_port" "$db_name" "$db_user" "$db_password"; then
                    cfg_set database.enabled true
                fi
                return
                ;;
        esac
    fi

    local use_db
    read -r -p "Record backup run history to a PostgreSQL database, for future homelab-api/homelab-cli visibility? [y/N]: " use_db
    case "$use_db" in
        y|Y|yes|YES) ;;
        *)
            log "skipping database setup"
            return
            ;;
    esac

    read -r -p "Database host: " db_host
    [ -n "$db_host" ] || die "database host is required"
    read -r -p "Database port [5432]: " db_port
    db_port=${db_port:-5432}
    read -r -p "Database name [homelab]: " db_name
    db_name=${db_name:-homelab}
    read -r -p "Database user: " db_user
    [ -n "$db_user" ] || die "database user is required"
    read -r -s -p "Database password: " db_password; echo

    # Saved as soon as entered (even before the connection is verified)
    # so a failed/skipped attempt can be retried above without re-typing
    # everything. database.enabled itself is only set on success below.
    cfg_set database.host "$db_host"
    cfg_set database.port "$db_port"
    cfg_set database.dbname "$db_name"
    cfg_set database.user "$db_user"
    cfg_set database.password "$db_password"

    install_psycopg2_if_needed

    if retry_bootstrap_database "$db_host" "$db_port" "$db_name" "$db_user" "$db_password"; then
        cfg_set database.enabled true
    fi
}

install_psycopg2_if_needed() {
    log "installing python3-psycopg2 (needed for run-tracking inserts)"
    if ! dpkg -s python3-psycopg2 >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y python3-psycopg2
    fi
}

# Retries bootstrap_database() until it succeeds or the admin chooses to
# skip. No hard attempt limit -- fixing a typo'd hostname or a firewall
# rule mid-flow shouldn't get cut off arbitrarily; 's'/'n' is the exit
# hatch, and NOT enabling the database never blocks the rest of
# `configure` (SSH trust, systemd units, etc. all still run).
retry_bootstrap_database() {
    local db_host=$1 db_port=$2 db_name=$3 db_user=$4 db_password=$5

    while true; do
        if bootstrap_database "$db_host" "$db_port" "$db_name" "$db_user" "$db_password"; then
            return 0
        fi

        local retry_choice
        # If stdin is exhausted/non-interactive, `read` fails (EOF) rather
        # than blocking -- treat that as "skip", not "silently loop
        # forever retrying with no way to provide new input".
        if ! read -r -p "Retry database connection? [Y/n, or 's' to skip database setup]: " retry_choice; then
            warn "no input available; skipping database setup"
            return 1
        fi
        case "$retry_choice" in
            n|N|s|S)
                warn "skipping database setup; re-run 'homelab-borg-service-backup-client setup' later to retry"
                return 1
                ;;
            *)
                ;;  # loop and try again
        esac
    done
}

# Creates the database (if missing) and applies install/schema.sql.
# Idempotent -- CREATE SCHEMA/TABLE IF NOT EXISTS throughout -- so safe
# to re-run on every install.sh/configure invocation. Returns non-zero
# on failure rather than calling die() -- a database problem must never
# kill the rest of `configure` (see retry_bootstrap_database()).
bootstrap_database() {
    local db_host=$1 db_port=$2 db_name=$3 db_user=$4 db_password=$5

    log "checking for database '$db_name' on $db_host:$db_port"
    local exists
    # -X: ignore any ~/.psqlrc for this (or any) user. A startup file
    # that runs its own SET/other commands (e.g. a shared admin
    # workstation's `SET search_path ...`) would otherwise print extra
    # lines ahead of -tAc's actual output and corrupt this exists check.
    if ! exists=$(PGPASSWORD="$db_password" psql -X -h "$db_host" -p "$db_port" -U "$db_user" -d postgres \
            -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>&1); then
        warn "could not connect to PostgreSQL at $db_host:$db_port as $db_user:"
        warn "$exists"
        return 1
    fi

    if [ "$exists" != "1" ]; then
        log "creating database '$db_name'"
        if ! PGPASSWORD="$db_password" createdb -h "$db_host" -p "$db_port" -U "$db_user" "$db_name"; then
            warn "failed to create database '$db_name'"
            return 1
        fi
    else
        log "database '$db_name' already exists"
    fi

    log "applying schema to '$db_name'"
    if ! PGPASSWORD="$db_password" psql -X -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
            -v ON_ERROR_STOP=1 -f "$REPO_ROOT/install/schema.sql"; then
        warn "failed to apply install/schema.sql to '$db_name'"
        return 1
    fi

    log "database ready: service_backup schema in '$db_name'"
    return 0
}

populate_homelab_defaults() {
    local current_paths
    current_paths=$(cfg_get homelab_only.paths)
    if [ -n "$current_paths" ]; then
        log "homelab_only.paths already set, leaving as-is"
        return
    fi

    log "detecting installed homelab-* packages for default backup paths"
    local paths=()
    local have_api=0 have_processor=0
    if dpkg -s homelab-api >/dev/null 2>&1; then
        paths+=("/etc/homelab/api"); have_api=1
    fi
    if dpkg -s homelab-api-backend-processor >/dev/null 2>&1; then
        paths+=("/etc/homelab/processor"); have_processor=1
    fi
    if dpkg -s homelab-drive-web-ui >/dev/null 2>&1; then
        paths+=("/etc/homelab/drive-web-ui")
    fi
    if dpkg -s homelab-sso-ui >/dev/null 2>&1; then
        paths+=("/etc/homelab/sso-ui")
    fi

    if [ "${#paths[@]}" -eq 0 ]; then
        warn "no known homelab-* packages detected; leaving homelab_only.paths empty, edit $CONFIG manually"
        return
    fi

    log "detected homelab paths: ${paths[*]}"
    cfg_set_list homelab_only.paths "${paths[@]}"

    if [ "$have_api" -eq 1 ] || [ "$have_processor" -eq 1 ]; then
        log "detected homelab-api/processor, defaulting to dumping the 'mailserver' database"
        cfg_set_databases homelab_only.databases "postgres:mailserver:/var/lib/homelab-borg-service-backup-client/dumps"
    fi
}

# Onboarding a client no longer involves the client SSHing into the
# server at all -- the client only ever needs to know whether its own
# dedicated key already works. Trust is established by whoever
# administers the backup server running
# `homelab-borg-service-backup-server enroll` there directly (see the
# homelab-borg-service-backup-server package); this client never holds
# or uses server-side admin/sudo credentials.
setup_ssh_trust() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    local identifier
    identifier=$(cfg_get hostname)
    if [ -z "$identifier" ]; then
        if [ ! -r /etc/machine-id ]; then
            die "/etc/machine-id not readable and no hostname override set; cannot derive host identifier"
        fi
        identifier="$(hostname)-$(cat /etc/machine-id)"
    fi
    log "host identifier: $identifier"

    if [ ! -f "$SSH_KEY" ]; then
        log "generating dedicated SSH key at $SSH_KEY"
        ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "homelab-borg-service-backup-client-$identifier" >/dev/null
    fi
    chmod 600 "$SSH_KEY"
    chmod 644 "$SSH_KEY.pub"

    local ssh_user server pubkey
    ssh_user=$(cfg_get ssh_borgbackup_server_username); ssh_user=${ssh_user:-borgbackup}
    server=$(cfg_get borgbackup_server)
    pubkey=$(cat "$SSH_KEY.pub")

    log "checking existing passwordless access to ${ssh_user}@${server}"
    # A successful forced-command connection (borg serve) will still exit
    # non-zero when fed garbage on stdin, so success is "no auth error" —
    # not "exit code 0".
    local probe
    probe=$(echo | ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new "${ssh_user}@${server}" 2>&1) || true
    if ! echo "$probe" | grep -qi "Permission denied"; then
        log "passwordless access already works"
        return
    fi

    warn "SSH trust to ${server} is not yet established"
    echo
    echo "  On ${server}, have an administrator run:"
    echo "    sudo homelab-borg-service-backup-server enroll ${identifier} '${pubkey}'"
    echo

    local retry_choice
    while true; do
        if ! read -r -p "Press Enter to re-check once that's been run (or 's' to skip for now): " retry_choice; then
            warn "no input available; skipping SSH trust check for now"
            return
        fi
        case "$retry_choice" in
            s|S)
                warn "skipping SSH trust check; re-run 'homelab-borg-service-backup-client setup' later to retry"
                return
                ;;
            *)
                ;;
        esac

        probe=$(echo | ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=accept-new "${ssh_user}@${server}" 2>&1) || true
        if ! echo "$probe" | grep -qi "Permission denied"; then
            log "passwordless access confirmed"
            return
        fi
        warn "still no passwordless access to ${server}"
    done
}

install_script_and_units() {
    if [ "$SKIP_BINARY" -eq 1 ]; then
        log "skipping binary install (--skip-binary): using $BIN_DEST"
    else
        log "installing $BIN_DEST"
        install -o root -g root -m 700 "$REPO_ROOT/bin/homelab-borg-service-backup-client" "$BIN_DEST"
    fi

    local sched_mode
    sched_mode=$(cfg_get schedule.mode); sched_mode=${sched_mode:-daily}

    if [ "$sched_mode" = "continuous" ]; then
        log "installing continuous service (no timer)"
        systemctl disable --now homelab-borg-service-backup-client.timer >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/homelab-borg-service-backup-client.timer"
        sed "s|__BIN_PATH__|$BIN_DEST|" \
            "$REPO_ROOT/systemd/homelab-borg-service-backup-client-continuous.service.tmpl" > "$UNIT_DIR/homelab-borg-service-backup-client.service"
        systemctl daemon-reload
        systemctl enable --now homelab-borg-service-backup-client.service
    else
        local on_calendar jitter_seconds
        jitter_seconds=$(cfg_get schedule.jitter_seconds); jitter_seconds=${jitter_seconds:-1800}

        case "$sched_mode" in
            hourly)
                on_calendar="hourly"
                ;;
            daily|weekly|monthly)
                on_calendar=$(build_randomized_calendar "$sched_mode")
                ;;
            calendar)
                on_calendar=$(cfg_get schedule.calendar)
                [ -n "$on_calendar" ] || die "schedule.calendar is empty but schedule.mode is calendar"
                ;;
            *) die "unknown schedule.mode: $sched_mode" ;;
        esac

        log "installing oneshot service + timer (OnCalendar=$on_calendar, RandomizedDelaySec=$jitter_seconds)"
        systemctl disable --now homelab-borg-service-backup-client.service >/dev/null 2>&1 || true
        sed "s|__BIN_PATH__|$BIN_DEST|" \
            "$REPO_ROOT/systemd/homelab-borg-service-backup-client.service.tmpl" > "$UNIT_DIR/homelab-borg-service-backup-client.service"
        sed -e "s|__ON_CALENDAR__|$on_calendar|" -e "s|__JITTER_SECONDS__|$jitter_seconds|" \
            "$REPO_ROOT/systemd/homelab-borg-service-backup-client.timer.tmpl" > "$UNIT_DIR/homelab-borg-service-backup-client.timer"
        systemctl daemon-reload
        systemctl enable --now homelab-borg-service-backup-client.timer
    fi

    install_check_unit
}

# Installs (or removes, if integrity_check.mode is unset/never) the
# separate borg-check timer. Kept independent of the backup schedule
# above since a full repo check is slower and shouldn't block backups.
install_check_unit() {
    local check_mode
    check_mode=$(cfg_get integrity_check.mode); check_mode=${check_mode:-monthly}

    if [ "$check_mode" = "never" ]; then
        log "integrity_check.mode is never, removing any existing check timer"
        systemctl disable --now homelab-borg-service-backup-client-check.timer >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/homelab-borg-service-backup-client-check.service" "$UNIT_DIR/homelab-borg-service-backup-client-check.timer"
        systemctl daemon-reload
        return
    fi

    if [ "$check_mode" != "weekly" ] && [ "$check_mode" != "monthly" ]; then
        warn "unknown integrity_check.mode '$check_mode', defaulting to monthly"
        check_mode="monthly"
    fi

    log "installing integrity check oneshot service + timer (OnCalendar=$check_mode)"
    sed "s|__BIN_PATH__|$BIN_DEST|" \
        "$REPO_ROOT/systemd/homelab-borg-service-backup-client-check.service.tmpl" > "$UNIT_DIR/homelab-borg-service-backup-client-check.service"
    sed "s|__ON_CALENDAR__|$check_mode|" \
        "$REPO_ROOT/systemd/homelab-borg-service-backup-client-check.timer.tmpl" > "$UNIT_DIR/homelab-borg-service-backup-client-check.timer"
    systemctl daemon-reload
    systemctl enable --now homelab-borg-service-backup-client-check.timer
}

# Picks (once, persisted) a random hour from schedule.window_hours and a
# random minute, so a fleet of hosts on the same daily/weekly/monthly
# schedule doesn't all hit borgbackup_server at exactly midnight. Prints
# a systemd OnCalendar= expression for the given mode.
build_randomized_calendar() {
    local mode=$1
    local start_hour start_minute
    start_hour=$(cfg_get schedule.start_hour)
    start_minute=$(cfg_get schedule.start_minute)

    if [ -z "$start_hour" ] || [ -z "$start_minute" ]; then
        local window_hours=()
        while IFS= read -r h; do
            [ -n "$h" ] && window_hours+=("$h")
        done < <(cfg_get_list schedule.window_hours)
        if [ "${#window_hours[@]}" -eq 0 ]; then
            window_hours=(23 0 1 2)
        fi
        start_hour=${window_hours[$((RANDOM % ${#window_hours[@]}))]}
        start_minute=$((RANDOM % 60))
        cfg_set schedule.start_hour "$start_hour"
        cfg_set schedule.start_minute "$start_minute"
        log "picked randomized start time: $(printf '%02d:%02d' "$start_hour" "$start_minute") (persisted in $CONFIG)" >&2
    fi

    local hh mm
    hh=$(printf '%02d' "$start_hour")
    mm=$(printf '%02d' "$start_minute")

    case "$mode" in
        daily)   echo "*-*-* ${hh}:${mm}:00" ;;
        weekly)  echo "Mon *-*-* ${hh}:${mm}:00" ;;
        monthly) echo "*-*-01 ${hh}:${mm}:00" ;;
    esac
}

print_summary() {
    echo
    log "install complete"
    log "config:      $CONFIG"
    log "script:      $BIN_DEST"
    log "mode:        $(cfg_get mode)"
    log "schedule:    $(cfg_get schedule.mode)"
    log "database:    $([ "$(cfg_get database.enabled)" = "true" ] && echo "enabled ($(cfg_get database.dbname))" || echo "disabled")"
    echo
    log "check status with: systemctl status homelab-borg-service-backup-client.service homelab-borg-service-backup-client.timer 2>/dev/null"
    log "check logs with:   journalctl -t homelab-borg-service-backup-client -f"
    log "dry-run a manual test with: $BIN_DEST backup --dry-run --once"

    if [ -n "$GENERATED_PASSPHRASE" ]; then
        echo
        echo "########################################################################"
        echo "# ESCROW THIS NOW — none of the following is backed up anywhere yet.  #"
        echo "########################################################################"
        echo
        echo "  encryption passphrase: $GENERATED_PASSPHRASE"
        echo
        echo "  This passphrase is also saved (mode 600) in:"
        echo "    $CONFIG"
        echo
        echo "  A key export will additionally appear under $KEY_ESCROW_DIR"
        echo "  after the first backup run (see homelab-borg-service-backup-client backup --once)."
        echo
        echo "  Copy the passphrase and the exported key files to a password"
        echo "  manager / secrets vault AND an offline/paper copy before this host"
        echo "  becomes the disaster this tool exists to recover from."
        echo "########################################################################"
    fi
}

main() {
    require_root
    install_packages
    setup_config_skeleton
    prompt_config_values
    setup_ssh_trust
    install_script_and_units
    print_summary
}

main "$@"

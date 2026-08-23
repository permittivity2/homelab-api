# homelab-borg-service-backup

Two packages, one source repo, built on classic **borg** (1.x):

- **`homelab-borg-service-backup-client`** — installed on every host being
  backed up. Pushes encrypted archives to a centralized backup server
  over SSH. Driven entirely by a per-host config in
  `/etc/homelab/borgbackup/` and run under systemd (timer for periodic
  schedules, a long-running service for continuous mode).
- **`homelab-borg-service-backup-server`** — installed once, on the
  centralized backup server. Creates the `borgbackup` system user/group
  and backup directory, and provides `enroll`/`list`/`revoke` to manage
  which clients can reach it. Clients never need SSH or sudo access to
  this host to onboard — an administrator runs `enroll` locally on the
  server using the client's own printed public key.

This tool exists to help an administrator restore a homelab **service's
config** (guaranteed to live under `/etc/homelab/<component>/`) or an
entire server to a point in time after a disaster. It is not a user-data
backup tool.

## Server setup

```
sudo apt install ./homelab-borg-service-backup-server_*.deb
```

This is non-interactive and idempotent (safe to re-run/upgrade). It:

1. Installs `borgbackup` (the `Conflicts: borgbackup2` in
   `debian/control` prevents the v1/v2 binary-name mismatch that used to
   break every client backup with `sh: 1: borg: not found`).
2. Creates the `borgbackup` system user/group (no login shell) if
   missing.
3. Creates the backup directory (default `/var/borgbackup`), owned by
   `borgbackup`.
4. Creates `/etc/homelab/homelab-borg-service-backup-server/config.yml`
   (only if missing) recording `backup_user`/`backup_location` — edit
   this to point at a different path (e.g. an existing deployment still
   using `/mnt/borgbackup`).
5. Creates `~borgbackup/.ssh/authorized_keys`, empty and correctly
   permissioned, ready for `enroll`.

Onboard a client once you have its identifier and public key (both
printed by the client's `configure` step below):

```
sudo homelab-borg-service-backup-server enroll <identifier> '<pubkey>'
```

Also available: `homelab-borg-service-backup-server list` (show enrolled
identifiers) and `... revoke <identifier>` (remove a client's access,
e.g. when decommissioning a host).

## Client install

```
sudo apt install ./homelab-borg-service-backup-client_*.deb
sudo homelab-borgbackup configure
```

(Or, for a non-packaged install: `sudo ./install/install.sh`.)

This is interactive and root-only. It will:

1. Check for/install `borgbackup`, `python3-yaml`, `python3-systemd`,
   `postgresql-client`.
2. Create `/etc/homelab/borgbackup/config.yml` from
   `config/config.example.yml` (only if it doesn't already exist).
3. Prompt for anything required but unset: `borgbackup_server`, backup
   mode, schedule. A per-host encryption passphrase is **generated
   automatically** (see Encryption & key escrow below) — pass
   `--passphrase-file FILE` to supply your own instead.
4. If mode is `homelab_only`, pre-populate `homelab_only.paths`/
   `databases` by detecting installed `homelab-*` packages.
5. Generate a dedicated SSH key (`/etc/homelab/borgbackup/ssh/`). If
   trust to the backup server isn't already established, it prints the
   exact `enroll` command above (with this host's identifier and public
   key filled in) for an administrator to run **on the backup server**,
   then offers to re-check once that's done — no SSH or sudo access to
   the backup server is ever needed from the client side.
6. Install the script to `/usr/local/sbin/homelab-borgbackup` and the
   appropriate systemd unit(s), then enable+start them.
7. Print a one-time summary telling you exactly what to escrow and
   where, if a new passphrase was generated.

Re-run `install.sh` any time to pick up a changed `schedule.mode` (it
regenerates the systemd units) — it will not overwrite an existing
`config.yml` or SSH key.

## Uninstall

```
sudo ./install/uninstall.sh          # stops/removes units + binary, keeps config
sudo ./install/uninstall.sh --purge  # also removes /etc/homelab/borgbackup entirely
```

## Encryption & key escrow

Every repo is created with borg's `repokey` encryption (the key lives
inside the repo itself, so it travels with it wherever the repo is
replicated) protected by a **passphrase unique to that host**, generated
automatically by `install.sh`. Leaving `encryption.passphrase` blank is
a hard error unless `encryption.allow_unencrypted: true` is explicitly
set — silent unencrypted backups are not the default, because
`/etc/homelab/*` configs routinely contain database passwords and API
keys.

On top of the passphrase, the first successful backup run also exports
the repo's key independently via `borg key export` into
`/etc/homelab/borgbackup/key-escrow/<identifier>.key` (plus a
`--paper` printable copy at `<identifier>-paper.txt`). This is a safety
net against repo metadata damage, not a substitute for the passphrase.

**None of this is backed up anywhere off the source host automatically.**
The whole point of this tool is surviving the loss of a host — so before
that happens, copy both the generated passphrase (printed once by
`install.sh`, and stored in `config.yml`) and the exported key files to:

1. A password manager / self-hosted secrets manager, and
2. An offline/paper copy (the `--paper` export is meant to be printed or
   transcribed).

See `admin-recovery-key` below for the SSH-side equivalent of this
problem.

## Restoring onto a fresh/replacement host

Run once, on the backup server (part of the
`homelab-borg-service-backup-server` package, not per client host), to
generate a broader-scoped **admin recovery key**:

```
sudo homelab-borg-service-backup-server admin-recovery-key
```

This key can `list`/`extract` **any** host's repo under
`backup_location` (still restricted to `borg serve`, never an
interactive shell) — it exists so a restore doesn't depend on the very
host key that a disaster may have destroyed along with everything else.
Escrow its private key the same way as passphrases above.

Disaster recovery runbook, once a host is gone and you're rebuilding it
(or restoring to any other machine):

1. Reimage/provision the replacement host, install `borgbackup` and this
   package (`sudo ./install/install.sh`, or the `.deb` — see Packaging
   below). You do **not** need to finish configuring it as a backup
   client to restore from it.
2. Retrieve the escrowed passphrase for the **original** host's repo,
   and the admin recovery key from step above.
3. List what's available:
   ```
   homelab-borgbackup list-archives \
       --host <original-identifier> --server <borgbackup_server> \
       --ssh-key /path/to/admin-recovery/id_ed25519 \
       --passphrase-file /path/to/escrowed-passphrase
   ```
4. Extract into a staging directory (never straight onto `/`):
   ```
   homelab-borgbackup restore \
       --host <original-identifier> --server <borgbackup_server> \
       --ssh-key /path/to/admin-recovery/id_ed25519 \
       --passphrase-file /path/to/escrowed-passphrase \
       --archive <archive-name> --target /var/tmp/restore
   ```
5. Review `/var/tmp/restore` and manually copy what's needed into place
   — a restore is a reviewable staging step, not an automatic overwrite.

`--host`/`--server`/`--ssh-user`/`--location`/`--ssh-key`/
`--passphrase-file` on `list-archives`/`restore` all fall back to the
local `config.yml` when omitted, so restoring a specific file on a
still-alive host (no disaster involved) just needs
`homelab-borgbackup list-archives` / `restore --archive ... --target ...`
with no overrides.

## Run history database (optional)

`install.sh`/`configure` asks whether to record each `backup`/`check`
run to a PostgreSQL database — off by default. If enabled, it:

1. Collects host, port, database name (default `homelab`), user, and
   password, and installs `python3-psycopg2` on demand.
2. Creates the database if it doesn't already exist, then applies
   `install/schema.sql` (idempotent — safe to re-run).
3. From then on, every `backup`/`check` run writes one row recording
   what happened: status, timing, and — for backups, via `borg create
   --json` — real original/compressed/deduplicated size and file count.

Tables live in a dedicated `service_backup` Postgres schema (not
`public`) inside the `homelab` database, so other `homelab-*` packages
sharing that database later don't collide on table names. **This is
write-only for now** — there is no API or CLI to read this data back
out yet; that's an intentionally separate, later phase. A database
error (unreachable host, bad credentials, `psycopg2` missing) only ever
logs a warning — it never fails or blocks an actual backup.

## Config reference

See `config/config.example.yml` for the full documented schema. Key
points:

- **Host identifier**: `hostname` in config, or
  `<system-hostname>-<contents of /etc/machine-id>` if unset. If
  `/etc/machine-id` is unreadable and no override is set, the script
  logs to journald and exits cleanly (exit 0) rather than guessing.
- **mode**: `full_host` | `local_only` | `homelab_only` | `specific`.
  `exclude:` (regex list) applies on top of whichever mode is chosen.
- **schedule.mode**: `hourly` | `daily` | `weekly` | `monthly` |
  `calendar` (raw systemd `OnCalendar=` expression) | `continuous`
  (script loops immediately after each successful run; no timer).
  `daily`/`weekly`/`monthly` don't fire at exact midnight — install.sh
  picks a random hour (from `schedule.window_hours`, default an 11pm-3am
  window: `[23, 0, 1, 2]`) and minute once, persists it into
  `schedule.start_hour`/`start_minute`, and reuses that same time on
  every re-run (clear both to re-roll). On top of that, every
  timer-driven mode (including `hourly`/`calendar`) gets an additional
  `RandomizedDelaySec` from `schedule.jitter_seconds` (default 1800).
  Together this keeps a fleet of hosts from all hitting
  `borgbackup_server` at once.
- **retention**: `borg prune` runs after every successful backup using
  `keep_daily`/`keep_weekly`/`keep_monthly`/`keep_yearly`.
- **encryption.passphrase**: auto-generated per host at install; see
  Encryption & key escrow above. `encryption.allow_unencrypted: true` is
  the (discouraged) escape hatch to back up without a passphrase.
- **integrity_check.mode**: `never` | `weekly` | `monthly` (default).
  Runs `borg check` (read-only, never `--repair`) on its own timer,
  separate from the backup schedule since a full check is slower and
  shouldn't block backups. A corrupted repo is only useful to discover
  before a real disaster recovery attempt needs it.
- **database.enabled**: off by default; see Run history database above.

## Commands

```
homelab-borgbackup backup [--dry-run] [--once] [--config PATH]
homelab-borgbackup check [--config PATH]
homelab-borgbackup list-archives [--host ID] [--server S] [--ssh-user U]
                                  [--location DIR] [--ssh-key PATH]
                                  [--passphrase-file PATH]
homelab-borgbackup restore --archive NAME --target DIR [--paths ...]
                            [--dry-run] [same overrides as list-archives]
```

Running the binary with no subcommand (or one starting with a flag) is
still accepted and behaves as `backup`, for compatibility with older
invocations and the systemd units.

## Manual testing

```
/usr/local/sbin/homelab-borgbackup backup --dry-run --once
journalctl -t homelab-borgbackup -f
```

`--dry-run` prints the resolved sources, exclude patterns, and the exact
`borg create`/`borg prune` commands without executing them. `--once`
forces a single run even when `schedule.mode: continuous`.

## Unit tests

```
sudo apt-get install python3-pytest   # or: pip install pytest
pytest tests/
```

Covers the pure-logic functions of both the client (pattern building per
mode, host identifier resolution, repo URL construction, passphrase
fallback order, the bare-args-means-`backup` command detection) and the
server CLI (identifier validation, `authorized_keys` line construction/
parsing, `enroll`/`revoke` idempotency) with no real `borg`/SSH/network/
filesystem-user calls — the manual dry-run testing above covers
integration-level behavior.

## Packaging

One Debian source package (`debian/`) builds two binary packages —
`homelab-borg-service-backup-client` and `homelab-borg-service-backup-server`
— sharing a single changelog/version. A `build-package.sh` (modeled on
`homelab-api/build-package.sh`) builds both `.deb`s and publishes them to
the same shared apt repository used by the rest of this homelab's
`homelab-*` packages. See `debian/` and `build-package.sh` at the repo
root.

The server package's setup (user/group/directory/config) runs
non-interactively from `postinst` — see Server setup above. The client
package still requires running `homelab-borgbackup configure` (or
`install.sh`, for a non-packaged install) once to set config values and
print the `enroll` command for the server administrator — that step is
interactive and doesn't fit a non-interactive `postinst`.

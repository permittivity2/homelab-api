"""Unit tests for the pure-logic functions in bin/homelab-borg-service-backup-client.

No real borg/SSH/network calls -- the manual dry-run/build verification
done alongside this tool's development already covers integration-level
behavior (see README's Manual testing section).
"""
import types

import pytest

import homelab_borg_service_backup_client as hb


# --- _truthy ---------------------------------------------------------------

@pytest.mark.parametrize("value, expected", [
    (True, True),
    (False, False),
    ("true", True),
    ("True", True),
    ("yes", True),
    ("1", True),
    ("on", True),
    ("false", False),   # the exact regression this helper exists to fix:
    ("False", False),   # configedit.py's set-scalar always quotes values,
    ("no", False),      # so bare bool("false") would otherwise be True.
    ("0", False),
    ("", False),
    (None, False),
])
def test_truthy(value, expected):
    assert hb._truthy(value) is expected


# --- normalize_argv ----------------------------------------------------------

@pytest.mark.parametrize("argv, expected", [
    ([], ["backup"]),
    (["--dry-run"], ["backup", "--dry-run"]),
    (["--dry-run", "--once"], ["backup", "--dry-run", "--once"]),
    (["backup", "--once"], ["backup", "--once"]),
    (["check"], ["check"]),
    (["list-archives", "--host", "x"], ["list-archives", "--host", "x"]),
    (["restore", "--archive", "a"], ["restore", "--archive", "a"]),
    (["configure"], ["configure"]),
    (["-h"], ["-h"]),
    (["--help"], ["--help"]),
])
def test_normalize_argv(argv, expected):
    assert hb.normalize_argv(argv) == expected


# --- build_sources_and_patterns ---------------------------------------------

def test_full_host_mode():
    sources, patterns = hb.build_sources_and_patterns({}, "full_host", [])
    assert sources == ["/"]
    for p in hb.PSEUDO_FS_EXCLUDES:
        assert f"! fm:{p}" in patterns


def test_local_only_mode_excludes_network_and_virtual_mounts(monkeypatch):
    monkeypatch.setattr(hb, "read_mounts", lambda: [
        ("/", "ext4"),
        ("/mnt/nas", "nfs4"),
        ("/data", "ext4"),
        ("/proc", "proc"),
    ])
    sources, patterns = hb.build_sources_and_patterns({}, "local_only", [])
    assert sources == ["/"]
    assert "! fm:/mnt/nas" in patterns
    assert "! fm:/proc" in patterns
    assert "! fm:/data" not in patterns


def test_homelab_only_mode_combines_paths_and_dump_dirs():
    config = {"homelab_only": {"paths": ["/etc/homelab/api"]}}
    sources, _patterns = hb.build_sources_and_patterns(
        config, "homelab_only", ["/var/lib/homelab-borg-service-backup-client/dumps"]
    )
    assert sources == ["/etc/homelab/api", "/var/lib/homelab-borg-service-backup-client/dumps"]


def test_specific_mode_uses_specific_paths():
    config = {"specific": {"paths": ["/etc/foo"]}}
    sources, _patterns = hb.build_sources_and_patterns(config, "specific", [])
    assert sources == ["/etc/foo"]


def test_exclude_applies_on_top_of_any_mode():
    config = {"exclude": [r".*\.cache/.*"]}
    _sources, patterns = hb.build_sources_and_patterns(config, "full_host", [])
    assert r"- re:.*\.cache/.*" in patterns


def test_unknown_mode_exits_with_error():
    with pytest.raises(SystemExit) as exc_info:
        hb.build_sources_and_patterns({}, "bogus", [])
    assert exc_info.value.code == 1


# --- resolve_identifier ------------------------------------------------------

def test_resolve_identifier_prefers_explicit_hostname():
    assert hb.resolve_identifier({"hostname": "myhost"}) == "myhost"


def test_resolve_identifier_falls_back_to_machine_id(monkeypatch, tmp_path):
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    monkeypatch.setattr(hb, "MACHINE_ID_PATH", str(machine_id_file))
    monkeypatch.setattr(hb.socket, "gethostname", lambda: "myserver")
    assert hb.resolve_identifier({}) == "myserver-abc123"


def test_resolve_identifier_exits_cleanly_when_machine_id_unreadable(monkeypatch):
    monkeypatch.setattr(hb, "MACHINE_ID_PATH", "/nonexistent/machine-id")
    with pytest.raises(SystemExit) as exc_info:
        hb.resolve_identifier({})
    assert exc_info.value.code == 0


# --- build_repo_url ----------------------------------------------------------

def test_build_repo_url_doubles_leading_slash_for_absolute_location():
    url = hb.build_repo_url("borgbackup", "backup01", "/mnt/borgbackup", "myhost")
    # location's own leading "/" plus the separator "/" this function adds
    # produces a literal "//" right after the hostname -- borg's own quirk
    # for treating the remote path as absolute rather than home-relative.
    assert url == "ssh://borgbackup@backup01//mnt/borgbackup/myhost"


def test_build_repo_url_errors_without_server():
    with pytest.raises(SystemExit) as exc_info:
        hb.build_repo_url("borgbackup", None, "/mnt/borgbackup", "myhost")
    assert exc_info.value.code == 1


# --- get_passphrase precedence ----------------------------------------------

def _args(**kwargs):
    kwargs.setdefault("passphrase_file", None)
    return types.SimpleNamespace(**kwargs)


def test_get_passphrase_prefers_passphrase_file(tmp_path, monkeypatch):
    pf = tmp_path / "pass.txt"
    pf.write_text("from-file\n")
    monkeypatch.setenv("BORG_PASSPHRASE", "from-env")
    config = {"encryption": {"passphrase": "from-config"}}
    assert hb.get_passphrase(config, _args(passphrase_file=str(pf))) == "from-file"


def test_get_passphrase_falls_back_to_config(monkeypatch):
    monkeypatch.delenv("BORG_PASSPHRASE", raising=False)
    config = {"encryption": {"passphrase": "from-config"}}
    assert hb.get_passphrase(config, _args()) == "from-config"


def test_get_passphrase_falls_back_to_env_var(monkeypatch):
    monkeypatch.setenv("BORG_PASSPHRASE", "from-env")
    assert hb.get_passphrase({}, _args()) == "from-env"


def test_get_passphrase_prompts_interactively_as_last_resort(monkeypatch):
    monkeypatch.delenv("BORG_PASSPHRASE", raising=False)
    monkeypatch.setattr(hb.sys, "stdin", types.SimpleNamespace(isatty=lambda: True))
    monkeypatch.setattr(hb.getpass, "getpass", lambda prompt="": "typed-in")
    assert hb.get_passphrase({}, _args()) == "typed-in"


def test_get_passphrase_errors_when_nothing_available_and_not_a_tty(monkeypatch):
    monkeypatch.delenv("BORG_PASSPHRASE", raising=False)
    monkeypatch.setattr(hb.sys, "stdin", types.SimpleNamespace(isatty=lambda: False))
    with pytest.raises(SystemExit) as exc_info:
        hb.get_passphrase({}, _args())
    assert exc_info.value.code == 1


# --- run_borg_capture_json (run-tracking database stats extraction) --------

def test_run_borg_capture_json_parses_stdout():
    cmd = ["python3", "-c", 'print(\'{"archive": {"name": "n", "stats": {"nfiles": 3}}}\')']
    data = hb.run_borg_capture_json(cmd, dict(hb.os.environ))
    assert data == {"archive": {"name": "n", "stats": {"nfiles": 3}}}


def test_run_borg_capture_json_returns_none_on_invalid_json():
    cmd = ["python3", "-c", "print('not json')"]
    assert hb.run_borg_capture_json(cmd, dict(hb.os.environ)) is None


def test_run_borg_capture_json_raises_on_real_failure():
    cmd = ["python3", "-c", "import sys; sys.exit(2)"]
    with pytest.raises(hb.subprocess.CalledProcessError):
        hb.run_borg_capture_json(cmd, dict(hb.os.environ))


# --- db_connect (disabled/driver-missing paths need no real Postgres) ------

def test_db_connect_returns_none_when_disabled():
    assert hb.db_connect({"database": {"enabled": False}}) is None
    assert hb.db_connect({}) is None


def test_db_connect_returns_none_when_psycopg2_missing(monkeypatch):
    monkeypatch.setattr(hb, "_HAVE_PSYCOPG2", False)
    assert hb.db_connect({"database": {"enabled": True, "host": "x"}}) is None


# --- _db_safe never lets a database error propagate -------------------------

def test_db_safe_catches_exceptions_and_returns_none():
    def boom():
        raise RuntimeError("simulated database error")

    assert hb._db_safe(boom) is None


def test_db_safe_returns_value_on_success():
    assert hb._db_safe(lambda: 42) == 42

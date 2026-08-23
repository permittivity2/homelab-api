"""Loads scripts that have no .py extension (so they aren't importable
the normal way) as modules, before test collection imports them by name."""
import importlib.machinery
import importlib.util
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load(module_name, script_path):
    loader = importlib.machinery.SourceFileLoader(module_name, str(script_path))
    spec = importlib.util.spec_from_loader(module_name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)


_load("homelab_borgbackup", REPO_ROOT / "bin" / "homelab-borgbackup")
_load("homelab_borg_service_backup_server", REPO_ROOT / "server" / "homelab-borg-service-backup-server")

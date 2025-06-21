import json
import subprocess
from typing import Any


def run_lsjson(remote: str, backup_path: str, flags: list[str] | None = None) -> list[dict[str, Any]]:
    """List files in a remote directory in JSON format."""
    if flags is None:
        flags = []
    target = f"{remote}:{backup_path}"
    cmd = ["rclone", "lsjson", *flags, target]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr or f"rclone exit {result.returncode}")
    return json.loads(result.stdout) # type: ignore[no-any-return]


def run_listremotes() -> list[str]:
    """List all configured remotes."""
    result = subprocess.run(["rclone", "listremotes"], check=False, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [r.strip().rstrip(":") for r in result.stdout.splitlines() if r.strip()]

def run_deletefile(remote: str, backup_path: str, filename: str) -> subprocess.CompletedProcess[str]:
    """Delete a specific file from a remote."""
    remote_file = f"{remote}:{backup_path}/{filename}"
    return subprocess.run(["rclone", "deletefile", remote_file], check=False, capture_output=True, text=True)

def run_copyto(remote: str, backup_path: str, filename: str, tmp_path: str) -> subprocess.CompletedProcess[str]:
    """Copy a file from a remote to a temporary path."""
    remote_file = f"{remote}:{backup_path}/{filename}"
    return subprocess.run(["rclone", "copyto", remote_file, tmp_path], check=False, capture_output=True, text=True)

def run_about(remote: str, backup_path: str) -> subprocess.CompletedProcess[str]:
    """Get usage information about a remote."""
    target = f"{remote}:{backup_path}"
    return subprocess.run(["rclone", "about", target, "--json"], check=False, capture_output=True, text=True)

def run_lsf(remote: str, backup_path: str) -> subprocess.CompletedProcess[str]:
    """List files in a remote directory."""
    target = f"{remote}:{backup_path}"
    return subprocess.run(["rclone", "lsf", target], check=False, capture_output=True, text=True)

def run_version() -> subprocess.CompletedProcess[str]:
    """Get the version of rclone."""
    return subprocess.run(["rclone", "version"], check=False, capture_output=True, text=True)

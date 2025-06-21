import base64
import json
import re
import subprocess
import tempfile
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.responses import FileResponse

from api.auth import get_token
from api.cache import clear_rclone_cache, get_redis_client
from api.config import get_backup_path
from api.models import (
    BackupFile,
    BackupMetadataResponse,
    BulkDeleteRequest,
    BulkDeleteResponse,
    BulkDeleteResult,
    CacheRefreshResponse,
    RcloneConfigBase64Response,
    TriggerBackupResponse,
)
from api.rclone import run_copyto, run_deletefile, run_lsjson
from api.utils import DEFAULT_MAX, DEFAULT_MIN, parse_dt

router = APIRouter(prefix="/backups", tags=["Backups"])

def pascal_to_snake_dict(item: dict[str, Any]) -> dict[str, Any]:
    """Convert a dictionary with PascalCase keys to snake_case keys."""
    def to_snake(s: str) -> str:
        """Convert a string from PascalCase to snake_case."""
        return re.sub(r"(?<!^)(?=[A-Z])", "_", s).lower()
    allowed_keys = ["Name", "Size", "ModTime"]
    return {to_snake(k): item[k] for k in allowed_keys if k in item}


@router.get("/")
def list_backups( #noqa: C901,PLR0912,PLR0913
    remote: str,
    _: Annotated[bool, Depends(get_token)],
    search: str | None = None,
    min_size: int | None = None,
    max_size: int | None = None,
    min_date: str | None = None,
    max_date: str | None = None,
    page: int = 1,
    page_size: int = 20,
) -> list[BackupFile]:
    """List backups from a specific remote with optional filters."""
    backup_path = get_backup_path()
    redis_client = get_redis_client()
    use_filters = any([search, min_size, max_size])
    flags = []
    if search:
        flags += ["--include", f"*{search}*"]
    if min_size is not None:
        flags += ["--min-size", str(min_size)]
    if max_size is not None:
        flags += ["--max-size", str(max_size)]
    if use_filters:
        try:
            all_files = run_lsjson(remote, backup_path, flags)
        except RuntimeError as e:
            raise HTTPException(status_code=500, detail=f"rclone error: {e}") from e
    else:
        cache_key = f"rclone_lsjson:{remote}:{backup_path}"
        cached = redis_client.get(cache_key)
        if cached:
            try:
                all_files = json.loads(cached)
            except Exception:
                all_files = []
        else:
            try:
                all_files = run_lsjson(remote, backup_path)
                redis_client.set(cache_key, json.dumps(all_files), ex=86400)
            except RuntimeError:
                all_files = []

    if min_date:
        min_dt = parse_dt(min_date)
        if min_dt:
            if min_dt.tzinfo is None:
                min_dt = min_dt.replace(tzinfo=DEFAULT_MIN.tzinfo)
            all_files = [
                f for f in all_files
                if (parse_dt(f.get("ModTime", "")) or DEFAULT_MIN).astimezone(DEFAULT_MIN.tzinfo) >= min_dt
            ]
    if max_date:
        max_dt = parse_dt(max_date)
        if max_dt:
            if max_dt.tzinfo is None:
                max_dt = max_dt.replace(tzinfo=DEFAULT_MAX.tzinfo)
            all_files = [
                f for f in all_files
                if (parse_dt(f.get("ModTime", "")) or DEFAULT_MAX).astimezone(DEFAULT_MAX.tzinfo) <= max_dt
            ]
    start = (page - 1) * page_size
    end = start + page_size
    return [BackupFile(**pascal_to_snake_dict(f)) for f in all_files[start:end]]

@router.get("/{remote}/{filename:path}")
def get_backup_metadata(remote: str, filename: str, _: Annotated[bool, Depends(get_token)]) -> BackupMetadataResponse:
    """Get metadata for a specific backup file."""
    redis_client = get_redis_client()
    backup_path = get_backup_path()
    cache_key = f"rclone_lsjson:{remote}:{backup_path}"
    cached = redis_client.get(cache_key)
    if cached:
        try:
            all_files = json.loads(cached)
        except Exception:
            all_files = []
    else:
        try:
            all_files = run_lsjson(remote, backup_path)
            redis_client.set(cache_key, json.dumps(all_files), ex=86400)
        except Exception:
            all_files = []
    for f in all_files:
        if f.get("Name") == filename:
            return BackupMetadataResponse(**pascal_to_snake_dict(f))
    raise HTTPException(status_code=404, detail="Backup not found.")

@router.delete("/{remote}/{filename:path}")
def delete_backup(remote: str, filename: str, _: Annotated[bool, Depends(get_token)]) -> dict[str, str]:
    """Delete a specific backup file from a remote."""
    redis_client = get_redis_client()
    backup_path = get_backup_path()
    result = run_deletefile(remote, backup_path, filename)
    if result.returncode == 0:
        cache_key = f"rclone_lsjson:{remote}:{backup_path}"
        redis_client.delete(cache_key)
        return {"status": "ok", "message": f"Deleted {filename}"}
    raise HTTPException(status_code=500,
                        detail=f"Failed to delete backup: {result.stderr if result.stderr else 'Delete failed'}")

@router.post("/refresh-cache")
def refresh_cache(remote: str, _: Annotated[bool, Depends(get_token)]) -> CacheRefreshResponse:
    """Refresh the cache for the rclone lsjson command."""
    backup_path = get_backup_path()
    redis_client = get_redis_client()
    cache_key = f"rclone_lsjson:{remote}:{backup_path}"
    try:
        files = run_lsjson(remote, backup_path)
        redis_client.set(cache_key, json.dumps(files), ex=86400)
        return CacheRefreshResponse(
            status="ok",
            message="Cache refreshed.",
            cache_key=cache_key,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to refresh cache - {e}.") from e

@router.get("/download/{remote}/{filename:path}")
def download_backup(remote: str, filename: str, _: Annotated[bool, Depends(get_token)]) -> FileResponse:
    """Download a specific backup file from a remote."""
    backup_path = get_backup_path()
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = tmp.name
    result = run_copyto(remote, backup_path, filename, tmp_path)
    if result.returncode != 0:
        raise HTTPException(status_code=404, detail="File not found or download failed.")
    return FileResponse(tmp_path, filename=filename, media_type="application/octet-stream")

@router.post("/trigger-backup")
def trigger_backup(_: Annotated[bool, Depends(get_token)]) -> TriggerBackupResponse:
    """Trigger a backup process by running the setup and backup scripts."""
    clear_rclone_cache()
    setup = subprocess.run(["./setup-rclone.sh"], check=False, capture_output=True, text=True)
    backup = subprocess.run(["./scripts/backup.sh"], check=False, capture_output=True, text=True)
    if setup.returncode != 0 or backup.returncode != 0:
        err = setup.stderr + backup.stderr
        raise HTTPException(status_code=500, detail=f"Backup failed: {err}")
    return TriggerBackupResponse(
        status="ok",
        message="Backup triggered successfully",
        backup_id=None,
    )

@router.post("/{remote}/bulk-delete")
def bulk_delete_backups(
    remote: str,
    req: BulkDeleteRequest,
    _: Annotated[bool, Depends(get_token)],
) -> BulkDeleteResponse:
    """Bulk delete backups from a specific remote."""
    backup_path = get_backup_path()
    redis_client = get_redis_client()
    results = []
    cache_key = f"rclone_lsjson:{remote}:{backup_path}"
    for filename in req.files:
        result = run_deletefile(remote, backup_path, filename)
        if result.returncode == 0:
            status: Literal["ok", "error", "not_found", "permission_denied"] = "ok"
            message = f"Deleted {filename}"
        else:
            status = "error"
            message = result.stderr if result.stderr else "Delete failed"
        results.append(
            BulkDeleteResult(
                filename=filename,
                status=status,
                message=message,
                size_freed=None,
            ),
        )
    if any(r.status == "ok" for r in results):
        redis_client.delete(cache_key)
    return BulkDeleteResponse(
        results=results,
        total_size_freed=0,
    )

@router.post("/rclone/config/base64")
def rclone_config_to_base64(
    _: Annotated[bool, Depends(get_token)],
    config: Annotated[str, Body(media_type="text/plain", description="Raw rclone config contents")],
) -> RcloneConfigBase64Response:
    """Convert rclone config to base64 encoded string."""
    encoded = base64.b64encode(config.encode("utf-8")).decode("ascii")
    return RcloneConfigBase64Response(
        status="ok",
        message="Config converted to base64 successfully",
        base64_config=encoded,
        config_size=len(config),
    )

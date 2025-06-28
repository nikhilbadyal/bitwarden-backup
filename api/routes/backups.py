import asyncio
import base64
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.responses import FileResponse

from api.auth import get_token
from api.cache import clear_rclone_cache, get_redis_client
from api.config import get_backup_path, get_encryption_password, get_scripts_dir, setup_rclone_config
from api.models import (
    BackupFile,
    BackupMetadataResponse,
    BulkDeleteRequest,
    BulkDeleteResponse,
    BulkDeleteResult,
    CacheRefreshResponse,
    PaginatedBackupResponse,
    RcloneConfigBase64Response,
    TriggerBackupResponse,
)
from api.rclone import run_copyto, run_deletefile, run_lsjson
from api.utils import DEFAULT_MAX, DEFAULT_MIN, parse_dt

router = APIRouter(prefix="/backups", tags=["Backups"])

# Internal metadata files that should be filtered out from user-facing operations
INTERNAL_METADATA_FILES = {
    ".last_bw_backup_hash.sha256",  # Hash tracking file used by backup script
    # Add future metadata files here as needed
}

def filter_internal_files(files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Filter out internal metadata files from backup file listings."""
    return [f for f in files if f.get("Name") not in INTERNAL_METADATA_FILES]

def is_internal_metadata_file(filename: str) -> bool:
    """Check if a filename is an internal metadata file that should be protected."""
    return filename in INTERNAL_METADATA_FILES

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
    sort_by: str = "ModTime",
    sort_order: str = "desc",
) -> PaginatedBackupResponse:
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

    # Filter out internal metadata files from user-facing listings
    all_files = filter_internal_files(all_files)

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

    if sort_by == "ModTime":
        all_files.sort(key=lambda x: parse_dt(x.get("ModTime", "")) or DEFAULT_MIN, reverse=sort_order == "desc")

    total_files = len(all_files)
    start = (page - 1) * page_size
    end = start + page_size
    paginated_files = [BackupFile(**pascal_to_snake_dict(f)) for f in all_files[start:end]]

    return PaginatedBackupResponse(
        items=paginated_files,
        total=total_files,
        page=page,
        page_size=page_size,
    )

@router.get("/download/{remote}/{filename:path}")
def download_backup(remote: str, filename: str, _: Annotated[bool, Depends(get_token)]) -> FileResponse:
    """Download a specific backup file from a remote."""
    # Prevent download of internal metadata files
    if is_internal_metadata_file(filename):
        raise HTTPException(
            status_code=400,
            detail="Internal metadata file not available for download",
        )

    backup_path = get_backup_path()
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = tmp.name
    result = run_copyto(remote, backup_path, filename, tmp_path)
    if result.returncode != 0:
        raise HTTPException(status_code=404, detail="File not found or download failed.")
    return FileResponse(tmp_path, filename=filename, media_type="application/octet-stream")

@router.get("/{remote}/{filename:path}")
def get_backup_metadata(remote: str, filename: str, _: Annotated[bool, Depends(get_token)]) -> BackupMetadataResponse:
    """Get metadata for a specific backup file."""
    # Reject requests for internal metadata files
    if is_internal_metadata_file(filename):
        raise HTTPException(
            status_code=404,
            detail="Internal metadata file not accessible",
        )

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

    # Filter out internal metadata files
    all_files = filter_internal_files(all_files)

    for f in all_files:
        if f.get("Name") == filename:
            return BackupMetadataResponse(**pascal_to_snake_dict(f))
    raise HTTPException(status_code=404, detail="Backup not found.")

@router.delete("/{remote}/{filename:path}")
def delete_backup(remote: str, filename: str, _: Annotated[bool, Depends(get_token)]) -> dict[str, str]:
    """Delete a specific backup file from a remote."""
    # Prevent deletion of internal metadata files
    if is_internal_metadata_file(filename):
        raise HTTPException(
            status_code=400,
            detail="Cannot delete internal metadata file required by backup system",
        )

    redis_client = get_redis_client()
    backup_path = get_backup_path()
    result = run_deletefile(remote, backup_path, filename)
    if result.returncode == 0:
        cache_key = f"rclone_lsjson:{remote}:{backup_path}"
        redis_client.delete(cache_key)
        return {"status": "ok", "message": f"Deleted {filename}"}
    raise HTTPException(status_code=500,
                        detail=f"Failed to delete backup: {result.stderr if result.stderr else 'Delete failed'}")

@router.post("/restore/{remote}/{filename:path}")
async def restore_backup(
    remote: str,
    filename: str,
    _: Annotated[bool, Depends(get_token)],
) -> FileResponse:
    """Restore a specific backup file from a remote by downloading and decrypting it."""
    # Prevent restore of internal metadata files
    if is_internal_metadata_file(filename):
        raise HTTPException(
            status_code=400,
            detail="Internal metadata file cannot be restored",
        )

    def _raise_process_error(error_message: str) -> None:
        """Raise HTTPException for process execution errors."""
        raise HTTPException(
            status_code=500,
            detail=f"Failed to restore backup: {error_message}",
        )

    def _raise_output_missing_error() -> None:
        """Raise HTTPException when output file was not created."""
        raise HTTPException(
            status_code=500,
            detail="Restore completed but output file was not created",
        )

    scripts_dir = get_scripts_dir()
    script_path = scripts_dir / "restore-backup.sh"

    if not script_path.exists():
        raise HTTPException(status_code=500, detail="Restore script not found.")

    # Create a temporary directory securely, then create file inside it
    temp_dir = tempfile.mkdtemp(prefix="restored_backup_")
    output_file = Path(temp_dir) / "restored_backup.json"

    command = [
        str(script_path),
        "-r",
        remote,
        "--specific-file",
        filename,
        "-o",
        str(output_file),
    ]

    try:
        # Set up rclone configuration from RCLONE_CONFIG_BASE64
        setup_rclone_config()

        encryption_password = get_encryption_password()
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "ENCRYPTION_PASSWORD": encryption_password},
        )
        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            error_message = stderr.decode() if stderr else "Unknown error occurred"
            _raise_process_error(error_message)

        if not output_file.exists():
            _raise_output_missing_error()

        return FileResponse(
            path=str(output_file),
            filename=f"restored_{filename.replace('.enc', '.json')}",
            media_type="application/json",
        )
    except Exception as e:
        # Clean up the temporary directory on error
        if Path(temp_dir).exists():
            shutil.rmtree(temp_dir)
        if isinstance(e, HTTPException):
            raise
        raise HTTPException(
            status_code=500,
            detail=f"An unexpected error occurred during restore: {e!s}",
        ) from e

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
        # Handle internal metadata files
        if is_internal_metadata_file(filename):
            results.append(
                BulkDeleteResult(
                    filename=filename,
                    status="error",
                    message="Cannot delete internal metadata file required by backup system",
                    size_freed=None,
                ),
            )
            continue

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

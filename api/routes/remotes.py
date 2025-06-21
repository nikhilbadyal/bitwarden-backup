import json
import time
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException

from api.auth import get_token
from api.config import get_backup_path
from api.models import AllRemotesTestResponse, RemotesResponse, RemoteStatus, RemoteTestResponse, RemoteUsageResponse
from api.rclone import run_about, run_listremotes, run_lsf

router = APIRouter(prefix="/remotes", tags=["Remotes"])

@router.get("/")
def list_remotes(_: Annotated[bool, Depends(get_token)]) -> RemotesResponse:
    """List all configured remotes."""
    remotes = run_listremotes()
    return RemotesResponse(remotes=remotes)

@router.get("/{remote}/check")
def check_remote_connection(remote: str, _: Annotated[bool, Depends(get_token)]) -> RemoteTestResponse:
    """Check if a specific remote is reachable."""
    backup_path = get_backup_path()
    start_time = time.time()
    proc = run_lsf(remote, backup_path)
    response_time_ms = int((time.time() - start_time) * 1000)
    if proc.returncode == 0:
        return RemoteTestResponse(
            status="ok",
            message=f"Remote '{remote}' is reachable.",
            remote_name=remote,
            response_time_ms=response_time_ms,
        )
    return RemoteTestResponse(
        status="error",
        message=proc.stderr or f"Remote '{remote}' is not reachable.",
        remote_name=remote,
        response_time_ms=response_time_ms,
    )

@router.get("/check-all")
def check_all_remotes(_: Annotated[bool, Depends(get_token)]) -> AllRemotesTestResponse:
    """Check the connection status of all remotes."""
    remotes = run_listremotes()
    results = []
    backup_path = get_backup_path()
    for remote in remotes:
        start_time = time.time()
        proc = run_lsf(remote, backup_path)
        response_time_ms = int((time.time() - start_time) * 1000)
        if proc.returncode == 0:
            results.append(
                RemoteStatus(
                    remote=remote,
                    status="ok",
                    message="reachable",
                    response_time_ms=response_time_ms,
                ),
            )
        else:
            msg = proc.stderr.strip() or "not reachable"
            results.append(
                RemoteStatus(
                    remote=remote,
                    status="error",
                    message=msg,
                    response_time_ms=response_time_ms,
                ),
            )
    return AllRemotesTestResponse(results=results)

@router.get("/{remote}/usage")
def get_remote_usage(remote: str, _: Annotated[bool, Depends(get_token)]) -> RemoteUsageResponse:
    """Get usage information for a specific remote."""
    backup_path = get_backup_path()
    proc = run_about(remote, backup_path)
    if proc.returncode != 0:
        msg = proc.stderr or proc.stdout or "Failed to get usage info."
        if "doesn't support about" in msg or "not supported" in msg.lower():
            return RemoteUsageResponse(remote=remote, used=0, total=None, free=None)
        raise HTTPException(status_code=500, detail=msg)
    try:
        data = json.loads(proc.stdout)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Invalid usage info: {exc}") from exc
    used = int(data.get("used", 0))
    total = int(data["total"]) if "total" in data else None
    free = int(data["free"]) if "free" in data else None
    return RemoteUsageResponse(remote=remote, used=used, total=total, free=free)

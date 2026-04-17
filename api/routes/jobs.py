"""API routes for backup job management."""

import asyncio
import json
from collections.abc import AsyncGenerator
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse

from api.auth import get_token
from api.cache import clear_rclone_cache
from api.jobs import BackupJobManager, JobStatus, JobUpdate, cancel_running_job, start_backup_job
from api.models import (
    BackupJobListResponse,
    BackupJobLogEntry,
    BackupJobLogsResponse,
    BackupJobResponse,
    BackupJobStatusResponse,
    BackupJobStreamTokenResponse,
    CancelJobResponse,
)

router = APIRouter(prefix="/jobs", tags=["Backup Jobs"])


def _job_to_status_response(job: dict[str, Any]) -> BackupJobStatusResponse:
    """Convert job dict to BackupJobStatusResponse."""
    return BackupJobStatusResponse(
        id=job["id"],
        status=job["status"],
        progress=job["progress"],
        current_step=job["current_step"],
        created_at=job["created_at"],
        started_at=job.get("started_at"),
        completed_at=job.get("completed_at"),
        error=job.get("error"),
        result=job.get("result"),
    )


@router.post(
    "/trigger",
    status_code=201,
    summary="Trigger a new backup job",
    description="Start a new async backup job. Returns immediately with job ID.",
)
async def trigger_backup_job(
    _: Annotated[bool, Depends(get_token)],
) -> BackupJobResponse:
    """Trigger a new backup job asynchronously.

    This endpoint returns immediately with a job ID.
    Use the job status endpoint to monitor progress.
    """
    # Clear rclone cache before starting
    clear_rclone_cache()

    # Create job
    manager = BackupJobManager()
    job_id = manager.create_job()

    # Start backup in background
    start_backup_job(job_id)

    job = manager.get_job(job_id)
    if not job:
        raise HTTPException(status_code=500, detail="Failed to create backup job")

    return BackupJobResponse(
        job_id=job_id,
        status=job["status"],
        message="Backup job started. Use the job status endpoint to monitor progress.",
        created_at=job["created_at"],
    )


@router.get(
    "/",
    summary="List backup jobs",
    description="List recent backup jobs with their status.",
)
def list_backup_jobs(
    _: Annotated[bool, Depends(get_token)],
    limit: Annotated[int, Query(ge=1, le=100, description="Maximum jobs to return")] = 20,
) -> BackupJobListResponse:
    """List recent backup jobs."""
    manager = BackupJobManager()
    jobs = manager.list_jobs(limit=limit)

    return BackupJobListResponse(
        jobs=[_job_to_status_response(job) for job in jobs],
        total=len(jobs),
    )


@router.get(
    "/{job_id}",
    summary="Get job status",
    description="Get detailed status of a specific backup job.",
)
def get_job_status(
    job_id: str,
    _: Annotated[bool, Depends(get_token)],
) -> BackupJobStatusResponse:
    """Get the status of a specific backup job."""
    manager = BackupJobManager()
    job = manager.get_job(job_id)

    if not job:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")

    return _job_to_status_response(job)


@router.get(
    "/{job_id}/logs",
    summary="Get job logs",
    description="Get logs for a specific backup job.",
)
def get_job_logs(
    job_id: str,
    _: Annotated[bool, Depends(get_token)],
    start: Annotated[int, Query(ge=0, description="Start index for logs")] = 0,
    limit: Annotated[int, Query(ge=1, le=1000, description="Maximum logs to return")] = 100,
) -> BackupJobLogsResponse:
    """Get logs for a specific backup job."""
    manager = BackupJobManager()
    job = manager.get_job(job_id)

    if not job:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")

    logs = manager.get_logs(job_id, start=start, end=start + limit - 1)

    return BackupJobLogsResponse(
        job_id=job_id,
        logs=[BackupJobLogEntry(**log) for log in logs],
        total_logs=len(logs),
    )


@router.post(
    "/{job_id}/stream-token",
    summary="Issue a short-lived SSE stream token",
    description=(
        "Issue a short-lived token for SSE stream bootstrap so the primary API token "
        "does not need to be sent in query parameters."
    ),
)
def issue_stream_token(
    job_id: str,
    _: Annotated[bool, Depends(get_token)],
) -> BackupJobStreamTokenResponse:
    """Issue a short-lived token used only to open the SSE stream for a job."""
    # Create a manager instance to access job state and token issuance helpers.
    manager = BackupJobManager()
    # Ensure the target job exists before minting a stream token.
    job = manager.get_job(job_id)
    if not job:
        # Return 404 so clients can handle stale or invalid job IDs.
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    # Issue a short-lived token bound to this job only.
    stream_token, ttl_seconds = manager.issue_stream_token(job_id)
    # Return token and TTL metadata so the UI can open the stream immediately.
    return BackupJobStreamTokenResponse(
        job_id=job_id,
        stream_token=stream_token,
        expires_in_seconds=ttl_seconds,
    )


@router.get(
    "/{job_id}/stream",
    summary="Stream job updates (SSE)",
    description=(
        "Server-Sent Events stream for real-time job updates and logs. "
        "Use a short-lived stream token from /stream-token."
    ),
)
async def stream_job_updates(
    job_id: str,
    stream_token: Annotated[str, Query(min_length=20, description="Short-lived stream token")],
) -> StreamingResponse:
    """Stream job updates and logs via Server-Sent Events (SSE).

    Connect to this endpoint to receive real-time updates about job progress and logs.
    The stream will close automatically when the job completes.
    """
    # Create a manager instance for both auth validation and stream state reads.
    manager = BackupJobManager()
    # Validate and consume the short-lived stream token before opening the stream.
    if not manager.consume_stream_token(job_id, stream_token):
        # Reject invalid, expired, or replayed stream tokens with 401.
        raise HTTPException(status_code=401, detail="Invalid or expired stream token")
    # Load the target job after auth validation.
    job = manager.get_job(job_id)

    if not job:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")

    async def event_generator() -> AsyncGenerator[str, None]:
        """Generate SSE events for job updates."""
        last_log_index = 0
        last_progress = -1
        last_status = ""

        while True:
            # Get current job state
            current_job = manager.get_job(job_id)
            if not current_job:
                yield 'event: error\ndata: {"error": "Job not found"}\n\n'
                break

            # Send status update if changed
            if current_job["status"] != last_status or current_job["progress"] != last_progress:
                last_status = current_job["status"]
                last_progress = current_job["progress"]

                status_data = {
                    "type": "status",
                    "status": current_job["status"],
                    "progress": current_job["progress"],
                    "current_step": current_job["current_step"],
                    "error": current_job.get("error"),
                }
                yield f"event: status\ndata: {json.dumps(status_data)}\n\n"

            # Send new logs
            new_logs, last_log_index = manager.get_new_logs(job_id, last_log_index)
            for log in new_logs:
                log_data = {"type": "log", **log}
                yield f"event: log\ndata: {json.dumps(log_data)}\n\n"

            # Check if job is done
            if current_job["status"] in ("completed", "failed", "cancelled"):
                done_data = {
                    "type": "done",
                    "status": current_job["status"],
                    "result": current_job.get("result"),
                    "error": current_job.get("error"),
                }
                yield f"event: done\ndata: {json.dumps(done_data)}\n\n"
                break

            # Wait before next poll
            await asyncio.sleep(0.5)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        },
    )


@router.post(
    "/{job_id}/cancel",
    summary="Cancel a backup job",
    description="Cancel a pending or running backup job.",
)
def cancel_job(
    job_id: str,
    _: Annotated[bool, Depends(get_token)],
) -> CancelJobResponse:
    """Cancel a backup job."""
    manager = BackupJobManager()
    job = manager.get_job(job_id)

    if not job:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")

    if job["status"] not in (JobStatus.PENDING.value, JobStatus.RUNNING.value):
        raise HTTPException(
            status_code=400,
            detail=f"Cannot cancel job with status '{job['status']}'",
        )

    # Try to cancel the running task
    if job["status"] == JobStatus.RUNNING.value:
        cancel_running_job(job_id)

    # Update job status
    manager.update_job(job_id, JobUpdate(status=JobStatus.CANCELLED))
    manager.add_log(job_id, "WARN", "Job cancelled by user")

    return CancelJobResponse(
        job_id=job_id,
        status="ok",
        message="Job cancelled successfully",
    )

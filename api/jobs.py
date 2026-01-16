"""Backup job management module for async backup execution."""

import asyncio
import json
import os
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import Enum
from typing import Any

from api.cache import get_redis_client


class JobStatus(str, Enum):
    """Backup job status enumeration."""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class JobUpdate:
    """Data class for job update parameters."""

    status: JobStatus | None = None
    progress: int | None = None
    current_step: str | None = None
    error: str | None = None
    result: dict[str, Any] | None = None


class BackupJobManager:
    """Manager for backup jobs using Redis for state storage."""

    JOB_PREFIX = "backup_job:"
    JOB_LOGS_PREFIX = "backup_job_logs:"
    JOB_LIST_KEY = "backup_jobs_list"
    JOB_TTL = 86400 * 7  # 7 days

    def __init__(self) -> None:
        """Initialize the job manager."""
        self.redis = get_redis_client()

    def create_job(self) -> str:
        """Create a new backup job and return its ID."""
        job_id = str(uuid.uuid4())
        now = datetime.now(UTC).isoformat()

        job_data = {
            "id": job_id,
            "status": JobStatus.PENDING.value,
            "created_at": now,
            "started_at": None,
            "completed_at": None,
            "progress": 0,
            "current_step": "Initializing...",
            "error": None,
            "result": None,
        }

        # Store job data
        self.redis.setex(
            f"{self.JOB_PREFIX}{job_id}",
            self.JOB_TTL,
            json.dumps(job_data),
        )

        # Add to job list (sorted set by creation time)
        self.redis.zadd(self.JOB_LIST_KEY, {job_id: datetime.now(UTC).timestamp()})

        # Initialize empty log list
        self.redis.delete(f"{self.JOB_LOGS_PREFIX}{job_id}")

        return job_id

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        """Get job data by ID."""
        data = self.redis.get(f"{self.JOB_PREFIX}{job_id}")
        if data:
            result: dict[str, Any] = json.loads(data)
            return result
        return None

    def update_job(self, job_id: str, update: JobUpdate) -> bool:
        """Update job data."""
        job = self.get_job(job_id)
        if not job:
            return False

        now = datetime.now(UTC).isoformat()

        if update.status:
            job["status"] = update.status.value
            if update.status == JobStatus.RUNNING and not job["started_at"]:
                job["started_at"] = now
            elif update.status in (JobStatus.COMPLETED, JobStatus.FAILED, JobStatus.CANCELLED):
                job["completed_at"] = now

        if update.progress is not None:
            job["progress"] = update.progress

        if update.current_step is not None:
            job["current_step"] = update.current_step

        if update.error is not None:
            job["error"] = update.error

        if update.result is not None:
            job["result"] = update.result

        self.redis.setex(
            f"{self.JOB_PREFIX}{job_id}",
            self.JOB_TTL,
            json.dumps(job),
        )

        return True

    def add_log(self, job_id: str, level: str, message: str) -> None:
        """Add a log entry to a job."""
        log_entry = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": level,
            "message": message,
        }
        self.redis.rpush(
            f"{self.JOB_LOGS_PREFIX}{job_id}",
            json.dumps(log_entry),
        )
        self.redis.expire(f"{self.JOB_LOGS_PREFIX}{job_id}", self.JOB_TTL)

    def get_logs(self, job_id: str, start: int = 0, end: int = -1) -> list[dict[str, Any]]:
        """Get logs for a job."""
        logs = self.redis.lrange(f"{self.JOB_LOGS_PREFIX}{job_id}", start, end)
        return [json.loads(log) for log in logs]

    def get_new_logs(self, job_id: str, last_index: int) -> tuple[list[dict[str, Any]], int]:
        """Get new logs since last_index. Returns (logs, new_last_index)."""
        logs = self.redis.lrange(f"{self.JOB_LOGS_PREFIX}{job_id}", last_index, -1)
        parsed_logs = [json.loads(log) for log in logs]
        new_last_index = last_index + len(parsed_logs)
        return parsed_logs, new_last_index

    def list_jobs(self, limit: int = 20) -> list[dict[str, Any]]:
        """List recent jobs."""
        # Get job IDs sorted by creation time (newest first)
        job_ids = self.redis.zrevrange(self.JOB_LIST_KEY, 0, limit - 1)
        jobs = []
        for job_id in job_ids:
            job = self.get_job(job_id)
            if job:
                jobs.append(job)
        return jobs

    def cancel_job(self, job_id: str) -> bool:
        """Cancel a pending or running job."""
        job = self.get_job(job_id)
        if not job:
            return False

        if job["status"] not in (JobStatus.PENDING.value, JobStatus.RUNNING.value):
            return False

        return self.update_job(job_id, JobUpdate(status=JobStatus.CANCELLED))

    def cleanup_old_jobs(self, max_age_days: int = 7) -> int:
        """Remove jobs older than max_age_days."""
        cutoff = datetime.now(UTC).timestamp() - (max_age_days * 86400)
        old_jobs = self.redis.zrangebyscore(self.JOB_LIST_KEY, 0, cutoff)

        for job_id in old_jobs:
            self.redis.delete(f"{self.JOB_PREFIX}{job_id}")
            self.redis.delete(f"{self.JOB_LOGS_PREFIX}{job_id}")

        self.redis.zremrangebyscore(self.JOB_LIST_KEY, 0, cutoff)
        return len(old_jobs)


# Progress mapping for backup script output
PROGRESS_MAP = {
    "Logging out": 25,
    "Checking for required dependencies": 30,
    "Validating environment": 35,
    "Configuring Bitwarden server": 40,
    "Logging into Bitwarden": 45,
    "Unlocking vault": 50,
    "Exporting vault data": 55,
    "Syncing vault data": 60,
    "Performing secure compression": 65,
    "Validating the encrypted backup": 70,
    "Checking for changes": 75,
    "Uploading backup": 80,
    "Pruning old backups": 90,
    "completed successfully": 100,
}


async def _run_setup_script(job_id: str, manager: BackupJobManager) -> bool:
    """Run the setup-rclone.sh script. Returns True on success."""
    manager.update_job(job_id, JobUpdate(progress=10, current_step="Setting up rclone configuration..."))
    manager.add_log(job_id, "INFO", "Running setup-rclone.sh")

    setup_process = await asyncio.create_subprocess_exec(
        "./setup-rclone.sh",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env={**os.environ},
    )
    setup_stdout, setup_stderr = await setup_process.communicate()

    if setup_stdout:
        for line in setup_stdout.decode().strip().split("\n"):
            if line.strip():
                manager.add_log(job_id, "INFO", f"[setup] {line}")

    if setup_process.returncode != 0:
        error_msg = setup_stderr.decode() if setup_stderr else "Setup failed"
        manager.add_log(job_id, "ERROR", f"Setup failed: {error_msg}")
        manager.update_job(job_id, JobUpdate(status=JobStatus.FAILED, error=error_msg, current_step="Setup failed"))
        return False

    manager.add_log(job_id, "SUCCESS", "Rclone setup completed")
    manager.update_job(job_id, JobUpdate(progress=20, current_step="Running backup script..."))
    return True


def _parse_log_level(line: str) -> str:
    """Parse log level from a log line."""
    if "[ERROR]" in line or "ERROR" in line:
        return "ERROR"
    if "[WARN]" in line or "WARN" in line:
        return "WARN"
    if "[SUCCESS]" in line or "SUCCESS" in line:
        return "SUCCESS"
    return "INFO"


async def _run_backup_script(job_id: str, manager: BackupJobManager) -> bool:
    """Run the backup.sh script. Returns True on success."""
    manager.add_log(job_id, "INFO", "Starting backup.sh script")

    backup_process = await asyncio.create_subprocess_exec(
        "./scripts/backup.sh",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env={**os.environ},
    )

    if backup_process.stdout:
        async for line_bytes in backup_process.stdout:
            line = line_bytes.decode().strip()
            if not line:
                continue

            level = _parse_log_level(line)
            manager.add_log(job_id, level, line)

            # Update progress based on keywords
            for keyword, prog in PROGRESS_MAP.items():
                if keyword.lower() in line.lower():
                    manager.update_job(job_id, JobUpdate(progress=prog, current_step=keyword))
                    break

    await backup_process.wait()

    if backup_process.returncode == 0:
        manager.update_job(
            job_id,
            JobUpdate(
                status=JobStatus.COMPLETED,
                progress=100,
                current_step="Backup completed successfully",
                result={"exit_code": 0},
            ),
        )
        manager.add_log(job_id, "SUCCESS", "Backup job completed successfully")
        return True

    error_msg = f"Backup script exited with code {backup_process.returncode}"
    manager.update_job(job_id, JobUpdate(status=JobStatus.FAILED, error=error_msg, current_step="Backup failed"))
    manager.add_log(job_id, "ERROR", error_msg)
    return False


async def run_backup_job(job_id: str) -> None:
    """Run the backup process asynchronously and update job status."""
    manager = BackupJobManager()

    # Update job to running
    manager.update_job(
        job_id,
        JobUpdate(status=JobStatus.RUNNING, progress=0, current_step="Starting backup process..."),
    )
    manager.add_log(job_id, "INFO", "Backup job started")

    try:
        # Step 1: Setup rclone
        if not await _run_setup_script(job_id, manager):
            return

        # Step 2: Run backup script
        await _run_backup_script(job_id, manager)

    except asyncio.CancelledError:
        manager.update_job(job_id, JobUpdate(status=JobStatus.CANCELLED, current_step="Job cancelled"))
        manager.add_log(job_id, "WARN", "Backup job was cancelled")
        raise

    except Exception as e:
        error_msg = str(e)
        manager.update_job(job_id, JobUpdate(status=JobStatus.FAILED, error=error_msg, current_step="Unexpected error"))
        manager.add_log(job_id, "ERROR", f"Unexpected error: {error_msg}")


# Global dict to track running tasks (for cancellation)
_running_tasks: dict[str, asyncio.Task[None]] = {}


def start_backup_job(job_id: str) -> None:
    """Start a backup job in the background."""
    task = asyncio.create_task(run_backup_job(job_id))
    _running_tasks[job_id] = task

    # Clean up task reference when done
    def cleanup(_: asyncio.Task[None]) -> None:
        _running_tasks.pop(job_id, None)

    task.add_done_callback(cleanup)


def cancel_running_job(job_id: str) -> bool:
    """Cancel a running backup job."""
    task = _running_tasks.get(job_id)
    if task and not task.done():
        task.cancel()
        return True
    return False

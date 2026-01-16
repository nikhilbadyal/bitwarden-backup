import base64
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, computed_field, field_validator, model_validator
from pydantic.types import NonNegativeInt, PositiveInt

# Constants
BYTES_IN_KB = 1024.0

def to_snake_case(string: str) -> str:
    """Convert CamelCase or PascalCase to snake_case."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", string).lower()

class BaseAPIModel(BaseModel):
    """Base model with common configuration for all API models."""

    model_config = ConfigDict(
        # Pydantic v2 configuration
        alias_generator=to_snake_case,
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,  # Backwards compatibility
        validate_by_alias=True,
        serialize_by_alias=True,
        # Performance optimizations
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
    )


class BackupFile(BaseAPIModel):
    """Model for a backup file with enhanced validation and computed fields."""

    name: Annotated[str, Field(description="Backup file name", min_length=1)]
    size: Annotated[NonNegativeInt, Field(description="File size in bytes")]
    mod_time: Annotated[str, Field(description="Last modification time in ISO format")]

    @field_validator("mod_time")
    @classmethod
    def validate_mod_time(cls, v: str) -> str:
        """Validate and normalize modification time."""
        try:
            # Parse and re-format to ensure consistent format
            dt = datetime.fromisoformat(v)
            return dt.isoformat()
        except ValueError as e:
            msg = f"Invalid datetime format: {v}"
            raise ValueError(msg) from e

    @computed_field
    def size_human(self) -> str:
        """Human-readable file size."""
        size_float = float(self.size)
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if size_float < BYTES_IN_KB:
                return f"{size_float:.1f} {unit}"
            size_float /= BYTES_IN_KB
        return f"{size_float:.1f} PB"

    @computed_field
    def file_extension(self) -> str:
        """Extract file extension."""
        return Path(self.name).suffix.lower()

    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,
        validate_by_alias=True,
        serialize_by_alias=True,
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "name": "backup_2025-01-01_12-00-00.zip",
                    "size": 1048576,
                    "ModTime": "2025-01-01T12:00:00Z",
                },
            ],
        },
    )


class RemotesResponse(BaseAPIModel):
    """Response model for listing rclone remotes with enhanced validation."""

    remotes: Annotated[
        list[str],
        Field(description="List of configured rclone remotes", min_length=0),
    ] = []

    @computed_field
    def total_remotes(self) -> int:
        """Total number of configured remotes."""
        return len(self.remotes)

    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,
        validate_by_alias=True,
        serialize_by_alias=True,
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "remotes": ["s3", "gdrive", "dropbox"],
                },
            ],
        },
    )


class BackupMetadataResponse(BackupFile):
    """Enhanced backup metadata response inheriting from BackupFile."""

    # Additional metadata fields
    checksum: str | None = Field(None, description="File checksum if available")
    backup_type: Literal["full", "incremental", "differential"] | None = Field(
        None, description="Type of backup",
    )

    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,
        validate_by_alias=True,
        serialize_by_alias=True,
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "name": "backup_2025-01-01_12-00-00.zip",
                    "size": 1048576,
                    "ModTime": "2025-01-01T12:00:00Z",
                    "checksum": "sha256:abc123...",
                    "backup_type": "full",
                },
            ],
        },
    )


class APIResponse(BaseAPIModel):
    """Base response model with status and message."""

    status: Literal["ok", "error"] = "ok"
    message: str = Field(description="Response message")
    timestamp: datetime = Field(default_factory=lambda: datetime.now(UTC))

    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,
        validate_by_alias=True,
        serialize_by_alias=True,
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "status": "ok",
                    "message": "Operation completed successfully",
                    "timestamp": "2025-01-01T12:00:00Z",
                },
            ],
        },
    )


class CacheRefreshResponse(APIResponse):
    """Response model for cache refresh operation."""

    message: str = "Cache refreshed successfully"
    cache_key: str | None = Field(None, description="Cache key that was refreshed")


class TriggerBackupResponse(APIResponse):
    """Response model for triggering a backup (legacy synchronous)."""

    message: str = "Backup triggered successfully"
    backup_id: str | None = Field(None, description="Unique backup identifier")


class BackupJobResponse(BaseAPIModel):
    """Response model for async backup job creation."""

    job_id: str = Field(description="Unique job identifier")
    status: Literal["pending", "running", "completed", "failed", "cancelled"] = Field(
        description="Current job status",
    )
    message: str = Field(description="Status message")
    created_at: datetime = Field(description="Job creation timestamp")


class BackupJobStatusResponse(BaseAPIModel):
    """Detailed backup job status response."""

    id: str = Field(description="Unique job identifier")
    status: Literal["pending", "running", "completed", "failed", "cancelled"] = Field(
        description="Current job status",
    )
    progress: int = Field(ge=0, le=100, description="Progress percentage (0-100)")
    current_step: str = Field(description="Current operation being performed")
    created_at: str = Field(description="Job creation timestamp")
    started_at: str | None = Field(None, description="Job start timestamp")
    completed_at: str | None = Field(None, description="Job completion timestamp")
    error: str | None = Field(None, description="Error message if failed")
    result: dict[str, Any] | None = Field(None, description="Result data if completed")


class BackupJobLogEntry(BaseAPIModel):
    """Single log entry for a backup job."""

    timestamp: str = Field(description="Log entry timestamp")
    level: Literal["INFO", "WARN", "ERROR", "SUCCESS", "DEBUG"] = Field(
        description="Log level",
    )
    message: str = Field(description="Log message")


class BackupJobLogsResponse(BaseAPIModel):
    """Response model for backup job logs."""

    job_id: str = Field(description="Job identifier")
    logs: list[BackupJobLogEntry] = Field(description="List of log entries")
    total_logs: int = Field(description="Total number of log entries")


class BackupJobListResponse(BaseAPIModel):
    """Response model for listing backup jobs."""

    jobs: list[BackupJobStatusResponse] = Field(description="List of backup jobs")
    total: int = Field(description="Total number of jobs")


class CancelJobResponse(APIResponse):
    """Response model for job cancellation."""

    job_id: str = Field(description="Cancelled job identifier")
    message: str = "Job cancelled successfully"


class HealthResponse(BaseAPIModel):
    """Enhanced health check response model."""

    status: Literal["healthy", "degraded", "unhealthy"] = "healthy"
    redis: Literal["ok", "error", "unavailable"] = "ok"
    rclone: Literal["ok", "error", "unavailable"] = "ok"
    timestamp: datetime = Field(default_factory=lambda: datetime.now(UTC))
    uptime_seconds: float | None = Field(None, description="Service uptime in seconds")

    @model_validator(mode="after")
    def determine_overall_status(self) -> "HealthResponse":
        """Determine overall health status based on component status."""
        if self.redis == "error" or self.rclone == "error":
            # Use object.__setattr__ to bypass validation and prevent infinite recursion
            object.__setattr__(self, "status", "unhealthy")
        elif self.redis == "unavailable" or self.rclone == "unavailable":
            # Use object.__setattr__ to bypass validation and prevent infinite recursion
            object.__setattr__(self, "status", "degraded")
        return self

    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,
        validate_by_alias=True,
        serialize_by_alias=True,
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "status": "healthy",
                    "redis": "ok",
                    "rclone": "ok",
                    "timestamp": "2025-01-01T12:00:00Z",
                    "uptime_seconds": 3600.0,
                },
            ],
        },
    )


class RemoteTestResponse(APIResponse):
    """Response model for testing a remote connection."""

    remote_name: str = Field(description="Name of the remote being tested")
    response_time_ms: float | None = Field(None, description="Response time in milliseconds")


class ServerInfoResponse(BaseAPIModel):
    """Enhanced server information model."""

    api_version: str = Field(description="API version")
    server_time: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        description="Current server time",
    )
    backup_path: str = Field(description="Configured backup path")
    python_version: str | None = Field(None, description="Python version")
    fastapi_version: str | None = Field(None, description="FastAPI version")

    @computed_field
    def server_timezone(self) -> str:
        """Server timezone information."""
        return str(self.server_time.tzinfo)

    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
        populate_by_name=True,
        validate_by_alias=True,
        serialize_by_alias=True,
        arbitrary_types_allowed=False,
        frozen=False,
        extra="forbid",
        json_schema_extra={
            "examples": [
                {
                    "api_version": "1.0.0",
                    "server_time": "2025-01-01T12:00:00Z",
                    "backup_path": "/app/backups",
                    "python_version": "3.12.0",
                    "fastapi_version": "0.115.0",
                },
            ],
        },
    )


class RemoteStatus(BaseAPIModel):
    """Enhanced model for the status of a remote."""

    remote: str = Field(description="Remote name")
    status: Literal["ok", "error", "timeout", "unreachable"] = Field(description="Remote status")
    message: str = Field(description="Status message")
    last_checked: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        description="Last check timestamp",
    )
    response_time_ms: float | None = Field(None, description="Response time in milliseconds")


class AllRemotesTestResponse(BaseAPIModel):
    """Response model for checking all remotes."""

    results: list[RemoteStatus] = Field(description="Test results for all remotes")
    summary: dict[str, int] = Field(
        default_factory=dict,
        description="Summary of test results",
    )

    @model_validator(mode="after")
    def calculate_summary(self) -> "AllRemotesTestResponse":
        """Calculate summary statistics."""
        status_counts: dict[str, int] = {}
        for result in self.results:
            status_counts[result.status] = status_counts.get(result.status, 0) + 1
        # Use object.__setattr__ to bypass validation and prevent infinite recursion
        object.__setattr__(self, "summary", status_counts)
        return self


class RemoteUsageResponse(BaseAPIModel):
    """Enhanced response model for remote storage usage information."""

    remote: str = Field(description="Remote name")
    used: NonNegativeInt = Field(description="Used storage in bytes")
    total: PositiveInt | None = Field(None, description="Total storage in bytes")
    free: NonNegativeInt | None = Field(None, description="Free storage in bytes")
    last_updated: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        description="Last update timestamp",
    )

    @computed_field
    def usage_percentage(self) -> float | None:
        """Calculate usage percentage if total is available."""
        if self.total and self.total > 0:
            return round((self.used / self.total) * 100, 2)
        return None

    @computed_field
    def used_human(self) -> str:
        """Human-readable used storage."""
        return self._bytes_to_human(self.used) or "0 B"

    @computed_field
    def free_human(self) -> str | None:
        """Human-readable free storage."""
        return self._bytes_to_human(self.free) if self.free is not None else None

    def _bytes_to_human(self, bytes_value: int | None) -> str | None:
        """Convert bytes to human-readable format."""
        if bytes_value is None:
            return None

        bytes_float = float(bytes_value)
        for unit in ["B", "KB", "MB", "GB", "TB", "PB"]:
            if bytes_float < BYTES_IN_KB:
                return f"{bytes_float:.1f} {unit}"
            bytes_float /= BYTES_IN_KB
        return f"{bytes_float:.1f} EB"


class RcloneConfigBase64Response(APIResponse):
    """Response model for rclone configuration in base64 format."""

    base64_config: str = Field(description="Base64-encoded rclone config")
    config_size: int | None = Field(None, description="Original config size in bytes")

    @field_validator("base64_config")
    @classmethod
    def validate_base64(cls, v: str) -> str:
        """Validate base64 encoding."""
        try:
            base64.b64decode(v, validate=True)
        except Exception as e:
            msg = "Invalid base64 encoding"
            raise ValueError(msg) from e
        else:
            return v


class BulkDeleteRequest(BaseAPIModel):
    """Enhanced request model for bulk delete operation."""

    files: Annotated[
        list[str],
        Field(
            description="List of filenames to delete",
            min_length=1,
            max_length=100,
        ),
    ]

    @field_validator("files")
    @classmethod
    def validate_filenames(cls, v: list[str]) -> list[str]:
        """Validate filenames in the bulk delete request."""
        if not v:
            msg = "At least one filename must be provided"
            raise ValueError(msg)

        for filename in v:
            if not filename.strip():
                msg = "Filenames cannot be empty or whitespace-only"
                raise ValueError(msg)

        return v


class BulkDeleteResult(BaseAPIModel):
    """Enhanced result model for a single file deletion in bulk delete operation."""

    filename: str = Field(description="Filename that was processed")
    status: Literal["ok", "error", "not_found", "permission_denied"] = Field(description="Operation status")
    message: str = Field(description="Operation message")
    size_freed: int | None = Field(None, description="Bytes freed by deletion")


class BulkDeleteResponse(BaseAPIModel):
    """Enhanced response model for bulk delete operation."""

    results: list[BulkDeleteResult] = Field(description="Individual deletion results")
    summary: dict[str, Any] = Field(
        default_factory=dict,
        description="Summary of bulk delete operation",
    )
    total_size_freed: int = Field(0, description="Total bytes freed")

    @model_validator(mode="after")
    def calculate_summary(self) -> "BulkDeleteResponse":
        """Calculate summary statistics for bulk delete operation."""
        status_counts: dict[str, int] = {}
        total_size = 0

        for result in self.results:
            status_counts[result.status] = status_counts.get(result.status, 0) + 1
            if result.size_freed:
                total_size += result.size_freed

        # Use object.__setattr__ to bypass validation and prevent infinite recursion
        object.__setattr__(self, "summary", {
            "total_files": len(self.results),
            "successful": status_counts.get("ok", 0),
            "failed": status_counts.get("error", 0),
            "not_found": status_counts.get("not_found", 0),
            "permission_denied": status_counts.get("permission_denied", 0),
        })
        object.__setattr__(self, "total_size_freed", total_size)
        return self

class PaginatedBackupResponse(BaseAPIModel):
    """Paginated response model for backup files."""

    items: list[BackupFile]
    total: int
    page: int
    page_size: int


class PaginationParams(BaseAPIModel):
    """Enhanced pagination parameters."""

    page: Annotated[int, Field(ge=1, description="Page number (1-based)")] = 1
    page_size: Annotated[int, Field(ge=1, le=100, description="Items per page")] = 20

    @computed_field
    def offset(self) -> int:
        """Calculate offset for database queries."""
        return (self.page - 1) * self.page_size


class PaginatedResponse(BaseAPIModel):
    """Generic paginated response model."""

    items: list[Any] = Field(description="List of items")
    pagination: dict[str, Any] = Field(description="Pagination metadata")
    total_items: int = Field(description="Total number of items")

    @classmethod
    def create(
        cls,
        items: list[Any],
        page: int,
        page_size: int,
        total_items: int,
    ) -> "PaginatedResponse":
        """Create a paginated response with metadata."""
        total_pages = (total_items + page_size - 1) // page_size

        return cls(
            items=items,
            total_items=total_items,
            pagination={
                "page": page,
                "page_size": page_size,
                "total_pages": total_pages,
                "has_next": page < total_pages,
                "has_prev": page > 1,
            },
        )

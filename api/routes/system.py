import sys
import time
from datetime import UTC, datetime
from typing import Annotated, Any

import fastapi
from fastapi import APIRouter, HTTPException, Query, status
from fastapi.responses import JSONResponse

from api.cache import get_redis_client
from api.config import get_backup_path
from api.models import APIResponse, HealthResponse
from api.rclone import run_version

router = APIRouter(tags=["System"])

# Startup time for uptime calculation
startup_time = time.time()


def get_redis_status() -> tuple[str, float]:
    """Get Redis connection status and response time."""
    start_time = time.time()

    try:
        redis_client = get_redis_client()
        redis_client.ping()
        response_time = (time.time() - start_time) * 1000  # Convert to milliseconds
    except Exception as e:
        response_time = (time.time() - start_time) * 1000
        # Check if it's a connection error (Redis not running) vs other errors
        error_str = str(e).lower()
        if any(keyword in error_str for keyword in ["connection", "refused", "timeout", "unreachable"]):
            return "unavailable", response_time
        return "error", response_time
    else:
        return "ok", response_time


def get_rclone_status() -> tuple[str, float]:
    """Get rclone status and response time."""
    start_time = time.time()

    try:
        result = run_version()
        response_time = (time.time() - start_time) * 1000  # Convert to milliseconds

        if result.returncode == 0:
            return "ok", response_time
    except FileNotFoundError:
        # rclone binary not found
        response_time = (time.time() - start_time) * 1000
        return "unavailable", response_time
    except Exception:
        response_time = (time.time() - start_time) * 1000
        return "error", response_time
    else:
        return "error", response_time


@router.get(
    "/health",
    summary="Health Check",
    description="Check the health of the system, including Redis and rclone status",
    responses={
        200: {"description": "System health status"},
        503: {"description": "Service unavailable - system unhealthy"},
    },
)
async def health() -> JSONResponse:
    """
    Check the health of the system, including Redis and rclone status.

    Returns detailed health information including:
    - Overall system status
    - Redis connection status
    - rclone availability
    - System uptime
    """
    # Get component statuses
    redis_status, redis_response_time = get_redis_status()
    rclone_status, rclone_response_time = get_rclone_status()

    # Calculate uptime
    uptime_seconds = time.time() - startup_time

    # Create health response
    health_response = HealthResponse(
        redis=redis_status,  # type: ignore[arg-type]
        rclone=rclone_status,  # type: ignore[arg-type]
        uptime_seconds=uptime_seconds,
        timestamp=datetime.now(UTC),
    )

    # Return appropriate HTTP status based on health
    if health_response.status == "unhealthy":
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content=health_response.model_dump(mode="json"),
        )
    if health_response.status == "degraded":
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content=health_response.model_dump(mode="json"),
            headers={"X-Health-Status": "degraded"},
        )

    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=health_response.model_dump(mode="json"),
    )

@router.get(
    "/ping",
    summary="Simple Ping",
    description="Simple ping endpoint for basic connectivity testing",
)
async def ping() -> APIResponse:
    """Ping endpoint for basic connectivity testing."""
    return APIResponse(
        status="ok",
        message="pong",
        timestamp=datetime.now(UTC),
    )


@router.get(
    "/status",
    summary="Detailed Status & Metrics",
    description="Get detailed system status and optionally component metrics",
)
async def get_detailed_status(
    include_redis: Annotated[bool, Query(description="Include Redis metrics", alias="include_redis")] = False, #noqa: FBT002
    include_rclone: Annotated[bool, Query(description="Include rclone metrics", alias="include_rclone")] = False, #noqa: FBT002
) -> dict[str, Any]:
    """Get detailed system status and optionally component metrics.

    - include_redis: Whether to include Redis status and metrics.
    - include_rclone: Whether to include rclone status and metrics.

    """
    redis_status, redis_response_time = get_redis_status() if include_redis else ("unknown", None)
    rclone_status, rclone_response_time = get_rclone_status() if include_rclone else ("unknown", None)

    # Determine overall status
    # If you want always to check status for overall even if not including metrics, uncomment below
    if not include_redis and not include_rclone:
        base_redis_status, _ = get_redis_status()
        base_rclone_status, _ = get_rclone_status()
    else:
        base_redis_status = redis_status if include_redis else "unknown"
        base_rclone_status = rclone_status if include_rclone else "unknown"

    overall_status = "healthy"
    for s in [base_redis_status, base_rclone_status]:
        if s == "error":
            overall_status = "unhealthy"
            break
        if s == "unavailable":
            overall_status = "degraded"

    components = {}
    if include_redis:
        components["redis"] = {
            "status": redis_status,
            "response_time_ms": redis_response_time,
            "healthy": redis_status == "ok",
        }
    if include_rclone:
        components["rclone"] = {
            "status": rclone_status,
            "response_time_ms": rclone_response_time,
            "healthy": rclone_status == "ok",
        }

    return {
        "overall_status": overall_status,
        "timestamp": datetime.now(UTC).isoformat(),
        "uptime_seconds": time.time() - startup_time,
        "components": components,
        "system": {
            "python_version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
            "fastapi_version": fastapi.__version__,
            "backup_path": get_backup_path(),
        },
    }


@router.get(
    "/version",
    summary="Version & Info",
    description="Get comprehensive version information and server details",
)
async def get_version_info() -> dict[str, Any]:
    """Get detailed version information and system info."""
    try:
        result = run_version()
        rclone_version = "unknown"
        if result.returncode == 0 and result.stdout:
            output = result.stdout.decode() if isinstance(result.stdout, bytes) else result.stdout
            if "rclone" in output.lower():
                rclone_version = output.strip().split("\n")[0]
    except Exception:
        rclone_version = "error"

    return {
        "api": {
            "version": "1.0.0",
            "build_date": "2025-01-01",  # Adjust if you want dynamic
        },
        "server_time": datetime.now(UTC).isoformat(),
        "backup_path": get_backup_path(),
        "python": {
            "version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
            "implementation": sys.implementation.name,
        },
        "fastapi": {
            "version": fastapi.__version__,
        },
        "rclone": {
            "version": rclone_version,
            "available": rclone_version not in ["error", "unknown"],
        },
    }



@router.post(
    "/maintenance/cache/clear",
    summary="Clear Cache",
    description="Clear all cached data (use with caution)",
)
async def clear_cache() -> APIResponse:
    """Clear all cached data (use with caution in production)."""
    try:
        redis_client = get_redis_client()
        redis_client.flushall()

        return APIResponse(
            status="ok",
            message="Cache cleared successfully",
            timestamp=datetime.now(UTC),
        )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to clear cache: {e!s}",
        ) from e

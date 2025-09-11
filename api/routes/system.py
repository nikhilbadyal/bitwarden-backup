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

ComponentData = dict[str, str | float | bool]
SystemStatusData = dict[str, str | float | datetime | dict[str, str | ComponentData]]


def get_system_status(*, check_redis: bool = True, check_rclone: bool = True) -> SystemStatusData:
    """
    Get comprehensive system status information.

    Args:
    ----
        check_redis: Whether to check Redis status
        check_rclone: Whether to check rclone status

    Returns
    -------
        Dict containing system status information
    """
    status_data: SystemStatusData = {
        "timestamp": datetime.now(UTC),
        "uptime_seconds": time.time() - startup_time,
        "system": {
            "python_version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
            "fastapi_version": fastapi.__version__,
            "backup_path": get_backup_path(),
        },
        "components": {},
    }

    # Check Redis if requested
    if check_redis:
        redis_status, redis_response_time = get_redis_status()
        components = status_data["components"]
        if isinstance(components, dict):
            components["redis"] = {
                "status": redis_status,
                "response_time_ms": redis_response_time,
                "healthy": redis_status == "ok",
            }

    # Check rclone if requested
    if check_rclone:
        rclone_status, rclone_response_time = get_rclone_status()
        components = status_data["components"]
        if isinstance(components, dict):
            components["rclone"] = {
                "status": rclone_status,
                "response_time_ms": rclone_response_time,
                "healthy": rclone_status == "ok",
            }

    return status_data


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
    description="Standard health check endpoint with appropriate HTTP status codes",
    responses={
        200: {"description": "System is healthy"},
        206: {"description": "System is degraded but functional"},
        503: {"description": "System is unhealthy"},
    },
)
async def health() -> JSONResponse:
    """
    Return standard health check with appropriate HTTP status codes.

    This endpoint is optimized for health checking systems and load balancers.
    It always checks all critical components and returns proper HTTP status codes.
    """
    # Get component statuses
    redis_status, _redis_response_time = get_redis_status()
    rclone_status, _rclone_response_time = get_rclone_status()

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
            status_code=status.HTTP_206_PARTIAL_CONTENT,
            content=health_response.model_dump(mode="json"),
            headers={"X-Health-Status": "degraded"},
        )

    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=health_response.model_dump(mode="json"),
    )


@router.get(
    "/ping",
    summary="Simple Connectivity Test",
    description="Minimal endpoint for basic connectivity testing",
)
async def ping() -> APIResponse:
    """Minimal ping endpoint for basic connectivity testing."""
    return APIResponse(
        status="ok",
        message="pong",
        timestamp=datetime.now(UTC),
    )


@router.get(
    "/status",
    summary="System Status & Metrics",
    description="Detailed system status information with optional component metrics",
)
async def get_status(
    include_redis: Annotated[bool, Query(description="Include Redis metrics")] = True,  # noqa: FBT002
    include_rclone: Annotated[bool, Query(description="Include rclone metrics")] = True,  # noqa: FBT002
) -> dict[str, Any]:
    """
    Get detailed system status and metrics.

    This endpoint provides comprehensive system information and is designed for
    monitoring and observability purposes.

    Args:
    ----
        include_redis: Whether to include Redis status and metrics
        include_rclone: Whether to include rclone status and metrics
    """
    status_data = get_system_status(
        check_redis=include_redis,
        check_rclone=include_rclone,
    )

    # Determine overall status based on component health
    overall_status = "healthy"
    components = status_data.get("components", {})
    if isinstance(components, dict):
        for component_data in components.values():
            if isinstance(component_data, dict) and component_data.get("status") == "error":
                overall_status = "unhealthy"
                break
            if isinstance(component_data, dict) and component_data.get("status") == "unavailable":
                overall_status = "degraded"

    # Create response dict with proper types
    timestamp_value = (
        status_data["timestamp"].isoformat()
        if isinstance(status_data["timestamp"], datetime)
        else status_data["timestamp"]
    )
    response_data: dict[str, Any] = {
        "overall_status": overall_status,
        "timestamp": timestamp_value,
        "uptime_seconds": status_data["uptime_seconds"],
        "components": components,
        "system": status_data["system"],
    }

    return response_data


@router.get(
    "/info",
    summary="System Information",
    description="Get comprehensive system and version information",
)
async def get_system_info() -> dict[str, Any]:
    """
    Get comprehensive system information including versions, paths, and server details.

    This endpoint combines version information with system details for a complete
    overview of the running system.
    """
    # Get rclone version
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
            "name": "Bitwarden Backup API",
            "version": "1.0.0",
            "build_date": "2025-01-01",
        },
        "server": {
            "time": datetime.now(UTC).isoformat(),
            "uptime_seconds": time.time() - startup_time,
            "backup_path": get_backup_path(),
        },
        "runtime": {
            "python": {
                "version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
                "implementation": sys.implementation.name,
            },
            "fastapi": {
                "version": fastapi.__version__,
            },
        },
        "tools": {
            "rclone": {
                "version": rclone_version,
                "available": rclone_version not in ["error", "unknown"],
            },
        },
    }


@router.post(
    "/maintenance/cache/clear",
    summary="Clear System Cache",
    description="Clear all cached data (use with caution in production)",
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

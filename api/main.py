import sys
import time
import uuid
from collections.abc import AsyncGenerator, Awaitable, Callable
from contextlib import asynccontextmanager
from typing import Any

import fastapi
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from .config import load_env, setup_rclone_config
from .routes import backups, remotes, system

# Global variables for tracking application state
start_time = time.time()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan events."""
    # Startup

    # Setup environment and rclone configuration
    try:
        load_env()
        setup_rclone_config()
    except Exception:
        sys.exit(1)

    # Store startup time
    app.state.start_time = time.time()

    yield

    # Shutdown


# Create FastAPI application with modern configuration
app = FastAPI(
    title="Bitwarden Backup API",
    description="""
    ## Bitwarden Vault Backup Management API

    A comprehensive API for managing Bitwarden vault backups across multiple cloud storage providers.

    ### Features
    - 🔄 Automated backup operations
    - ☁️ Multi-cloud storage support via rclone
    - 📊 Real-time monitoring and health checks
    - 🔍 Advanced search and filtering
    - 📈 Storage usage analytics
    - 🔐 Secure configuration management

    ### Authentication
    All endpoints require a valid API token passed via the `Authorization` header.

    ### Rate Limiting
    API calls are rate-limited to prevent abuse. See response headers for current limits.
    """,
    version="1.0.0",
    contact={
        "name": "Bitwarden Backup API Support",
        "url": "https://github.com/nikhilbadyal/bitwarden-backup/",
        "email": "support@example.com",
    },
    license_info={
        "name": "MIT",
        "url": "https://opensource.org/licenses/MIT",
    },
    openapi_tags=[
        {
            "name": "System",
            "description": "System health and information endpoints",
        },
        {
            "name": "Backups",
            "description": "Backup file management operations",
        },
        {
            "name": "Remotes",
            "description": "Remote storage provider management",
        },
    ],
    lifespan=lifespan,
    # Modern OpenAPI configuration
    openapi_url="/api/v1/openapi.json",
    docs_url="/api/v1/docs",
    redoc_url="/api/v1/redoc",
    # Security
    swagger_ui_parameters={
        "defaultModelsExpandDepth": 2,
        "defaultModelExpandDepth": 2,
        "displayRequestDuration": True,
        "filter": True,
        "showExtensions": True,
        "showCommonExtensions": True,
    },
)

# Add security middleware
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=["*"],  # Configure appropriately for production
)

# Configure CORS with more specific settings
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure appropriately for production
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["X-Request-ID", "X-Response-Time"],
)


# Custom middleware for request tracking and performance monitoring
@app.middleware("http")
async def add_request_metadata(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
    """Add request metadata and performance tracking."""
    request_start_time = time.time()

    # Generate request ID for tracking
    request_id = str(uuid.uuid4())

    # Add request ID to headers
    response: Response = await call_next(request)

    # Calculate response time
    response_time = time.time() - request_start_time

    # Add custom headers
    response.headers["X-Request-ID"] = request_id
    response.headers["X-Response-Time"] = f"{response_time:.3f}s"
    response.headers["X-API-Version"] = "1.0.0"

    return response


# Custom exception handlers
@app.exception_handler(ValidationError)
async def validation_exception_handler(_request: Request, exc: ValidationError) -> JSONResponse:
    """Handle Pydantic validation errors."""
    return JSONResponse(
        status_code=422,
        content={
            "status": "error",
            "message": "Validation failed",
            "details": exc.errors(),
            "timestamp": time.time(),
        },
    )


@app.exception_handler(HTTPException)
async def custom_http_exception_handler(_request: Request, exc: HTTPException) -> JSONResponse:
    """Enhanced HTTP exception handler."""
    # Create a simple, consistent response format
    content = {
        "status": "error",
        "message": str(exc.detail) if hasattr(exc, "detail") else "HTTP Exception",
        "status_code": exc.status_code,
        "timestamp": time.time(),
    }

    return JSONResponse(
        status_code=exc.status_code,
        content=content,
    )


@app.exception_handler(500)
async def internal_server_error_handler(_request: Request, _exc: Exception) -> JSONResponse:
    """Handle internal server errors."""
    return JSONResponse(
        status_code=500,
        content={
            "status": "error",
            "message": "Internal server error",
            "timestamp": time.time(),
        },
    )


# Root endpoint with API information
@app.get(
    "/",
    summary="API Root Information",
    description="Get basic information about the API",
    tags=["System"],
)
async def root() -> dict[str, Any]:
    """Get API root information."""
    return {
        "name": "Bitwarden Backup API",
        "version": "1.0.0",
        "description": "API for Bitwarden Vault Backup management",
        "docs": "/api/v1/docs",
        "redoc": "/api/v1/redoc",
        "openapi": "/api/v1/openapi.json",
        "health": "/health",
        "uptime_seconds": time.time() - start_time,
        "python_version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "fastapi_version": fastapi.__version__,
    }


# Include routers with API versioning
app.include_router(
    system.router,
    tags=["System"],
)

app.include_router(
    backups.router,
    prefix="/api/v1",
    tags=["Backups"],
)

app.include_router(
    remotes.router,
    prefix="/api/v1",
    tags=["Remotes"],
)


# Note: System endpoints are now consolidated in api/routes/system.py
# - /health - Health check with proper HTTP status codes
# - /ping - Simple connectivity test
# - /status - Detailed system status and metrics
# - /info - Comprehensive system information (replaces /version)
# - /maintenance/cache/clear - Clear system cache


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api.main:app",
        host="0.0.0.0",  # noqa: S104
        port=8000,
        reload=True,
        access_log=True,
        log_level="info",
    )

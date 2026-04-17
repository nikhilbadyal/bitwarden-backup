import base64
import os
import tempfile
from pathlib import Path

from dotenv import load_dotenv


def load_env() -> None:
    """Load environment variables from a .env file located two directories up."""
    env_path = Path(__file__).parent.parent / ".env"
    load_dotenv(dotenv_path=env_path)

def setup_rclone_config() -> None:
    """Set up the Rclone configuration from a base64 encoded environment variable."""
    try:
        b64 = os.environ["RCLONE_CONFIG_BASE64"]
    except KeyError as ke:
        msg = "Environment variable RCLONE_CONFIG_BASE64 is required but not set"
        raise RuntimeError(msg) from ke
    with tempfile.NamedTemporaryFile(mode="wb", delete=False, prefix="rclone-config-", suffix=".conf") as tmp:
        tmp.write(base64.b64decode(b64))
        tmp.flush()
        os.environ["PROJECT_RCLONE_CONFIG_FILE"] = tmp.name
        os.environ["RCLONE_CONFIG"] = tmp.name


def _parse_csv_env(name: str, default: str) -> list[str]:
    """Parse a comma-separated environment variable into a clean list."""
    # Read the raw value from the environment, with a safe default fallback.
    raw_value = os.environ.get(name, default)
    # Split by comma and trim whitespace so users can format values readably.
    parsed_values = [value.strip() for value in raw_value.split(",")]
    # Drop empty entries to avoid invalid middleware configuration.
    return [value for value in parsed_values if value]


# Changed signature to use keyword-only argument `*` before
# `default: bool` to fix the Ruff FBT001 warning.
def _parse_bool_env(name: str, *, default: bool) -> bool:
    """Parse a boolean environment variable using common truthy strings."""
    # Build a default string representation so callers can provide native bool defaults.
    default_value = "true" if default else "false"
    # Read and normalize the environment value for case-insensitive matching.
    raw_value = os.environ.get(name, default_value).strip().lower()
    # Return True only for explicit truthy values to avoid accidental enablement.
    return raw_value in {"1", "true", "yes", "on"}


def get_api_token() -> str:
    """Retrieve the API token from environment variables."""
    try:
        return os.environ["API_TOKEN"]
    except KeyError as ke:
        msg = "Environment variable API_TOKEN is required but not set"
        raise RuntimeError(msg) from ke

def get_redis_url() -> str:
    """Get the Redis URL from environment variables or return a default value."""
    try:
        return os.environ["REDIS_URL"]
    except KeyError as ke:
        msg = "Environment variable REDIS_URL is required but not set"
        raise RuntimeError(msg) from ke

def get_backup_path() -> str:
    """Get the backup path from environment variables or return a default value."""
    try:
        return os.environ["BACKUP_PATH"]
    except KeyError as ke:
        msg = "Environment variable BACKUP_PATH is required but not set"
        raise RuntimeError(msg) from ke

def get_encryption_password() -> str:
    """Get the encryption password from environment variables."""
    try:
        return os.environ["ENCRYPTION_PASSWORD"]
    except KeyError as ke:
        msg = "Environment variable ENCRYPTION_PASSWORD is required but not set"
        raise RuntimeError(msg) from ke

def get_scripts_dir() -> Path:
    """Get the scripts directory path."""
    return Path(__file__).parent.parent

def is_backup_decryption_allowed() -> bool:
    """Check if backup decryption operations are allowed via environment variable."""
    return os.environ.get("API_ALLOW_BACKUP_DECRYPTION", "false").lower() == "true"


def get_api_allowed_hosts() -> list[str]:
    """Return TrustedHostMiddleware allow-list values from environment configuration."""
    # Use explicit localhost defaults for local development safety.
    return _parse_csv_env("API_ALLOWED_HOSTS", "localhost,127.0.0.1")


def get_api_cors_origins() -> list[str]:
    """Return explicit CORS allowed origins from environment configuration."""
    # Use explicit local origins instead of wildcard to keep credentialed requests valid.
    return _parse_csv_env("API_CORS_ORIGINS", "http://localhost,http://localhost:3000,http://127.0.0.1:3000")


def get_api_cors_allow_credentials() -> bool:
    """Return whether CORS credentialed requests are enabled."""
    # Keep credential support enabled by default for token-bearing browser clients.
    # Used keyword argument syntax `default=True` to fix the
    # Ruff FBT003 warning (Boolean positional value in function call).
    return _parse_bool_env("API_CORS_ALLOW_CREDENTIALS", default=True)


def get_api_cors_allow_methods() -> list[str]:
    """Return explicit CORS methods to satisfy middleware wildcard restrictions."""
    # Keep methods explicit so configuration remains valid when credentials are enabled.
    return _parse_csv_env("API_CORS_ALLOW_METHODS", "GET,POST,PUT,DELETE,OPTIONS")


def get_api_cors_allow_headers() -> list[str]:
    """Return explicit CORS request headers to satisfy middleware wildcard restrictions."""
    # Keep headers explicit so configuration remains valid when credentials are enabled.
    return _parse_csv_env("API_CORS_ALLOW_HEADERS", "Authorization,Content-Type,Accept")


def get_api_cors_expose_headers() -> list[str]:
    """Return CORS response headers that browsers are allowed to read."""
    # Expose only operational headers needed by the UI.
    return _parse_csv_env("API_CORS_EXPOSE_HEADERS", "X-Request-ID,X-Response-Time,X-API-Version")


def validate_api_security_configuration() -> None:
    """Validate cross-setting security constraints before middleware initialization."""
    # Read the credential setting once so validation is deterministic.
    allow_credentials = get_api_cors_allow_credentials()
    # Read configured origins once so wildcard checks are deterministic.
    allowed_origins = get_api_cors_origins()
    # Read configured methods once so wildcard checks are deterministic.
    allowed_methods = get_api_cors_allow_methods()
    # Read configured headers once so wildcard checks are deterministic.
    allowed_headers = get_api_cors_allow_headers()

    # Enforce FastAPI/Starlette CORS rule that forbids wildcard with credentialed requests.
    if allow_credentials and (
        "*" in allowed_origins or "*" in allowed_methods or "*" in allowed_headers
    ):
        # Raise a clear startup error to prevent silently insecure runtime behavior.
        msg = (
            "Invalid CORS configuration: API_CORS_ALLOW_CREDENTIALS=true requires explicit "
            "API_CORS_ORIGINS, API_CORS_ALLOW_METHODS, and API_CORS_ALLOW_HEADERS (no '*')."
        )
        raise RuntimeError(msg)


def get_stream_token_ttl_seconds() -> int:
    """Return the short-lived SSE stream token TTL in seconds."""
    # Defined `min_ttl` as a named variable instead of a magic number to fix the Ruff PLR2004 warning.
    min_ttl = 30
    # Read configured value with a conservative default.
    raw_ttl = os.environ.get("API_STREAM_TOKEN_TTL_SECONDS", "120")
    try:
        # Convert to integer so Redis can consume the TTL directly.
        ttl_seconds = int(raw_ttl)
    except ValueError as exc:
        # Raise a clear startup error if the configured value is not a valid integer.
        msg = "Environment variable API_STREAM_TOKEN_TTL_SECONDS must be an integer"
        raise RuntimeError(msg) from exc
    # Enforce a minimum positive TTL to avoid immediately-expired tokens.
    if ttl_seconds < min_ttl:
        # Raise a clear startup error for misconfigured values that would break streaming UX.
        msg = f"Environment variable API_STREAM_TOKEN_TTL_SECONDS must be >= {min_ttl}"
        raise RuntimeError(msg)
    # Return the validated TTL for downstream usage.
    return ttl_seconds

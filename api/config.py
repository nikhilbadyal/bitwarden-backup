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

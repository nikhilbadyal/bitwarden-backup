from datetime import UTC, datetime

DEFAULT_MIN = datetime.min.replace(tzinfo=UTC)
DEFAULT_MAX = datetime.max.replace(tzinfo=UTC)

def parse_dt(s: str) -> datetime | None:
    """Parse a string into a datetime object, returning None if parsing fails."""
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None

class DeleteBackupError(Exception):
    """Exception raised when a backup deletion fails."""


class RefreshCacheError(Exception):
    """Exception raised when a cache refresh fails."""

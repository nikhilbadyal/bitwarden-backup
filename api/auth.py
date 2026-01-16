from typing import Annotated

from fastapi import Depends, HTTPException, Query
from fastapi.security import APIKeyHeader

from .config import get_api_token, is_backup_decryption_allowed

api_key_header = APIKeyHeader(name="Authorization", auto_error=False)


def get_token(api_key: str = Depends(api_key_header)) -> bool:
    """Dependency to validate API token from Authorization header."""
    if not api_key or api_key.replace("Bearer ", "") != get_api_token():
        raise HTTPException(status_code=401, detail="Invalid or missing token.")
    return True


def get_token_from_query(token: str = Query(default="", description="API token")) -> bool:
    """Dependency to validate API token from query parameter.

    Used for SSE endpoints where EventSource doesn't support custom headers.
    """
    if not token or token != get_api_token():
        raise HTTPException(status_code=401, detail="Invalid or missing token.")
    return True


def get_token_with_decryption_permission(
    _authenticated: Annotated[bool, Depends(get_token)],
) -> bool:
    """Dependency to validate API token and check if decryption operations are allowed."""
    if not is_backup_decryption_allowed():
        raise HTTPException(
            status_code=403,
            detail=(
                "Backup decryption operations are disabled. "
                "Set API_ALLOW_BACKUP_DECRYPTION=true to enable sensitive operations."
            ),
        )
    return True

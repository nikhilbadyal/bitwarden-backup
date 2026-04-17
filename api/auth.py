import hmac
from typing import Annotated

from fastapi import Depends, HTTPException
from fastapi.security import APIKeyHeader

from .config import get_api_token, is_backup_decryption_allowed

api_key_header = APIKeyHeader(name="Authorization", auto_error=False)


def get_token(api_key: str = Depends(api_key_header)) -> bool:
    """Dependency to validate API token from Authorization header."""
    # Reject missing authorization headers early to keep error handling clear.
    if not api_key:
        # Return a uniform authentication error for missing credentials.
        raise HTTPException(status_code=401, detail="Invalid or missing token.")
    # Normalize optional Bearer prefix without forcing strict client formatting.
    normalized_token = api_key.removeprefix("Bearer ").strip()
    # Compare tokens using constant-time comparison to reduce timing side channels.
    if not hmac.compare_digest(normalized_token, get_api_token()):
        # Return a uniform authentication error for invalid credentials.
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

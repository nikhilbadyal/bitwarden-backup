
from fastapi import Depends, HTTPException
from fastapi.security import APIKeyHeader

from .config import get_api_token

api_key_header = APIKeyHeader(name="Authorization", auto_error=False)


def get_token(api_key: str = Depends(api_key_header)) -> bool:
    """Dependency to validate API token from Authorization header."""
    if not api_key or api_key.replace("Bearer ", "") != get_api_token():
        raise HTTPException(status_code=401, detail="Invalid or missing token.")
    return True

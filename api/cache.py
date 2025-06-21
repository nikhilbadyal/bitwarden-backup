import redis

from api.config import get_redis_url


def get_redis_client() -> redis.Redis:
    """Get a Redis client instance."""
    return redis.Redis.from_url(get_redis_url(), decode_responses=True)

def clear_rclone_cache() -> None:
    """Clear the Rclone cache in Redis."""
    redis_client = get_redis_client()

    for key in redis_client.scan_iter("rclone_lsjson:*"):
        redis_client.delete(key)

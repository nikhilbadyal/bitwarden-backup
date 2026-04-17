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


def clear_application_cache() -> int:
    """Clear only this application's cache keys instead of flushing all Redis data."""
    # Create a dedicated Redis client for the cache clear transaction.
    redis_client = get_redis_client()
    # Track deleted keys for observability in API responses.
    deleted_keys = 0
    # Define prefix patterns owned by this application only.
    managed_prefix_patterns = (
        "rclone_lsjson:*",
        "backup_job:*",
        "backup_job_logs:*",
        "backup_job_stream_token:*",
    )
    # Iterate through each managed prefix so we never delete foreign application data.
    for pattern in managed_prefix_patterns:
        # Scan keys by prefix to avoid blocking Redis with KEYS.
        for key in redis_client.scan_iter(pattern):
            # Delete each matched key and accumulate successful deletion count.
            deleted_keys += int(redis_client.delete(key))
    # Delete singleton list key used for job indexing and include deletion in the count.
    deleted_keys += int(redis_client.delete("backup_jobs_list"))
    # Return deletion count so callers can report maintenance impact.
    return deleted_keys

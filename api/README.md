# Bitwarden Backup API

A FastAPI-based service for managing Bitwarden vault backups using rclone and remote storage providers.

## Features

- List, download, and delete Bitwarden backup files from any rclone-supported remote
- Trigger new backups and refresh backup cache
- Check health of API, Redis, and rclone
- List and test rclone remotes
- Get storage usage for a remote
- Bulk delete backup files
- Convert rclone config to base64 for scripting
- Secure token-based authentication
- CORS enabled for UI integration

## Endpoints

### Authentication

All endpoints (except `/health` and `/info`) require an `Authorization: Bearer <API_TOKEN>` header.

### Backups

- `GET /backups?remote=REMOTE` — List backup files (with filtering, pagination)
- `GET /backups/{remote}/{filename}` — Get metadata for a backup file
- `DELETE /backups/{remote}/{filename}` — Delete a backup file
- `POST /backups/{remote}/bulk-delete` — Bulk delete backup files (JSON: `{ "files": ["file1", "file2"] }`)
- `POST /backups/refresh_cache` — Refresh backup file cache for a remote
- `GET /download/{remote}/{filename}` — Download a backup file
- `POST /trigger-backup` — Trigger a new backup run

### Remotes

- `GET /remotes` — List available rclone remotes
- `GET /remotes/{remote}/check` — Check if a remote is reachable
- `GET /remotes/check-all` — Check all remotes for connectivity
- `GET /remotes/{remote}/usage` — Get storage usage for a remote

### System

- `GET /health` — Health check for API, Redis, and rclone
- `GET /info` — API version, server time, backup path

### Rclone Config

- `POST /rclone/config/base64` — Convert raw rclone config to base64 (plain text body)

## How to Run

### Prerequisites

- Python 3.11+
- Redis server
- rclone installed and configured

### Install dependencies

```sh
pip install -r api/requirements.txt
```

### Set environment variables (optional)

- `API_TOKEN` — API authentication token (default: `supersecrettoken`)
- `REDIS_URL` — Redis connection string (default: `redis://localhost:6379/0`)
- `BACKUP_PATH` — Path in remote for backups (default: `bitwarden-backup`)

### Start the API

```sh
uvicorn api.main:app --reload
```

### API Docs

Visit [http://localhost:8000/docs](http://localhost:8000/docs) for interactive Swagger UI.

## Example: Bulk Delete

```sh
curl -X POST \
  -H "Authorization: Bearer <API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"files": ["backup1.zip", "backup2.zip"]}' \
  http://localhost:8000/backups/myremote/bulk-delete
```

---

For more details, see the FastAPI docs or the code in `api/main.py`.

# Bitwarden Backup API Setup Guide

This document explains how to set up and run the Bitwarden Backup API using Docker.

## 🚀 Quick Start

### Prerequisites

- Docker and Docker Compose installed
- `.env` file configured (copy from `env.example`)

### Option 1: Using the Helper Script (Recommended)

```bash
# Make the script executable (if not already)
chmod +x run-api.sh

# Run the API
./run-api.sh
```

### Option 2: Using Docker Compose Directly

#### API with Redis (Recommended)

```bash
# Build and start the API service with Redis
docker-compose -f docker-compose.api.yml up --build -d

# View logs
docker-compose -f docker-compose.api.yml logs -f

# Stop the service
docker-compose -f docker-compose.api.yml down
```

#### Both API and Backup Services

```bash
# Build and start both services
docker-compose up --build -d

# View API logs
docker-compose logs -f bitwarden-backup-api

# View backup logs
docker-compose logs -f bitwarden-backup

# Stop all services
docker-compose down
```

## 🔧 Configuration

### Required Environment Variables

Create a `.env` file in the root directory with your configuration. Use `env.example` as a template.

**Core Backup Variables:**

- `BW_CLIENTID` - Your Bitwarden API Client ID
- `BW_CLIENTSECRET` - Your Bitwarden API Client Secret
- `BW_PASSWORD` - Your Bitwarden Master Password
- `ENCRYPTION_PASSWORD` - Strong password for backup encryption
- `RCLONE_CONFIG_BASE64` - Your base64-encoded rclone configuration

**API-Specific Variables:**

- `API_TOKEN` - Authentication token for API access (use a strong, random token)
- `REDIS_URL` - Redis connection URL (default: `redis://localhost:6379/0`)
- `BACKUP_PATH` - Remote path/bucket for storing backups (default: `bitwarden-backup`)

### Example .env Configuration

```bash
# Bitwarden credentials
BW_CLIENTID="user.1234567890abcdef"
BW_CLIENTSECRET="abcdef1234567890"
BW_PASSWORD="MySecretPassword123!"
ENCRYPTION_PASSWORD="BackupEncryption456!"
RCLONE_CONFIG_BASE64="W215LXMzXQp0eXBlID0gczMK..."

# API configuration
API_TOKEN="your_secure_random_api_token_here"
REDIS_URL="redis://localhost:6379/0"
BACKUP_PATH="bitwarden-backup"
```

### Port Configuration

The API runs on port `5050` by default. To change this:

1. Update the port mapping in `docker-compose.api.yml`:

   ```yaml
   ports:
     - "YOUR_PORT:5050"
   ```

2. Or set a custom port in the Dockerfile.api CMD section.

## 🌐 Available Endpoints

Once running, the API will be available at:

- **API Root**: <http://localhost:5050/>
- **API Documentation**: <http://localhost:5050/api/v1/docs>
- **ReDoc Documentation**: <http://localhost:5050/api/v1/redoc>
- **OpenAPI Schema**: <http://localhost:5050/api/v1/openapi.json>

### Authentication

All API endpoints (except health checks) require authentication using the `Authorization` header:

```bash
curl -H "Authorization: Bearer your_api_token" http://localhost:5050/api/v1/backups
```

### Key Endpoints

**System:**

- `GET /` - API root information
- `GET /api/v1/health` - Health check (API, Redis, rclone)
- `GET /api/v1/info` - System information

**Backups:**

- `GET /api/v1/backups` - List backup files
- `GET /api/v1/backups/{remote}/{filename}` - Get backup metadata
- `DELETE /api/v1/backups/{remote}/{filename}` - Delete a backup
- `POST /api/v1/backups/refresh_cache` - Refresh backup cache
- `GET /api/v1/download/{remote}/{filename}` - Download backup file

**Remotes:**

- `GET /api/v1/remotes` - List rclone remotes
- `GET /api/v1/remotes/{remote}/check` - Check remote connectivity
- `GET /api/v1/remotes/{remote}/usage` - Get storage usage

## 🏗️ Architecture

The API setup includes:

### Services

1. **bitwarden-backup-api** - The main API service
   - FastAPI application
   - Handles backup management
   - Provides REST endpoints

2. **redis** - Caching and session storage
   - Redis 7 Alpine image
   - Persistent data storage
   - Health monitoring

### File Structure

```
├── Dockerfile.api              # API-specific Dockerfile
├── docker-compose.api.yml      # API + Redis Docker Compose
├── docker-compose.yml          # Backup service Docker Compose
├── run-api.sh                  # Helper script to run API
├── API.md                      # This documentation
└── api/                        # API source code
    ├── main.py                 # FastAPI application
    ├── config.py               # Configuration management
    ├── auth.py                 # Authentication
    ├── cache.py                # Redis caching
    ├── models.py               # Data models
    ├── requirements.txt        # Python dependencies
    └── routes/                 # API route handlers
        ├── backups.py
        ├── remotes.py
        └── system.py
```

## 🛠️ Development

### Live Reload

The API container is configured with `--reload` for development. Changes to your code will automatically restart the server.

### Debugging

To run the container interactively for debugging:

```bash
docker-compose -f docker-compose.api.yml exec bitwarden-backup-api bash
```

### Building Only

To build the image without starting:

```bash
docker-compose -f docker-compose.api.yml build
```

### Logs

View API logs:

```bash
docker-compose -f docker-compose.api.yml logs -f bitwarden-backup-api
```

View Redis logs:

```bash
docker-compose -f docker-compose.api.yml logs -f redis
```

## 🔧 Troubleshooting

### API Won't Start

1. **Check .env file**: Ensure all required variables are set

   ```bash
   # Verify required variables
   grep -E "^(API_TOKEN|REDIS_URL|BW_CLIENTID)" .env
   ```

2. **Verify Docker**: `docker info`

3. **Check logs**: `docker-compose -f docker-compose.api.yml logs`

### Redis Connection Issues

1. **Check Redis health**:

   ```bash
   docker-compose -f docker-compose.api.yml exec redis redis-cli ping
   ```

2. **Verify Redis URL**: Ensure `REDIS_URL` points to the correct Redis instance

3. **Network connectivity**: Ensure services are on the same Docker network

### Authentication Errors

1. **Check API token**: Ensure `API_TOKEN` is set and matches your requests
2. **Header format**: Use `Authorization: Bearer your_token`
3. **Token security**: Use a strong, random token (not a simple password)

### Port Already in Use

If port 5050 is already in use:

1. Stop existing services: `docker ps` and `docker stop <container>`
2. Or change the port mapping in docker-compose.api.yml

### Permission Issues

The containers run as non-root users for security. If you encounter permission issues:

1. Ensure the `.env` file is readable: `chmod 644 .env`
2. Check Docker volume permissions

### Health Check Failures

The API includes comprehensive health checks. If they fail:

1. Wait longer for services to fully start (Redis takes ~10s, API ~40s)
2. Check individual service health:

   ```bash
   curl http://localhost:5050/api/v1/health
   ```

3. Review logs for startup errors

## 🚀 Production Considerations

For production deployment:

### Security

1. **Remove --reload** from Dockerfile.api CMD
2. **Use strong API tokens** (32+ random characters)
3. **Configure CORS** properly instead of allowing all origins
4. **Set up TLS/SSL** termination (nginx, Traefik, etc.)
5. **Use secrets management** instead of .env files
6. **Restrict network access** (firewall, VPC, etc.)

### Performance

1. **Configure resource limits** in Docker Compose:

   ```yaml
   deploy:
     resources:
       limits:
         cpus: '1.0'
         memory: 512M
   ```

2. **Redis persistence**: Configure appropriate persistence settings
3. **Log aggregation**: Set up centralized logging (ELK, Loki, etc.)
4. **Monitoring**: Add Prometheus metrics, health check monitoring

### Scaling

1. **Load balancing**: Multiple API instances behind a load balancer
2. **Redis clustering**: For high availability
3. **Backup storage**: Ensure your rclone remotes can handle the load

## 🔄 Migration from Direct uvicorn

If you were previously running:

```bash
uvicorn api.main:app --reload --host 0.0.0.0 --port 5050
```

You can now simply run:

```bash
./run-api.sh
```

The Docker setup provides the same functionality with additional benefits:

- ✅ **Isolated environment** - No dependency conflicts
- ✅ **Consistent deployment** - Works the same everywhere
- ✅ **Redis integration** - Built-in caching and session management
- ✅ **Health monitoring** - Comprehensive health checks
- ✅ **Security hardening** - Non-root containers, minimal permissions
- ✅ **Easy scaling** - Ready for production deployment

## 📚 API Usage Examples

### List Backups

```bash
curl -H "Authorization: Bearer your_api_token" \
  "http://localhost:5050/api/v1/backups?remote=s3-backup"
```

### Download Backup

```bash
curl -H "Authorization: Bearer your_api_token" \
  "http://localhost:5050/api/v1/download/s3-backup/bw_backup_20241218123456.json.gz.enc" \
  -o backup.enc
```

### Check System Health

```bash
curl "http://localhost:5050/api/v1/health"
```

### Trigger New Backup

```bash
curl -X POST -H "Authorization: Bearer your_api_token" \
  "http://localhost:5050/api/v1/trigger-backup"
```

For more examples, visit the interactive API documentation at <http://localhost:5050/api/v1/docs> when the API is running.

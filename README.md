# Bitwarden Vault Backup Script

**Configure once, forget forever.** Automated Bitwarden vault backups with **multi-remote cloud storage support**. Set up once and enjoy hands-free daily backups to multiple cloud services simultaneously (S3, Google Drive, Dropbox, OneDrive, Cloudflare R2, and 40+ others). **Supports both official Bitwarden and self-hosted servers.**

## 🚀 Quick Start (TL;DR)

### 1. Generate Rclone Config

```bash
# If you have this repo cloned:
./generate-rclone-base64.sh

# Interactive mode (create new config):
./generate-rclone-base64.sh --interactive

# Test config and save to file:
./generate-rclone-base64.sh --test --output my-config.txt

# Or manually create base64 from existing rclone config:
base64 -w 0 < ~/.config/rclone/rclone.conf
```

### 2. Minimal Configuration

Create a `.env` file with these **5 required variables**:

```bash
cat > .env << EOF
BW_CLIENTID=your_bitwarden_client_id
BW_CLIENTSECRET=your_bitwarden_client_secret
BW_PASSWORD=your_bitwarden_master_password
ENCRYPTION_PASSWORD=your_strong_encryption_password
RCLONE_CONFIG_BASE64=your_base64_encoded_rclone_config
EOF
```

### 3. Run Backup

**⚡ Fastest (No cloning required):**

```bash
docker run --rm --env-file .env --pull always \
  -e BITWARDENCLI_APPDATA_DIR=/tmp/bw_appdata \
  nikhilbadyal/bitwarden-backup:latest
```

**Or with Docker Compose:**

```bash
git clone https://github.com/nikhilbadyal/bitwarden-backup.git
cd bitwarden-backup
# Copy your .env file here
docker-compose up --build
```

**Or with scripts:**

```bash
./setup-rclone.sh && ./scripts/backup.sh
```

That's it! Your vault will be backed up to all configured remotes with encryption and compression.

## 🌐 API Management Interface

This project includes a **REST API** for managing your Bitwarden backups through a web interface or programmatic access.

### Quick API Setup

For detailed API setup instructions, Docker configuration, and usage examples, see:

**📖 [API.md](API.md) - Complete API Setup Guide**

**Quick Start:**

```bash
# Run the API with Docker
./run-api.sh

# Access the API
# - API Root: http://localhost:5050/
# - Documentation: http://localhost:5050/api/v1/docs
```

The API provides endpoints for:

- 📊 System health and monitoring
- 📁 Backup file management and listing
- ☁️ Remote storage provider management
- 🔍 Advanced search and filtering capabilities

---

## 📋 Detailed Documentation

### What This Does

This repository provides a **"configure once, forget forever"** solution for Bitwarden vault backups:

1. `setup-rclone.sh`: Configures rclone from a base64-encoded configuration to support **ANY rclone-compatible storage service**
2. `backup.sh`: Performs automated backup, validates, compresses, encrypts, and uploads to **ALL configured remotes** simultaneously
3. `generate-rclone-base64.sh`: Helper script to generate base64-encoded rclone configurations
4. `restore-backup.sh`: Decrypt and restore backup files back to plain JSON format

### Prerequisites

- A Bitwarden account with API access enabled (works with both official Bitwarden and self-hosted servers)
- Docker installed (recommended) OR `bw`, `jq`, `gzip`, `openssl`, `rclone` CLI tools installed
- Access to one or more cloud storage services with rclone support

### Alternative Installation Methods

**🔧 Full Setup (Clone Repository):**

```bash
git clone https://github.com/nikhilbadyal/bitwarden-backup.git
cd bitwarden-backup

# Generate rclone config
./generate-rclone-base64.sh

# Create .env file (copy from env.example)
cp env.example .env
# Edit .env with your values

# Run backup
./setup-rclone.sh && ./scripts/backup.sh
```

## 🔧 Configuration

### Required Environment Variables

| Variable               | Description                           | Example                       |
|:-----------------------|:--------------------------------------|:------------------------------|
| `BW_CLIENTID`          | Your Bitwarden API Client ID          | `user.1234567890abcdef`       |
| `BW_CLIENTSECRET`      | Your Bitwarden API Client Secret      | `abcdef1234567890`            |
| `BW_PASSWORD`          | Your Bitwarden Master Password        | `MySecretPassword123!`        |
| `ENCRYPTION_PASSWORD`  | Strong password for backup encryption | `BackupEncryption456!`        |
| `RCLONE_CONFIG_BASE64` | Base64-encoded rclone configuration   | `W215LXMzXQp0eXBlID0gczMK...` |

### API Configuration (Required for API service)

| Variable      | Description                            | Example                    |
|:--------------|:---------------------------------------|:---------------------------|
| `API_TOKEN`   | Authentication token for API access    | `your_secure_api_token`    |
| `REDIS_URL`   | Redis connection URL for caching       | `redis://localhost:6379/0` |
| `BACKUP_PATH` | Remote path/bucket for storing backups | `bitwarden-backup`         |

### Self-Hosted Bitwarden Support

This backup tool **fully supports self-hosted Bitwarden servers**! Configure your custom server using these optional environment variables:

| Variable           | Description                                   | Example                         |
|:-------------------|:----------------------------------------------|:--------------------------------|
| `BW_SERVER`        | **Primary server URL** (recommended approach) | `https://bitwarden.example.com` |
| `BW_WEB_VAULT`     | Custom web vault URL (advanced)               | `https://vault.example.com`     |
| `BW_API`           | Custom API URL (advanced)                     | `https://api.example.com`       |
| `BW_IDENTITY`      | Custom identity URL (advanced)                | `https://id.example.com`        |
| `BW_ICONS`         | Custom icons service URL (advanced)           | `https://icons.example.com`     |
| `BW_NOTIFICATIONS` | Custom notifications URL (advanced)           | `https://notify.example.com`    |
| `BW_EVENTS`        | Custom events URL (advanced)                  | `https://events.example.com`    |
| `BW_KEY_CONNECTOR` | Key Connector URL (for organizations)         | `https://keycon.example.com`    |

**Quick Examples:**

```bash
# For most self-hosted installations, just set BW_SERVER:
BW_SERVER="https://vault.mycompany.com"

# For Bitwarden EU cloud:
BW_SERVER="https://vault.bitwarden.eu"

# For complex custom setups (rarely needed):
BW_WEB_VAULT="https://vault.example.com"
BW_API="https://api.example.com"
BW_IDENTITY="https://identity.example.com"
```

**Important Notes:**
- Leave these variables empty or unset to use the official Bitwarden service
- `BW_SERVER` is the recommended approach for most self-hosted installations
- Individual service URLs (`BW_API`, `BW_IDENTITY`, etc.) override `BW_SERVER` if both are set
- All existing backup functionality works identically with self-hosted servers

### Optional Variables (Advanced)

<details>
<summary>Click to expand optional configuration</summary>

| Variable                 | Description                                | Default            |
|:-------------------------|:-------------------------------------------|:-------------------|
| `BACKUP_DIR`             | Temporary directory for backup files       | `/tmp/bw_backup`   |
| `BACKUP_PATH`            | Remote path/bucket for storing backups     | `bitwarden-backup` |
| `MIN_BACKUP_SIZE`        | Minimum backup size in bytes               | `1024`             |
| `COMPRESSION_LEVEL`      | Gzip compression level (1-9)               | `9`                |
| `RETENTION_COUNT`        | Number of backups to keep per remote       | `240`              |
| `BW_UNLOCK_RETRIES`      | Number of vault unlock attempts            | `3`                |
| `BW_UNLOCK_RETRY_DELAY`  | Seconds to wait between retry attempts     | `5`                |
| `PBKDF2_ITERATIONS`      | PBKDF2 iterations for encryption           | `600000`           |
| `BITWARDEN_SYNC_TIMEOUT` | Bitwarden sync timeout in seconds          | `60`               |
| `PARALLEL_THRESHOLD`     | Min remotes needed for parallel processing | `3`                |
| `MAX_PARALLEL_JOBS`      | Maximum parallel jobs for pruning          | `4`                |
| `APPRISE_URLS`           | Notification URLs (space-separated)        | None               |
| `BW_SERVER`              | Self-hosted Bitwarden server URL           | None               |
| `BW_WEB_VAULT`           | Custom web vault URL (advanced)            | None               |
| `BW_API`                 | Custom API URL (advanced)                  | None               |
| `BW_IDENTITY`            | Custom identity URL (advanced)             | None               |
| `BW_ICONS`               | Custom icons service URL (advanced)        | None               |
| `BW_NOTIFICATIONS`       | Custom notifications URL (advanced)        | None               |
| `BW_EVENTS`              | Custom events URL (advanced)               | None               |
| `BW_KEY_CONNECTOR`       | Key Connector URL (for organizations)      | None               |

**Important Notes:**

- `BACKUP_PATH`: For S3-compatible services, this becomes the bucket name. For other services, this is the folder path where backups are stored.
- `MIN_BACKUP_SIZE`: Backups smaller than this are considered invalid and the script will exit with an error.
- `PBKDF2_ITERATIONS`: Changes only affect new backups. Restore script automatically detects iteration count for backward compatibility.
- All scripts automatically load variables from `.env` file if it exists in the project root.

</details>

### 📋 What You Get (Features)

**Backup Features:**

- **Multi-Remote Support**: Backup to multiple cloud services simultaneously
- **Strong Encryption**: AES-256-CBC encryption with PBKDF2 (configurable, default 600,000 iterations) using your password
- **Zero-Disk Security**: Uses secure pipe-based processing - unencrypted vault data never touches disk
- **Smart Change Detection**: Only uploads when vault actually changes (SHA256 comparison)
- **Detailed Notifications**: Per-remote status in final notifications (success/failed/up-to-date)
- **Automatic Retries**: Handles network issues and API rate limiting for Bitwarden unlock
- **Secure Cleanup**: Logs out of Bitwarden and cleans temporary files
- **Cross-platform**: Supports Linux and macOS (different SHA256 utilities)

**Restore Features:**

- **Multi-Source Restore**: Decrypt local files or download from any remote
- **Backup Browsing**: List and browse backups across all storage services
- **Verification Pipeline**: Multi-stage validation (decryption → decompression → JSON validation)

---

## 🗂️ Detailed Documentation

### Supported Cloud Storage Services

This backup solution supports **ALL rclone-compatible storage services**, including:

**Object Storage:**

- Amazon S3, Google Cloud Storage, Azure Blob Storage
- Cloudflare R2, Backblaze B2, Wasabi, MinIO
- IBM Cloud Object Storage, Oracle Cloud Storage

**Consumer Cloud Storage:**

- Google Drive, Dropbox, OneDrive, Box
- pCloud, Mega, Yandex Disk, Mail.ru Cloud

**Enterprise Storage:**

- SFTP, FTP, WebDAV, HTTP
- Swift (OpenStack), Ceph, QingStor

**And many more!** See the [rclone documentation](https://rclone.org/) for the complete list.

## Example Multi-Remote Setup

Your rclone configuration can include multiple remotes:

```ini
[aws-s3]
type = s3
provider = AWS
access_key_id = AKIAIOSFODNN7EXAMPLE
secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region = us-east-1

[google-drive]
type = drive
client_id = 123456789.apps.googleusercontent.com
client_secret = abcdefghijklmnopqrstuvwx
token = {"access_token":"ya29.a0AfH6SMC..."}

[cloudflare-r2]
type = s3
provider = Cloudflare
access_key_id = your_r2_access_key
secret_access_key = your_r2_secret_key
endpoint = https://abc123.r2.cloudflarestorage.com

[dropbox-backup]
type = dropbox
token = {"access_token":"sl.B0abcdefghijklmnop..."}
```

The backup script will automatically:

1. Detect all 4 remotes
2. Upload your backup to ALL of them
3. Maintain separate retention policies for each
4. Track changes independently per remote

### Usage Examples

<details>
<summary>Click to expand usage examples</summary>

**Manual Backup (Scripts):**

```bash
./setup-rclone.sh && ./scripts/backup.sh
```

**Automated with Cron:**

```crontab
# Daily backup at 3:00 AM
0 3 * * * /path/to/bitwarden-backup/setup-rclone.sh && /path/to/bitwarden-backup/scripts/backup.sh >> /var/log/bitwarden_backup.log 2>&1
```

**Docker Compose:**

```bash
docker-compose up --build
```

**GitHub Actions Automation:**

1. Fork this repository
2. Add your environment variables as a repository secret named `BITWARDEN_BACKUP_ENV`
3. Automatic daily backups run at 2:00 AM UTC with free GitHub infrastructure
4. Includes pre-commit checks (shellcheck) and log artifact storage

</details>

## 🔄 Backup Restoration

The `restore-backup.sh` script allows you to decrypt and restore your encrypted backups back to plain JSON format.

### Quick Restore Examples

```bash
# Decrypt a local backup file
./restore-backup.sh bw_backup_20241218123456.json.gz.enc

# Download and decrypt latest backup from S3 remote
./restore-backup.sh -r s3-remote

# List all available backups from all configured remotes
./restore-backup.sh -l

# Decrypt with custom output filename
./restore-backup.sh -f backup.enc -o my_vault.json
```

### Restore Options

| Option            | Description                       | Example                |
|:------------------|:----------------------------------|:-----------------------|
| `-f, --file`      | Decrypt local backup file         | `--file backup.enc`    |
| `-r, --remote`    | Download & decrypt from remote    | `--remote s3-backup`   |
| `-o, --output`    | Custom output filename            | `--output vault.json`  |
| `-l, --list`      | List backups from all remotes     | `--list`               |
| `--list-remote`   | List backups from specific remote | `--list-remote gdrive` |
| `--download-only` | Download without decrypting       | `--download-only`      |

### Restoration Process

1. **🔍 Validation** - Checks file existence and encryption password
2. **🔓 Decryption** - Decrypts using AES-256-CBC with your password
3. **📦 Decompression** - Extracts gzip compressed data
4. **✅ JSON Validation** - Ensures valid Bitwarden vault format
5. **💾 Secure Save** - Saves with secure file permissions (600)
6. **🧹 Cleanup** - Removes temporary files

### Security Notes

- Restored JSON files contain **unencrypted vault data** - handle with care
- Files are created with secure permissions (owner read/write only)
- Temporary files are automatically cleaned up
- **Delete restored files** when no longer needed
- The same `ENCRYPTION_PASSWORD` from backups is required

### Advanced Features

<details>
<summary>Click to expand advanced features</summary>

**Detailed Backup Features:**

- **Multi-Remote Support**: Backup to multiple cloud storage services simultaneously (S3, Google Drive, Dropbox, OneDrive, Cloudflare R2, and 40+ others supported by rclone)
- **Base64 Configuration**: Accepts rclone config as base64 to avoid typing errors and enable easy deployment
- **Isolated Configuration**: Uses project-specific rclone config to avoid interfering with your global rclone setup
- **Multi-Stage Validation**: JSON validation, size checks, compression verification, and encryption testing
- **Encryption Verification**: Tests decryption and validates gzip format before upload
- **Intelligent Change Detection**: SHA256 hashing to avoid unnecessary uploads when vault hasn't changed
- **Independent Retention Management**: Per-remote retention policies based on configurable count
- **Optional Apprise Notifications**: Success and failure notifications
- **Automatic Retry Logic**: Handles transient network issues and API rate limiting for Bitwarden vault unlock
- **Robust Error Handling**: Individual remote failures don't stop the entire process
- **Secure Cleanup**: Logs out of Bitwarden and unsets sensitive environment variables

**Detailed Restore Features:**

- **Multi-Source Restore**: Decrypt local files or download directly from any configured remote
- **Backup Browsing**: List and browse available backups across all your cloud storage services
- **Verification Pipeline**: Multi-stage validation (decryption → decompression → JSON validation)
- **Secure Processing**: Temporary files with secure permissions and automatic cleanup
- **Flexible Output**: Custom output file names and locations
- **Download-Only Mode**: Download encrypted backups without decrypting (for manual processing)

</details>

## Logging and Monitoring

### Exit Codes

| Code | Meaning                               |
|:-----|:--------------------------------------|
| `0`  | Success                               |
| `1`  | Missing required environment variable |
| `2`  | Missing required dependency           |
| `3`  | Backup directory issue                |
| `4`  | Bitwarden login failed                |
| `5`  | Bitwarden vault unlock failed         |
| `6`  | Bitwarden data export failed          |
| `7`  | Invalid backup file                   |
| `8`  | Compression or encryption failed      |
| `99` | Unexpected error during upload        |

### Notifications

Configure [Apprise](https://github.com/caronc/apprise) for notifications:

```bash
# Multiple notification services
APPRISE_URLS="mailto://user@example.com tgram://bot_token/chat_id discord://webhook_id/webhook_token"
```

**Enhanced Notification Details:**

The final notification now includes detailed per-remote status:

**Success Notification Example:**

```
Bitwarden backup script completed successfully. New backup uploaded: bw_backup_20241218123456.json.gz.enc.

📊 Remote Status:
  ✅ aws-s3: Success
  ✅ google-drive: Up to date
  ❌ dropbox-backup: Failed
  ✅ cloudflare-r2: Success

📋 Summary: 📤 2 uploaded, ✅ 1 up-to-date, ❌ 1 failed
```

**No Changes Notification Example:**

```
Bitwarden backup script completed successfully. No changes detected, no new backup uploaded.

🔍 Remote Status:
  ✅ aws-s3: Up to date
  ✅ google-drive: Up to date
  ✅ cloudflare-r2: Up to date
```

**Failure Notification Example:**

```
Bitwarden backup script failed with exit code 8.
Reason: Compression or encryption failed. Check ENCRYPTION_PASSWORD.

⚠️ Remote Status at time of failure:
  ✅ aws-s3: Success
  ❌ google-drive: Failed
  ⏸️ dropbox-backup: Not processed
```

## Security Considerations

- **`.env` File**: Contains sensitive credentials. Set permissions to `chmod 600 .env`.
- **Backup Directory**: Set secure permissions `chmod 700` on backup directory.
- **Encryption Password**: Store securely and separately from backups. **Losing this password means losing access to your backups.**
- **Rclone Configuration**: Contains cloud storage credentials. The base64 encoding is for convenience, not security.
- **Multi-Remote Security**: Each remote should have appropriate access controls and encryption.

## Migration from R2-Only Version

If you're upgrading from the R2-only version:

1. **Keep your existing `.env`** - the new version is backward compatible
2. **Generate rclone config**: Use `./generate-rclone-base64.sh` to create `RCLONE_CONFIG_BASE64`
3. **Add the new variable** to your `.env` file
4. **Optional**: Remove old R2-specific variables (they're ignored now)
5. **Run the backup** - it will work with your existing R2 setup plus any new remotes

## Troubleshooting

### Common Issues

**"RCLONE_CONFIG_BASE64 contains invalid base64 data" (Docker Hub image only):**

There's a known issue with the Docker Hub image having stricter base64 validation than local builds. If your base64 works with local Docker Compose but fails with the Docker Hub image:

**Workaround 1: Use local build instead**

```bash
git clone https://github.com/nikhilbadyal/bitwarden-backup.git
cd bitwarden-backup
# Copy your .env file here
docker-compose up --build
```

**Workaround 2: Regenerate base64 (may help)**

```bash
base64 -w 0 < ~/.config/rclone/rclone.conf | tr -d '\n'
```

This issue is being investigated - the local build is currently more reliable.

**No remotes found:**

- Ensure `RCLONE_CONFIG_BASE64` is properly set
- Test your config: `./generate-rclone-base64.sh --test`

**Upload failures:**

- Check remote credentials and permissions
- Verify network connectivity
- Review rclone configuration syntax

**Permission errors:**

- Ensure scripts are executable: `chmod +x *.sh scripts/*.sh`
- Check backup directory permissions

**Bitwarden unlock failures:**

The script includes automatic retry logic for vault unlock failures. If you're experiencing frequent unlock issues:

- **Increase retry attempts**: Set `BW_UNLOCK_RETRIES=5` (default: 3)
- **Increase retry delay**: Set `BW_UNLOCK_RETRY_DELAY=10` (default: 5 seconds)
- **Check network connectivity** to Bitwarden servers
- **Verify your master password** is correct in the `BW_PASSWORD` variable
- **Check for API rate limiting** if running frequent backups

**🎉 Universal Architecture Support:**

The Docker image is built for **2 main architectures** and works universally:

- ✅ **linux/amd64** (Intel/AMD 64-bit: Most desktops, servers, cloud instances)
- ✅ **linux/arm64** (ARM 64-bit: Apple Silicon, Raspberry Pi 4/5, AWS Graviton)

**Manual Installation (without Docker):**

If running scripts directly on any system, install Bitwarden CLI via npm:

```bash
# Install Node.js and npm
sudo apt update && sudo apt install -y nodejs npm

# Install Bitwarden CLI globally
sudo npm install -g @bitwarden/cli

# Verify installation
bw --version
```

**Read-only filesystem errors with Bitwarden CLI:**

If you see errors like `EROFS: read-only file system, open '/home/backupuser/.config/Bitwarden CLI/data.json'`:

This happens when the Docker container runs with a read-only filesystem but Bitwarden CLI needs to write configuration files. The Docker Compose file already handles this, but for manual Docker runs, add:

```bash
docker run --rm --env-file .env -e BITWARDENCLI_APPDATA_DIR=/tmp/bw_appdata nikhilbadyal/bitwarden-backup:latest
```

**Using outdated Docker images:**

Docker may use cached local images instead of pulling the latest from Docker Hub. To ensure you're running the most recent version:

```bash
# Option 1: Use --pull always flag (recommended)
docker run --rm --env-file .env -e BITWARDENCLI_APPDATA_DIR=/tmp/bw_appdata --pull always nikhilbadyal/bitwarden-backup:latest

# Option 2: Manually pull first, then run
docker pull nikhilbadyal/bitwarden-backup:latest
docker run --rm --env-file .env -e BITWARDENCLI_APPDATA_DIR=/tmp/bw_appdata nikhilbadyal/bitwarden-backup:latest
```

**Note**: `docker-compose` automatically handles this with `pull_policy: always` in the compose file.

### Getting Help

1. **Check logs**: Review script output for specific error messages
2. **Test rclone**: Use `rclone ls remote:` to test connectivity
3. **Validate config**: Use the `--test` flag with the helper script
4. **Check dependencies**: Ensure all required tools are installed

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## License

This project is open source. Please check the license file for details.

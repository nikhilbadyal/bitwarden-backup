# Bitwarden Vault Backup Script

Automated Bitwarden vault backups with **multi-remote cloud storage support**. Backup to multiple cloud services simultaneously (S3, Google Drive, Dropbox, OneDrive, Cloudflare R2, and 40+ others).

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
docker run --rm --env-file .env --pull always --platform linux/amd64 \
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

---

## 📋 Detailed Documentation

### What This Does

This repository contains bash scripts for automated Bitwarden vault backups:

1. `setup-rclone.sh`: Configures rclone from a base64-encoded configuration to support **ANY rclone-compatible storage service**
2. `backup.sh`: Performs automated backup, validates, compresses, encrypts, and uploads to **ALL configured remotes** simultaneously
3. `generate-rclone-base64.sh`: Helper script to generate base64-encoded rclone configurations
4. `restore-backup.sh`: Decrypt and restore backup files back to plain JSON format

### Prerequisites

* A Bitwarden account with API access enabled
* Docker installed (recommended) OR `bw`, `jq`, `gzip`, `openssl`, `rclone` CLI tools installed
* Access to one or more cloud storage services with rclone support

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

### Optional Variables (Advanced)

<details>
<summary>Click to expand optional configuration</summary>

| Variable                | Description                            | Default            |
|:------------------------|:------doc       s   qs---------------------------------|:-------------------|
| `BACKUP_DIR`            | Temporary directory for backup files   | `/tmp/bw_backup`   |
| `BACKUP_PATH`           | Remote path/bucket for storing backups | `bitwarden-backup` |
| `MIN_BACKUP_SIZE`       | Minimum backup size in bytes           | `1024`             |
| `COMPRESSION_LEVEL`     | Gzip compression level (1-9)           | `9`                |
| `RETENTION_COUNT`       | Number of backups to keep per remote   | `240`              |
| `BW_UNLOCK_RETRIES`     | Number of vault unlock attempts        | `3`                |
| `BW_UNLOCK_RETRY_DELAY` | Seconds to wait between retry attempts | `5`                |
| `APPRISE_URLS`          | Notification URLs (space-separated)    | None               |

**Important Notes:**
- `BACKUP_PATH`: For S3-compatible services, this becomes the bucket name. For other services, this is the folder path where backups are stored.
- `MIN_BACKUP_SIZE`: Backups smaller than this are considered invalid and the script will exit with an error.
- All scripts automatically load variables from `.env` file if it exists in the project root.

</details>

### 📋 What You Get (Features)

**Backup Features:**

* **Multi-Remote Support**: Backup to multiple cloud services simultaneously
* **Strong Encryption**: AES-256-CBC encryption with PBKDF2 (100,000 iterations) using your password
* **Smart Change Detection**: Only uploads when vault actually changes (SHA256 comparison)
* **Detailed Notifications**: Per-remote status in final notifications (success/failed/up-to-date)
* **Automatic Retries**: Handles network issues and API rate limiting for Bitwarden unlock
* **Secure Cleanup**: Logs out of Bitwarden and cleans temporary files
* **Cross-platform**: Supports Linux and macOS (different SHA256 utilities)

**Restore Features:**

* **Multi-Source Restore**: Decrypt local files or download from any remote
* **Backup Browsing**: List and browse backups across all storage services
* **Verification Pipeline**: Multi-stage validation (decryption → decompression → JSON validation)

---

## 🗂️ Detailed Documentation

### Supported Cloud Storage Services

This backup solution supports **ALL rclone-compatible storage services**, including:

**Object Storage:**

* Amazon S3, Google Cloud Storage, Azure Blob Storage
* Cloudflare R2, Backblaze B2, Wasabi, MinIO
* IBM Cloud Object Storage, Oracle Cloud Storage

**Consumer Cloud Storage:**

* Google Drive, Dropbox, OneDrive, Box
* pCloud, Mega, Yandex Disk, Mail.ru Cloud

**Enterprise Storage:**

* SFTP, FTP, WebDAV, HTTP
* Swift (OpenStack), Ceph, QingStor

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

| Option | Description | Example |
|:-------|:------------|:--------|
| `-f, --file` | Decrypt local backup file | `--file backup.enc` |
| `-r, --remote` | Download & decrypt from remote | `--remote s3-backup` |
| `-o, --output` | Custom output filename | `--output vault.json` |
| `-l, --list` | List backups from all remotes | `--list` |
| `--list-remote` | List backups from specific remote | `--list-remote gdrive` |
| `--download-only` | Download without decrypting | `--download-only` |

### Restoration Process

1. **🔍 Validation** - Checks file existence and encryption password
2. **🔓 Decryption** - Decrypts using AES-256-CBC with your password
3. **📦 Decompression** - Extracts gzip compressed data
4. **✅ JSON Validation** - Ensures valid Bitwarden vault format
5. **💾 Secure Save** - Saves with secure file permissions (600)
6. **🧹 Cleanup** - Removes temporary files

### Security Notes

* Restored JSON files contain **unencrypted vault data** - handle with care
* Files are created with secure permissions (owner read/write only)
* Temporary files are automatically cleaned up
* **Delete restored files** when no longer needed
* The same `ENCRYPTION_PASSWORD` from backups is required

### Advanced Features

<details>
<summary>Click to expand advanced features</summary>

**Detailed Backup Features:**

* **Multi-Remote Support**: Backup to multiple cloud storage services simultaneously (S3, Google Drive, Dropbox, OneDrive, Cloudflare R2, and 40+ others supported by rclone)
* **Base64 Configuration**: Accepts rclone config as base64 to avoid typing errors and enable easy deployment
* **Isolated Configuration**: Uses project-specific rclone config to avoid interfering with your global rclone setup
* **Multi-Stage Validation**: JSON validation, size checks, compression verification, and encryption testing
* **Encryption Verification**: Tests decryption and validates gzip format before upload
* **Intelligent Change Detection**: SHA256 hashing to avoid unnecessary uploads when vault hasn't changed
* **Independent Retention Management**: Per-remote retention policies based on configurable count
* **Optional Apprise Notifications**: Success and failure notifications
* **Automatic Retry Logic**: Handles transient network issues and API rate limiting for Bitwarden vault unlock
* **Robust Error Handling**: Individual remote failures don't stop the entire process
* **Secure Cleanup**: Logs out of Bitwarden and unsets sensitive environment variables

**Detailed Restore Features:**

* **Multi-Source Restore**: Decrypt local files or download directly from any configured remote
* **Backup Browsing**: List and browse available backups across all your cloud storage services
* **Verification Pipeline**: Multi-stage validation (decryption → decompression → JSON validation)
* **Secure Processing**: Temporary files with secure permissions and automatic cleanup
* **Flexible Output**: Custom output file names and locations
* **Download-Only Mode**: Download encrypted backups without decrypting (for manual processing)

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

Configure Apprise for notifications:

```bash
# Multiple notification services
APPRISE_URLS="mailto://user@example.com tgram://bot_token/chat_id discord://webhook_id/webhook_token"
```

**Enhanced Notification Details:**

The final notification now includes detailed per-remote status:

**Success Notification Example:**
```
Bitwarden backup script completed successfully. New backup uploaded: bw_backup_20241218123456.json.gz.enc.

Remote Status:
  ✓ aws-s3: Success
  ✓ google-drive: Up to date
  ✗ dropbox-backup: Failed
  ✓ cloudflare-r2: Success

Summary: 2 uploaded, 1 up-to-date, 1 failed
```

**No Changes Notification Example:**
```
Bitwarden backup script completed successfully. No changes detected, no new backup uploaded.

Remote Status:
  ✓ aws-s3: Up to date
  ✓ google-drive: Up to date
  ✓ cloudflare-r2: Up to date
```

**Failure Notification Example:**
```
Bitwarden backup script failed with exit code 8.
Reason: Compression or encryption failed. Check ENCRYPTION_PASSWORD.

Remote Status at time of failure:
  ✓ aws-s3: Success
  ✗ google-drive: Failed
  ? dropbox-backup: Not processed
```

## Security Considerations

* **`.env` File**: Contains sensitive credentials. Set permissions to `chmod 600 .env`.
* **Backup Directory**: Set secure permissions `chmod 700` on backup directory.
* **Encryption Password**: Store securely and separately from backups. **Losing this password means losing access to your backups.**
* **Rclone Configuration**: Contains cloud storage credentials. The base64 encoding is for convenience, not security.
* **Multi-Remote Security**: Each remote should have appropriate access controls and encryption.

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

* Ensure `RCLONE_CONFIG_BASE64` is properly set
* Test your config: `./generate-rclone-base64.sh --test`

**Upload failures:**

* Check remote credentials and permissions
* Verify network connectivity
* Review rclone configuration syntax

**Permission errors:**

* Ensure scripts are executable: `chmod +x *.sh scripts/*.sh`
* Check backup directory permissions

**Bitwarden unlock failures:**

The script includes automatic retry logic for vault unlock failures. If you're experiencing frequent unlock issues:

* **Increase retry attempts**: Set `BW_UNLOCK_RETRIES=5` (default: 3)
* **Increase retry delay**: Set `BW_UNLOCK_RETRY_DELAY=10` (default: 5 seconds)
* **Check network connectivity** to Bitwarden servers
* **Verify your master password** is correct in the `BW_PASSWORD` variable
* **Check for API rate limiting** if running frequent backups

**Platform warnings (Apple Silicon/M1/M2 Macs):**

If you see warnings like "The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8)":

```bash
# Add --platform flag to specify architecture
docker run --rm --env-file .env --platform linux/amd64 nikhilbadyal/bitwarden-backup:latest
```

This warning is cosmetic and doesn't affect functionality, but the flag eliminates the warning.

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
docker run --rm --env-file .env --pull always nikhilbadyal/bitwarden-backup:latest

# Option 2: Manually pull first, then run
docker pull nikhilbadyal/bitwarden-backup:latest
docker run --rm --env-file .env nikhilbadyal/bitwarden-backup:latest
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

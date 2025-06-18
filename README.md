# Bitwarden Vault Backup Script

This repository contains bash scripts for automated Bitwarden vault backups with **multi-remote cloud storage support**:

1. `setup-rclone.sh`: Configures rclone from a base64-encoded configuration to support **ANY rclone-compatible storage service** (not just Cloudflare R2). This script only needs to be run *once* initially or when your configuration changes.
2. `backup.sh`: Performs automated backup of a Bitwarden vault, validates, compresses, encrypts, and uploads to **ALL configured remotes** simultaneously.
3. `generate-rclone-base64.sh`: Helper script to generate base64-encoded rclone configurations.
4. `restore-backup.sh`: Decrypt and restore backup files back to plain JSON format for disaster recovery or vault migration.

## Features

### **Backup Features**

* **Multi-Remote Support**: Backup to multiple cloud storage services simultaneously (S3, Google Drive, Dropbox, OneDrive, Cloudflare R2, and 40+ others supported by rclone).
* **Base64 Configuration**: Accepts rclone config as base64 to avoid typing errors and enable easy deployment.
* **Isolated Configuration**: Uses project-specific rclone config to avoid interfering with your global rclone setup.
* Automated Bitwarden vault backup via API key.
* **Multi-Stage Validation**: JSON validation, size checks, compression verification, and encryption testing.
* Gzip compression of the backup file.
* Strong encryption of the compressed backup using OpenSSL (AES-256-CBC) with a user-provided password.
* **Encryption Verification**: Tests decryption and validates gzip format before upload.
* Intelligent change detection to avoid unnecessary uploads when vault hasn't changed.
* Independent retention management per remote based on configurable count.
* **Optional Apprise notifications on success and failure.**
* Robust error handling and logging.
* Secure cleanup process that logs out of Bitwarden and unsets sensitive environment variables.

### **🆕 Restore Features**

* **Multi-Source Restore**: Decrypt local files or download directly from any configured remote.
* **Backup Browsing**: List and browse available backups across all your cloud storage services.
* **Verification Pipeline**: Multi-stage validation (decryption → decompression → JSON validation).
* **Secure Processing**: Temporary files with secure permissions and automatic cleanup.
* **Flexible Output**: Custom output file names and locations.
* **Download-Only Mode**: Download encrypted backups without decrypting (for manual processing).

## Prerequisites

* A Bitwarden account with API access enabled.
* The `bw` CLI installed and configured for server URL if not using the default.
* `jq` installed for JSON validation.
* `gzip` installed for compression.
* `openssl` installed for encryption and decryption verification.
* `rclone` installed for cloud storage operations.
* Access to one or more cloud storage services with rclone support.
* `apprise` installed (if using notifications).
* A `.env` file containing all required environment variables (see Configuration section).
* A suitable directory for storing temporary backup files (default is `/tmp/bw_backup`).

## Quick Start

### 1. Generate Your Rclone Configuration

**Option A: From existing rclone config**

```bash
./generate-rclone-base64.sh
```

**Option B: Interactive configuration**

```bash
./generate-rclone-base64.sh --interactive
```

**Option C: Test and save to file**

```bash
./generate-rclone-base64.sh --test --output my-config.txt
```

### 2. Create Your .env File

Copy `env.example` to `.env` and fill in your credentials:

```bash
cp env.example .env
# Edit .env with your values
```

**Note:** All scripts automatically load environment variables from `.env` if the file exists in the project root. No need to manually source or export variables!

### 3. Run the Backup

**Using Scripts:**

```bash
./setup-rclone.sh && ./scripts/backup.sh
```

**Using Docker:**

```bash
docker-compose up --build
```

## Configuration (Environment Variables)

### Required Variables

| Variable               | Description                           | Example                       |
|:-----------------------|:--------------------------------------|:------------------------------|
| `BW_CLIENTID`          | Your Bitwarden API Client ID          | `user.1234567890abcdef`       |
| `BW_CLIENTSECRET`      | Your Bitwarden API Client Secret      | `abcdef1234567890`            |
| `BW_PASSWORD`          | Your Bitwarden Master Password        | `MySecretPassword123!`        |
| `ENCRYPTION_PASSWORD`  | Strong password for backup encryption | `BackupEncryption456!`        |
| `RCLONE_CONFIG_BASE64` | Base64-encoded rclone configuration   | `W215LXMzXQp0eXBlID0gczMK...` |

### Optional Variables

| Variable            | Description                          | Default          |
|:--------------------|:-------------------------------------|:-----------------|
| `BACKUP_DIR`        | Temporary directory for backup files | `/tmp/bw_backup` |
| `MIN_BACKUP_SIZE`   | Minimum backup size in bytes         | `1024`           |
| `COMPRESSION_LEVEL` | Gzip compression level (1-9)         | `9`              |
| `RETENTION_COUNT`   | Number of backups to keep per remote | `240`            |
| `APPRISE_URLS`      | Notification URLs (space-separated)  | None             |

### Legacy Variables (No Longer Used)

The following R2-specific variables have been replaced by the multi-remote system:

* `RCLONE_R2_REMOTE_NAME`
* `RCLONE_R2_BUCKET_NAME`
* `RCLONE_R2_ENDPOINT`
* `RCLONE_R2_ACCESS_KEY_ID`
* `RCLONE_R2_SECRET_ACCESS_KEY`
* `R2_RETENTION_COUNT`

## Supported Cloud Storage Services

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

## Usage

### Manual Backup

```bash
# Setup rclone configuration (run once)
./setup-rclone.sh

# Run backup
./scripts/backup.sh
```

Both scripts automatically load your `.env` file, so you just need to ensure it exists in the project root.

### Automated with Cron

Add to your crontab (`crontab -e`):

```crontab
# Daily backup at 3:00 AM
0 3 * * * /path/to/bitwarden-backup/setup-rclone.sh && /path/to/bitwarden-backup/scripts/backup.sh >> /var/log/bitwarden_backup.log 2>&1
```

### Docker Deployment

**Docker Compose (Recommended):**

```bash
docker-compose up --build
```

**Direct Docker Run:**

```bash
docker run --rm --env-file .env nikhilbadyal/bitwarden-backup
```

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

## Advanced Features

### Change Detection

The script uses SHA256 hashing to detect changes in your vault:

* If no changes are detected across ANY remote, the backup is skipped
* If changes are found on ANY remote, a new backup is created and uploaded to ALL remotes
* This ensures consistency across all your storage locations

### Retention Management

Each remote maintains its own retention policy:

* Configurable via `RETENTION_COUNT` (default: 240 backups)
* Old backups are automatically pruned from each remote
* Retention is applied independently to each storage service

### Error Handling

The script provides comprehensive error handling:

* Individual remote failures don't stop the entire process
* Detailed logging shows which remotes succeeded/failed
* Specific exit codes for different failure scenarios
* Automatic cleanup of temporary files

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

### Getting Help

1. **Check logs**: Review script output for specific error messages
2. **Test rclone**: Use `rclone ls remote:` to test connectivity
3. **Validate config**: Use the `--test` flag with the helper script
4. **Check dependencies**: Ensure all required tools are installed

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## License

This project is open source. Please check the license file for details.

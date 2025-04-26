# Bitwarden Vault Backup Script

This repository contains two bash scripts:
1.  `setup-rclone.sh`: Configures `rclone` specifically for Cloudflare R2 storage using environment variables. This script only needs to be run *once* initially or when your R2 configuration changes.
2.  `backup.sh`: Performs an automated backup of a Bitwarden vault using the `bw` CLI, validates the export, compresses and encrypts it, uploads it to the configured R2 bucket using `rclone`, and prunes old backups from R2 based on a retention count.

## Features

* Automated Bitwarden vault backup via API key.
* Validation of the exported JSON data (format and minimum size).
* Gzip compression of the backup file.
* Strong encryption of the compressed backup using OpenSSL (AES-256-CBC) with a user-provided password.
* Verification of the encryption by attempting decryption and checking for valid gzip format.
* Uploads the encrypted backup to Cloudflare R2 storage using `rclone`.
* Prunes old backups from the R2 bucket based on a configurable retention count.
* Robust error handling and logging.
* Secure cleanup process that logs out of Bitwarden and unsets sensitive environment variables.

## Prerequisites

* A Bitwarden account with API access enabled.
* The `bw` CLI installed and configured for server URL if not using the default.
* `jq` installed for JSON validation.
* `gzip` installed for compression.
* `openssl` installed for encryption and decryption verification.
* `rclone` installed for uploading to R2 and pruning.
* Access to a Cloudflare R2 bucket and its necessary credentials (Endpoint, Access Key ID, Secret Access Key).
* A `.env` file containing all required environment variables (see Configuration section).
* A suitable directory for storing temporary and final backup files before upload (default is `/backup`). The script requires write permissions to this directory.

## Setup

1.  **Clone or download** the scripts.
2.  **Create a `.env` file** in the same directory as the scripts. This file will hold your sensitive configuration variables. **Secure this file appropriately!**
    ```dotenv
    # .env file
    BW_CLIENTID="your_bitwarden_client_id"
    BW_CLIENTSECRET="your_bitwarden_client_secret"
    BW_PASSWORD="your_bitwarden_master_password" # Used for vault unlock

    # Encryption password for the backup file
    ENCRYPTION_PASSWORD="a_strong_unique_encryption_password"

    # Rclone configuration for Cloudflare R2
    RCLONE_R2_REMOTE_NAME="my-r2-remote" # A name you choose for the rclone remote
    RCLONE_R2_BUCKET_NAME="your-r2-bucket-name"
    RCLONE_R2_ENDPOINT="your-r2-endpoint-url" # e.g., https://<account_id>.r2.cloudflarestorage.com
    RCLONE_R2_ACCESS_KEY_ID="your_r2_access_key_id"
    RCLONE_R2_SECRET_ACCESS_KEY="your_r2_secret_access_key"

    # Optional: Customize backup directory (default: /backup)
    # BACKUP_DIR="/path/to/your/backup/storage"

    # Optional: Customize minimum backup size check (default: 100000 bytes)
    # MIN_BACKUP_SIZE="200000"

    # Optional: Customize gzip compression level (1-9, default: 9)
    # COMPRESSION_LEVEL="6"

    # Optional: Customize R2 retention count (default: 240 backups)
    # R2_RETENTION_COUNT="180"
    ```
3.  **Run `setup-rclone.sh`**: This script reads the R2 variables from `.env` and creates/updates the `rclone.conf` file. This only needs to be done once.
    ```bash
    ./setup-rclone.sh
    ```
4.  **Ensure required dependencies are installed** (`bw`, `jq`, `gzip`, `openssl`, `rclone`).
5.  **Set appropriate permissions** for the scripts (e.g., `chmod +x setup-rclone.sh backup.sh`).

## Configuration (Environment Variables)

The scripts rely on environment variables, typically loaded from the `.env` file by `setup-rclone.sh` and `backup.sh`.

| Variable                    | Script(s)           | Description                                                                                                | Default        | Required |
| :-------------------------- | :------------------ | :--------------------------------------------------------------------------------------------------------- | :------------- | :------- |
| `BW_CLIENTID`               | `backup.sh`         | Your Bitwarden API Client ID.                                                                              | None           | Yes      |
| `BW_CLIENTSECRET`           | `backup.sh`         | Your Bitwarden API Client Secret.                                                                          | None           | Yes      |
| `BW_PASSWORD`               | `backup.sh`         | Your Bitwarden Master Password. Used to unlock the vault.                                                  | None           | Yes      |
| `ENCRYPTION_PASSWORD`       | `backup.sh`         | A strong, unique password used to encrypt the compressed backup file. **CRITICAL: Do not lose this!** | None           | Yes      |
| `BACKUP_DIR`                | `backup.sh`         | The directory where the backup files will be stored before upload.                                         | `/backup`      | No       |
| `MIN_BACKUP_SIZE`           | `backup.sh`         | Minimum expected size (in bytes) of the raw JSON backup file for validation.                               | `100000`       | No       |
| `COMPRESSION_LEVEL`         | `backup.sh`         | Gzip compression level (1-9). 9 is maximum compression.                                                  | `9`            | No       |
| `RCLONE_R2_REMOTE_NAME`     | `setup-rclone.sh`, `backup.sh` | The name given to the R2 remote in the `rclone.conf` file. Must match in both scripts/env.               | None           | Yes      |
| `RCLONE_R2_BUCKET_NAME`     | `setup-rclone.sh`, `backup.sh` | The name of your Cloudflare R2 bucket.                                                                     | None           | Yes      |
| `RCLONE_R2_ENDPOINT`        | `setup-rclone.sh`   | The S3 endpoint URL for your Cloudflare R2 bucket (e.g., `https://<account_id>.r2.cloudflarestorage.com`). | None           | Yes      |
| `RCLONE_R2_ACCESS_KEY_ID`   | `setup-rclone.sh`   | Your Cloudflare R2 Access Key ID.                                                                          | None           | Yes      |
| `RCLONE_R2_SECRET_ACCESS_KEY` | `setup-rclone.sh`   | Your Cloudflare R2 Secret Access Key.                                                                      | None           | Yes      |
| `R2_RETENTION_COUNT`        | `backup.sh`         | The number of the *most recent* backups to keep in the R2 bucket. Older backups will be pruned.            | `240`          | No       |

## Usage

1.  Ensure you have completed the [Setup](#setup) steps.
2.  Run the `backup.sh` script:
    ```bash
    ./scripts/backup.sh
    ```
    The script will output its progress to stderr.

3.  **Automation with Cron:** It is highly recommended to automate this process using cron. Edit your crontab (`crontab -e`) and add a line like this (adjust the path and schedule as needed):
    ```crontab
    # Example: Run daily at 3:00 AM
    0 3 * * * /path/to/your/backup.sh >> /var/log/bitwarden_backup.log 2>&1
    ```
    **Note:** Ensure your cron environment has access to the necessary commands (`bw`, `jq`, `gzip`, `openssl`, `rclone`) and the `.env` file (the script handles loading `.env` if located in the same directory). You might need to specify the full path to the script and ensure the user running the cron job has the necessary permissions.

## Logging

The script outputs informational, warning, and error messages to standard error (stderr). You can redirect stderr to a log file when running via cron or manually. It also includes optional integration with `logger` for syslog if the command is available.

## Cleanup

The script uses a `trap cleanup EXIT INT TERM` to ensure that a `cleanup` function is executed whenever the script exits (either successfully, due to an error, or upon receiving INT/TERM signals). This function attempts to log out of the Bitwarden CLI and securely unsets sensitive environment variables (`BW_SESSION`, `BW_CLIENTID`, `BW_CLIENTSECRET`, `BW_PASSWORD`).

## Security Considerations

* **`.env` File:** The `.env` file contains highly sensitive information (Bitwarden credentials, R2 keys, encryption password). **Secure this file strictly.** Ensure only the user running the script can read it (`chmod 600 .env`). Do not store it in a publicly accessible location.
* **Backup Directory:** The `BACKUP_DIR` contains the backup files before encryption and upload. Ensure this directory has strict permissions (`chmod 700 /path/to/backup`).
* **Encryption Password:** The `ENCRYPTION_PASSWORD` is the sole key to decrypting your backups. Store this password securely, separate from the backup files themselves. Losing this password means losing access to your backups.
* **R2 Bucket Security:** Configure appropriate access policies and permissions on your Cloudflare R2 bucket to restrict access.

## Exit Codes

The `backup.sh` script uses specific exit codes to indicate the result:

* `0`: Success
* `1`: Missing required environment variable
* `2`: Missing required dependency (`bw`, `jq`, `gzip`, `openssl`, or `rclone`)
* `3`: Backup directory issue (creation or permissions)
* `4`: Bitwarden login failed
* `5`: Bitwarden vault unlock failed
* `6`: Bitwarden data export failed
* `7`: Invalid backup file (empty, too small, or invalid JSON/encryption)
* `8`: Compression or Encryption failed
* `99`: Unexpected error during rclone upload
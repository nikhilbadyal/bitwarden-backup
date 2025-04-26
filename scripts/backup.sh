#!/usr/bin/env bash

# Bitwarden Vault Backup Script
# Backs up a Bitwarden vault using the bw CLI and API key,
# validates the export, compresses it, and prunes old backups.

# --- Strict Mode ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error and exit immediately.
# Exit immediately if any command in a pipeline fails.
set -euo pipefail
# Use nullglob so glob patterns that match no files expand to nothing.
# This is useful in find commands or loops.
# shopt -s nullglob # Can add this for extra robustness in some scenarios
# Split only on newlines and tabs, preserving spaces in filenames.
IFS=$'\n\t'

# --- Constants ---
readonly BACKUP_DIR="${BACKUP_DIR:-/backup}"
readonly RETENTION_DAYS="${RETENTION_DAYS:-60}"
readonly MIN_BACKUP_SIZE="${MIN_BACKUP_SIZE:-100000}"  # 1KB minimum size check
readonly COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-9}"  # Max gzip compression

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_MISSING_VAR=1
readonly EXIT_MISSING_DEP=2
readonly EXIT_BACKUP_DIR=3
readonly EXIT_LOGIN_FAILED=4
readonly EXIT_UNLOCK_FAILED=5
readonly EXIT_EXPORT_FAILED=6
readonly EXIT_INVALID_BACKUP=7
readonly EXIT_COMPRESS_FAILED=8
readonly EXIT_UNEXPECTED=99

# Colors for logging
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;37m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[1;31m"
readonly COLOR_SUCCESS="\033[1;32m"
readonly COLOR_DEBUG="\033[0;34m"

# --- Variables ---
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
RAW_FILE="${BACKUP_DIR}/bw_backup_${TIMESTAMP}.json"
COMPRESSED_FILE=""
export NODE_NO_DEPRECATION=1
# --- Logging Function ---
log() {
    local level=$1
    shift
    local color=""
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO) color="$COLOR_INFO" ;;
        WARN) color="$COLOR_WARN" ;;
        ERROR) color="$COLOR_ERROR" ;;
        SUCCESS) color="$COLOR_SUCCESS" ;;
        *) level="DEBUG"; color="$COLOR_DEBUG" ;;
    esac

    printf "%b[%s %s]%b %s\n" "$color" "$timestamp" "$level" "$COLOR_RESET" "$message" >&2

    # Optional syslog integration
    if command -v logger >/dev/null 2>&1; then
        logger -t "bw_backup" "[$level] $message" || true
    fi
}

# Function to perform cleanup actions on script exit
cleanup() {
    # Capture the exit code from the script before the trap was triggered
    # This allows the trap to return the original exit status
    local exit_code=$?

    # Log a message indicating script termination if not a clean exit (exit_code 0)
    if [ "$exit_code" -ne "$EXIT_SUCCESS" ]; then
        log ERROR "Script terminated with exit code $exit_code"
    fi

    log INFO "Performing secure cleanup..."

    # Attempt to log out of Bitwarden silently, ignore errors
    # Use >/dev/null 2>&1 to discard both stdout and stderr
    bw logout >/dev/null 2>&1 || true

    # Unset sensitive variables from the current shell environment
    unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD

    # Optional: Attempt to overwrite sensitive variables in memory before unsetting.
    # This is a theoretical security hardening step.
    declare -a sensitive_vars=(BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD)
    for var in "${sensitive_vars[@]}"; do
        # Check if the variable exists and is not already unset
        if declare -p "$var" 2>/dev/null | grep -q "^declare"; then
             # Overwrite the variable content
             eval "$var='$(printf "%*s" "${#${!var}}" | tr ' ' 'X')'" # Overwrite with 'X'
             # Could use /dev/urandom or specific patterns for better wiping if needed
             # e.g., eval "$var=$(head -c ${#${!var}} /dev/urandom | base64 | tr -d \\n)" # Random
        fi
    done

    log INFO "Cleanup complete."

    # Re-exit with the original exit code
    exit "$exit_code"
}

# Trap for script exit (success or failure), interrupt (Ctrl+C), and termination signals
# This ensures cleanup runs whenever the script stops.
trap cleanup EXIT INT TERM

# Note: With 'set -e' and the cleanup trap capturing $?, a separate ERR trap
# like the one in Sol3 is often redundant. Failures will trigger EXIT.
# If a separate ERR trap were needed (e.g., for specific error logging before cleanup),
# it would need careful handling to avoid exiting twice or interfering with the main trap.

# --- Helper Functions ---

# --- Dependency Check ---
check_dependencies() {
    log INFO "Checking for required dependencies..."
    local deps=("bw" "jq" "gzip")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log ERROR "Missing dependencies: ${missing[*]}"
        exit "$EXIT_MISSING_DEP"
    fi
    log SUCCESS "All dependencies found."
}

# Validate environment variables and backup directory setup
validate_environment() {
    log INFO "Validating environment and directory setup..."

    # Check if required variables are non-empty
    for var in BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD ENCRYPTION_PASSWORD; do
        # ${!var:-} expands to the value of var, or empty string if unset/null.
        # set -u already guarantees it's not unset, but this handles empty strings.
        if [ -z "${!var:-}" ]; then
            log ERROR "Missing or empty required variable: $var. Please set it."
            exit "$EXIT_MISSING_VAR"
        fi
    done
    log INFO "Required environment variables are set."

    # Create backup directory if it doesn't exist and check for failure
    if [ ! -d "$BACKUP_DIR" ]; then
        log INFO "Backup directory '$BACKUP_DIR' not found, creating..."
        mkdir -p "$BACKUP_DIR" || { log ERROR "Failed to create backup directory: $BACKUP_DIR"; exit "$EXIT_BACKUP_DIR"; }
        log INFO "Backup directory created."
    fi

    # Set secure permissions on the backup directory (rwx------ for owner)
    # Log a warning but don't exit if chmod fails (e.g., permissions already stricter, or filesystem issue)
    if ! chmod 700 "$BACKUP_DIR"; then
        log WARN "Could not set secure permissions (700) on backup directory: $BACKUP_DIR"
    fi
    log INFO "Backup directory permissions checked."

    # Test write permissions in the backup directory
    local test_file="${BACKUP_DIR}/.write_test.$TIMESTAMP"
    if ! touch "$test_file" 2>/dev/null; then
        log ERROR "No write permissions in backup directory: $BACKUP_DIR"
        exit "$EXIT_BACKUP_DIR"
    fi
    rm -f "$test_file"
    log INFO "Write permissions verified in backup directory."
}

# --- Bitwarden Operations ---

# Ensure logout before starting fresh
bw_logout() {
    log INFO "Logging out from any existing Bitwarden session..."
    bw logout >/dev/null 2>&1 || log WARN "Already logged out."
}

# Login to Bitwarden using API key
bw_login() {
    log INFO "Logging into Bitwarden using API key..."
    # Export variables needed by bw CLI. Assuming they are provided in the environment.
    export BW_CLIENTID="${BW_CLIENTID}"
    export BW_CLIENTSECRET="${BW_CLIENTSECRET}"
    export BW_PASSWORD="${BW_PASSWORD}" # Needed for unlock

    # Attempt login, silence output, exit on failure (due to set -e)
    if ! bw login --apikey >/dev/null 2>&1; then
        log ERROR "Failed to log into Bitwarden with API key. Check credentials."
        exit "$EXIT_LOGIN_FAILED"
    fi
    log SUCCESS "Successfully logged in."
}

# Unlock the vault using the password
bw_unlock() {
    log INFO "Unlocking vault..."
    # Unlock the vault and capture the session token.
    # Use 'if ! VAR=$(command)' pattern to check command success.
    local unlock_output
    if ! unlock_output=$(bw unlock --raw --passwordenv BW_PASSWORD 2>&1); then
        log ERROR "Failed to unlock vault. Check BW_PASSWORD ${unlock_output}."
        exit "$EXIT_UNLOCK_FAILED"
    fi
    BW_SESSION="$unlock_output" # Capture the session token
    export BW_SESSION # Export the session token for subsequent bw commands

    # Check if the session token was actually obtained (should be non-empty)
    if [ -z "$BW_SESSION" ]; then
         log ERROR "Unlock command succeeded but returned an empty session token."
         exit "$EXIT_UNLOCK_FAILED"
    fi

    log SUCCESS "Vault unlocked."
}

# Export the vault data in raw JSON format
export_data() {
    log INFO "Exporting vault data..."

    bw sync --session "$BW_SESSION"

    # Use the session token and feed password to interactive prompt
    if ! echo "$BW_PASSWORD" | bw export --raw --session "$BW_SESSION" --format json > "$RAW_FILE"; then
        log ERROR "Failed to export vault data to $RAW_FILE."

        # Check if the file was partially created or empty
        if [ -f "$RAW_FILE" ]; then
            if [ -s "$RAW_FILE" ]; then
                log ERROR "Partial export file '$RAW_FILE' might exist but the command failed."
            else
                log ERROR "Export command failed and created an empty file '$RAW_FILE'."
            fi
        else
            log ERROR "Export command failed and did not create the file '$RAW_FILE'."
        fi
        exit "$EXIT_EXPORT_FAILED"
    fi

    log INFO "Exported ${RAW_FILE} ($(stat -c%s "$RAW_FILE") bytes)"
}

# Validate the exported JSON file
validate_export() {
    log INFO "Validating the exported file..."

    # Check if the file exists and is not empty
    if [ ! -s "$RAW_FILE" ]; then
        log ERROR "Backup file is empty or does not exist: $RAW_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log INFO "Backup file exists and is not empty."

    # Check file size against minimum expected size
    local filesize
    # Use stat command to get file size in bytes
    if ! filesize=$(stat -c%s "$RAW_FILE" 2>/dev/null); then
        log WARN "Could not get size of backup file '$RAW_FILE'. Skipping size check."
    else
        log INFO "Backup file size: $filesize bytes."
        if [ "$filesize" -lt "$MIN_BACKUP_SIZE" ]; then
            log WARN "Backup file size ($filesize bytes) is less than the minimum expected size ($MIN_BACKUP_SIZE bytes). This might indicate an issue."
            # Decide if this should be an ERROR causing script exit
            exit "$EXIT_INVALID_BACKUP"
        fi
    fi

    # Check if the file contains valid JSON using jq
    # Redirect both stdout and stderr to /dev/null as jq empty is silent on success
    if ! jq empty "$RAW_FILE" >/dev/null 2>&1; then
        log ERROR "Backup file contains invalid JSON: $RAW_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log SUCCESS "Backup file is valid JSON."
}

encrypt_backup() {
    log INFO "Encrypting backup file..."
    local encrypted_file="${COMPRESSED_FILE}.enc"

    if [ -z "${ENCRYPTION_PASSWORD:-}" ]; then
        log ERROR "ENCRYPTION_PASSWORD not set. Cannot encrypt backup."
        exit "$EXIT_COMPRESS_FAILED"
    fi

    # Encrypt with AES-256-CBC and PBKDF2
    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
        -in "$COMPRESSED_FILE" -out "$encrypted_file" \
        -pass pass:"$ENCRYPTION_PASSWORD"; then
        log ERROR "Failed to encrypt the backup file: $COMPRESSED_FILE"
        exit "$EXIT_COMPRESS_FAILED"
    fi

    # Set secure permissions (rw-------)
    chmod 600 "$encrypted_file" || log WARN "Failed to set permissions on encrypted file."

    # Replace unencrypted backup with encrypted version
    rm -f "$COMPRESSED_FILE"
    COMPRESSED_FILE="$encrypted_file"
    log SUCCESS "Backup encrypted to: $encrypted_file"
}

# Verify the encrypted backup can be decrypted correctly
encrypt_verify() {
    log INFO "Verifying encrypted backup file..."

    local encrypted_file="${COMPRESSED_FILE}"

    if [ ! -f "$encrypted_file" ]; then
        log ERROR "Encrypted backup file not found: $encrypted_file"
        exit "$EXIT_INVALID_BACKUP"
    fi
    temp_decrypted_file=$(mktemp)

    # Try decrypting the file into memory
    if ! decrypted_content=$(openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
            -salt -in "$encrypted_file" -pass env:ENCRYPTION_PASSWORD -out "$temp_decrypted_file" 2>/dev/null); then
        log ERROR "Failed to decrypt encrypted backup. Verification failed."
        exit "$EXIT_INVALID_BACKUP"
    fi

    log INFO "Decryption succeeded. Verifying decrypted content format..."

    # Check if the decrypted content is valid gzip (gzip file starts with 1F 8B magic bytes)
    if ! gzip -t "$temp_decrypted_file" >/dev/null 2>&1; then
        log ERROR "Decrypted backup is not valid gzip compressed data."
        exit "$EXIT_INVALID_BACKUP"
    fi

    log SUCCESS "Encryption verified: Decrypted content is valid gzip compressed data."
    rm -f "$temp_decrypted_file"
}

# Compress the raw backup file
compress_backup() {
    log INFO "Compressing backup file..."
    # Attempt gzip compression with max compression level (-9)
    # Compress the file in place. Log warning but don't exit if compression fails.
    if gzip -f -9 "$RAW_FILE"; then # Use -f to force overwrite if .gz exists (shouldn't happen with timestamp)
        COMPRESSED_FILE="${RAW_FILE}.gz"
        log SUCCESS "Backup compressed to: $COMPRESSED_FILE"
    else
        log WARN "Failed to compress backup file: $RAW_FILE. Keeping uncompressed version."
        # If compression failed, the raw file remains, update the variable
        COMPRESSED_FILE="$RAW_FILE"
    fi

    encrypt_backup
    encrypt_verify

    # Set secure permissions on the final backup file (rw------- for owner)
    if ! chmod 600 "$COMPRESSED_FILE"; then
        log WARN "Could not set secure permissions (600) on backup file: $COMPRESSED_FILE"
    fi
    log INFO "Backup file permissions set to 600."
}

upload_backup() {
    log INFO "Uploading backup to remote storage using rclone..."

    # Check if rclone is available
    if ! command -v rclone >/dev/null 2>&1; then
        log ERROR "rclone is not installed. Please install rclone to upload backups."
        exit "$EXIT_MISSING_DEP"
    fi

    # Check if backup file exists
    if [ ! -f "$COMPRESSED_FILE" ]; then
        log ERROR "Backup file not found: $COMPRESSED_FILE. Cannot upload."
        exit "$EXIT_INVALID_BACKUP"
    fi

    # Upload the backup file using rclone
    if ! rclone copy "$COMPRESSED_FILE" "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/"; then
        log ERROR "Failed to upload backup to rclone remote '$RCLONE_R2_REMOTE_NAME'."
        exit "$EXIT_UNEXPECTED"
    fi

    log SUCCESS "Backup uploaded successfully to rclone remote '$RCLONE_R2_REMOTE_NAME'."
}

prune_old_backups_r2() {
    log INFO "Pruning old backups from R2..."

    local backups_to_keep=${R2_RETENTION_COUNT:-240}
    log INFO "Retention policy: Keeping last $backups_to_keep backups"

    if ! command -v rclone >/dev/null 2>&1; then
        log ERROR "rclone is not installed"
        return 1
    fi

    # Get sorted list of backup files (newest first)
    local backup_list
    # Use --output-json to get machine-readable output for jq
    if ! backup_list=$(rclone lsjson --no-modtime "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/" | \
        jq -r 'sort_by(.Name) | reverse | .[] | select(.Name | endswith(".enc")) | .Name'); then
        return 1
    fi

    local total_backups=$(echo "$backup_list" | wc -l)
    log INFO "Found $total_backups backup files"

    if [ "$total_backups" -le "$backups_to_keep" ]; then
        log INFO "No pruning needed"
        return 0
    fi

    # --- Store files to delete in an array ---
    local files_to_delete_array=()
    # Use a while read loop to safely populate the array from the tail output
    # Using <<< here to feed the string to the while read loop
    while IFS= read -r line; do
        files_to_delete_array+=("$line")
    done <<< "$(echo "$backup_list" | tail -n $((total_backups - backups_to_keep)))"

    local files_to_delete_count=${#files_to_delete_array[@]}
    log INFO "Identified $files_to_delete_count files to delete."

    local success_count=0
    local error_files=() # Array to store files that genuinely failed deletion

    for file in "${files_to_delete_array[@]}"; do

        if [ -z "$file" ]; then
            log WARN "Skipping empty filename in list."
            continue
        fi

        log INFO "Attempting to delete: $file"


        local delete_output_file=$(mktemp)

        local delete_exit_status=0

        # Execute rclone delete and capture stderr and exit status
        # Use || true to prevent set -e from exiting on rclone failure
        rclone delete --stats=0 "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/$file" 2>"$delete_output_file" || delete_exit_status=$?

        if [ "$delete_exit_status" -eq 0 ]; then
            log DEBUG "Successfully deleted: $file"
            success_count=$((success_count + 1)) || true # Alternative syntax
            # Clean up temp delete output file, ignore errors with || true or log WARN
            rm -f "$delete_output_file"
        else
            local ls_output_file=$(mktemp)

            local ls_exit_status=0

            rclone ls "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/$file" >"$ls_output_file" 2>/dev/null || ls_exit_status=$?

            if [ "$ls_exit_status" -ne 0 ]; then
                 success_count=$((success_count + 1)) || true # Alternative syntax
            else
                 local rclone_error_message=$(<"$delete_output_file")
                 error_files+=("$file")
            fi
            # Clean up temp ls output file, ignore errors with || true or log WARN
            rm -f "$ls_output_file"
        fi

    done # End of for loop

    log SUCCESS "Attempted to delete $files_to_delete_count files. Successfully confirmed $success_count deletions."

    if [ ${#error_files[@]} -gt 0 ]; then
        log ERROR "The following files could not be deleted and still exist:"
        printf "%s\n" "${error_files[@]}" >&2
    fi

    return 0 # Return 0 unless the file listing failed or you uncommented the return 1 above
}


# --- Main Execution ---
main() {
    log INFO "Starting Bitwarden backup process..."

    bw_logout
    check_dependencies
    validate_environment
    bw_login
    bw_unlock
    export_data
    validate_export
    compress_backup
    upload_backup
    prune_old_backups_r2

    log SUCCESS "Bitwarden backup process completed successfully! Backup file: $COMPRESSED_FILE"

    # Exit with code 0 on success. The trap will pick this up.
    exit "$EXIT_SUCCESS"
}

# Execute the main function
main
#!/usr/bin/env bash

# Bitwarden Vault Backup Script
# Backs up a Bitwarden vault using the bw CLI and API key,
# validates the export, compresses it, and prunes old backups.
# Added feature: Skip upload if no changes detected based on hash stored in R2.

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
readonly BACKUP_DIR="${BACKUP_DIR:-/tmp/bw_backup}" # Use a temporary local directory
# RETENTION_DAYS and MIN_BACKUP_SIZE are for local backups, not used after R2 pruning
readonly RETENTION_DAYS="${RETENTION_DAYS:-60}" # Kept for reference, apply R2_RETENTION_COUNT instead
readonly MIN_BACKUP_SIZE="${MIN_BACKUP_SIZE:-100000}"  # 1KB minimum size check
readonly COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-9}"  # Max gzip compression

# File within the R2 bucket to store the hash of the last successful backup
# This file will be downloaded and uploaded from the ephemeral server
readonly R2_HASH_FILENAME=".last_bw_backup_hash.sha256"

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
COMPRESSED_FILE="" # Will be set during compression/encryption
export NODE_NO_DEPRECATION=1 # Suppress Node.js deprecation warnings from bw CLI

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
    bw logout >/dev/null 2>&1 || true

    # Remove temporary local files
    if [ -f "$RAW_FILE" ]; then
        log DEBUG "Removing temporary raw file: $RAW_FILE"
        rm -f "$RAW_FILE" || log WARN "Failed to remove temporary raw file: $RAW_FILE"
    fi
    # Remove the compressed/encrypted file if it exists, regardless of success,
    # as it's only kept temporarily for upload from this ephemeral server.
    if [ -f "$COMPRESSED_FILE" ]; then
        log DEBUG "Removing temporary compressed/encrypted file: $COMPRESSED_FILE"
        rm -f "$COMPRESSED_FILE" || log WARN "Failed to remove temporary compressed/encrypted file: $COMPRESSED_FILE"
    fi

    # Unset sensitive variables from the current shell environment
    unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD ENCRYPTION_PASSWORD

    # Optional: Attempt to overwrite sensitive variables in memory before unsetting.
    declare -a sensitive_vars=(BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD ENCRYPTION_PASSWORD)
    for var in "${sensitive_vars[@]}"; do
        if declare -p "$var" 2>/dev/null | grep -q "^declare"; then
             eval "$var='$(printf "%*s" "${#${!var}}" | tr ' ' 'X')'"
        fi
    done

    log INFO "Cleanup complete."

    # Re-exit with the original exit code
    exit "$exit_code"
}

# Trap for script exit (success or failure), interrupt (Ctrl+C), and termination signals
trap cleanup EXIT INT TERM

# --- Helper Functions ---

# --- Dependency Check ---
check_dependencies() {
    log INFO "Checking for required dependencies..."
    local deps=("bw" "jq" "gzip" "openssl" "sha256sum" "rclone")
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
    for var in BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD ENCRYPTION_PASSWORD RCLONE_R2_REMOTE_NAME RCLONE_R2_BUCKET_NAME; do
        if [ -z "${!var:-}" ]; then
            log ERROR "Missing or empty required variable: $var. Please set it."
            exit "$EXIT_MISSING_VAR"
        fi
    done
    log INFO "Required environment variables are set."

    # Create backup directory if it doesn't exist (it won't on ephemeral)
    if [ ! -d "$BACKUP_DIR" ]; then
        log INFO "Temporary backup directory '$BACKUP_DIR' not found, creating..."
        mkdir -p "$BACKUP_DIR" || { log ERROR "Failed to create temporary backup directory: $BACKUP_DIR"; exit "$EXIT_BACKUP_DIR"; }
        log INFO "Temporary backup directory created."
    fi
    # Set secure permissions on the temporary directory (rwx------ for owner)
    if ! chmod 700 "$BACKUP_DIR"; then
        log WARN "Could not set secure permissions (700) on temporary backup directory: $BACKUP_DIR"
    fi
    log INFO "Temporary backup directory permissions checked."

    # Test write permissions in the temporary backup directory
    local test_file="${BACKUP_DIR}/.write_test.$TIMESTAMP"
    if ! touch "$test_file" 2>/dev/null; then
        log ERROR "No write permissions in temporary backup directory: $BACKUP_DIR"
        exit "$EXIT_BACKUP_DIR"
    fi
    rm -f "$test_file"
    log INFO "Write permissions verified in temporary backup directory."

    # Check rclone remote/bucket accessibility
    log INFO "Checking rclone remote accessibility..."
    if ! rclone mkdir "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/" 2>&1; then
        log ERROR "Could not access rclone remote '$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/'. Uploads/Hash check will fail."
        exit "$EXIT_UNEXPECTED"
    fi
    log SUCCESS "Rclone remote accessible."
}

# --- Bitwarden Operations (Same as before) ---

bw_logout() {
    log INFO "Logging out from any existing Bitwarden session..."
    bw logout >/dev/null 2>&1 || log WARN "Already logged out or no session."
}

bw_login() {
    log INFO "Logging into Bitwarden using API key..."
    export BW_CLIENTID="${BW_CLIENTID}"
    export BW_CLIENTSECRET="${BW_CLIENTSECRET}"
    export BW_PASSWORD="${BW_PASSWORD}"
    if ! bw login --apikey >/dev/null 2>&1; then
        log ERROR "Failed to log into Bitwarden with API key. Check credentials."
        exit "$EXIT_LOGIN_FAILED"
    fi
    log SUCCESS "Successfully logged in."
}

bw_unlock() {
    log INFO "Unlocking vault..."
    local unlock_output
    if ! unlock_output=$(bw unlock --raw --passwordenv BW_PASSWORD 2>&1); then
        log ERROR "Failed to unlock vault. Check BW_PASSWORD. Output: ${unlock_output}"
        exit "$EXIT_UNLOCK_FAILED"
    fi
    BW_SESSION="$unlock_output"
    export BW_SESSION
    if [ -z "$BW_SESSION" ]; then
         log ERROR "Unlock command succeeded but returned an empty session token."
         exit "$EXIT_UNLOCK_FAILED"
    fi
    log SUCCESS "Vault unlocked."
}

export_data() {
    log INFO "Exporting vault data..."
    log INFO "Syncing vault data..."
    if ! bw sync --session "$BW_SESSION" >/dev/null 2>&1; then
        log WARN "Vault sync failed or timed out. Proceeding with export using potentially stale local data."
    fi

    if ! echo "$BW_PASSWORD" | bw export --raw --session "$BW_SESSION" --format json > "$RAW_FILE"; then
        log ERROR "Failed to export vault data to $RAW_FILE."
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
    log INFO "Exported ${RAW_FILE} ($(stat -c%s "$RAW_FILE" 2>/dev/null || echo "size unknown") bytes)"
}

validate_export() {
    log INFO "Validating the exported file..."
    if [ ! -s "$RAW_FILE" ]; then
        log ERROR "Backup file is empty or does not exist: $RAW_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log INFO "Backup file exists and is not empty."

    local filesize
    if ! filesize=$(stat -c%s "$RAW_FILE" 2>/dev/null); then
        log WARN "Could not get size of backup file '$RAW_FILE'. Skipping size check."
    else
        log INFO "Backup file size: $filesize bytes."
        if [ "$filesize" -lt "$MIN_BACKUP_SIZE" ]; then
            log WARN "Backup file size ($filesize bytes) is less than the minimum expected size ($MIN_BACKUP_SIZE bytes). This might indicate an issue."
             exit "$EXIT_INVALID_BACKUP" # Making minimum size a hard error
        fi
    fi

    if ! jq empty "$RAW_FILE" >/dev/null 2>&1; then
        log ERROR "Backup file contains invalid JSON: $RAW_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log SUCCESS "Backup file is valid JSON."
}

# --- Hash Management in R2 ---

# Calculate SHA256 hash of a file
get_local_file_hash() {
    local filepath="$1"
    if [ -f "$filepath" ]; then
        sha256sum "$filepath" | awk '{print $1}'
    else
        echo "" # Return empty string if file doesn't exist locally
    fi
}

# Get the hash of the last successful backup from the R2 tracking file
get_last_remote_hash() {
    log INFO "Attempting to retrieve last backup hash from R2..."
    local remote_hash_file="$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/$R2_HASH_FILENAME"
    local last_hash=""

    # Use rclone cat to read the file directly. Capture stderr to check for errors.
    if last_hash=$(rclone cat "$remote_hash_file" 2>/dev/null); then
        log SUCCESS "Successfully retrieved last backup hash from R2."
        echo "$last_hash"
    else
        # Check if the error was "file not found" or a real error
        # rclone cat exits with 1 if the file doesn't exist. Other errors might be different.
        # A simple check for non-empty output from rclone cat is often sufficient if error goes to stderr
        # Let's check the exit status explicitly
        local rclone_exit_status=$?
        if [ "$rclone_exit_status" -eq 0 ]; then
             # This case is hit if rclone cat exits 0 but outputs nothing (empty file?)
             log WARN "Remote hash file '$remote_hash_file' might be empty."
             echo ""
        elif [ "$rclone_exit_status" -eq 1 ]; then
             log INFO "Remote hash file '$remote_hash_file' not found on R2 (likely first run)."
             echo "" # Return empty string if file not found
        else
             log WARN "Failed to retrieve last backup hash from R2 ('rclone cat' exited with status $rclone_exit_status)."
             echo "" # Return empty string on other errors
        fi
    fi
}

# Save the current hash to the R2 tracking file
save_current_remote_hash() {
    local current_hash="$1"
    local remote_hash_file="$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/$R2_HASH_FILENAME"

    if [ -z "$current_hash" ]; then
        log WARN "Attempted to save an empty hash to R2."
        return 1 # Indicate failure
    fi

    log INFO "Saving current backup hash to R2: $remote_hash_file"

    # Use rclone rcat to write the hash from stdin to the remote file.
    # This is atomic on most backends (overwrites the file).
    if echo "$current_hash" | rclone rcat "$remote_hash_file"; then
        log SUCCESS "Successfully saved current hash to R2."
        return 0 # Indicate success
    else
        log ERROR "Failed to save current hash to R2: $remote_hash_file"
        return 1 # Indicate failure
    fi
}

# --- Compression and Encryption ---

encrypt_backup() {
    log INFO "Encrypting backup file..."
    local temp_encrypted_file="${BACKUP_DIR}/bw_backup_${TIMESTAMP}.json.gz.enc.temp"

    if [ -z "${ENCRYPTION_PASSWORD:-}" ]; then
        log ERROR "ENCRYPTION_PASSWORD not set. Cannot encrypt backup."
        exit "$EXIT_COMPRESS_FAILED"
    fi

    # Encrypt with AES-256-CBC and PBKDF2. Use -pass env: to securely pass password.
    if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
        -in "$COMPRESSED_FILE" -out "$temp_encrypted_file" \
        -pass env:ENCRYPTION_PASSWORD; then
        log ERROR "Failed to encrypt the backup file: $COMPRESSED_FILE"
        rm -f "$temp_encrypted_file" || true
        exit "$EXIT_COMPRESS_FAILED"
    fi

    if [ ! -f "$temp_encrypted_file" ]; then
        log ERROR "Encryption process failed to create output file: $temp_encrypted_file"
        exit "$EXIT_COMPRESS_FAILED"
    fi

    # Remove the unencrypted compressed file after successful encryption
    rm -f "$COMPRESSED_FILE" || log WARN "Failed to remove unencrypted compressed file: $COMPRESSED_FILE"

    # Update COMPRESSED_FILE variable to point to the new encrypted file
    COMPRESSED_FILE="$temp_encrypted_file"

    log SUCCESS "Backup encrypted to temporary file: $temp_encrypted_file"
}

encrypt_verify() {
    log INFO "Verifying encrypted backup file..."
    local encrypted_file="${COMPRESSED_FILE}"
    if [ ! -f "$encrypted_file" ]; then
        log ERROR "Encrypted backup file not found for verification: $encrypted_file"
        exit "$EXIT_INVALID_BACKUP"
    fi
    local temp_decrypted_file=$(mktemp "${BACKUP_DIR}/bw_decrypt_verify.XXXXXXXXXX.gz")

    if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
            -salt -in "$encrypted_file" -pass env:ENCRYPTION_PASSWORD -out "$temp_decrypted_file" 2>/dev/null; then
        log ERROR "Failed to decrypt encrypted backup during verification."
        rm -f "$temp_decrypted_file" || true
        exit "$EXIT_INVALID_BACKUP"
    fi

    log INFO "Decryption succeeded. Verifying decrypted content format..."
    if ! gzip -t "$temp_decrypted_file" >/dev/null 2>&1; then
        log ERROR "Decrypted backup is not valid gzip compressed data."
        rm -f "$temp_decrypted_file" || true
        exit "$EXIT_INVALID_BACKUP"
    fi

    log SUCCESS "Encryption verified: Decrypted content is valid gzip compressed data."
    rm -f "$temp_decrypted_file" || log WARN "Failed to remove temporary decrypted verification file."

    # Rename the temporary encrypted file to its final name after verification
    local final_encrypted_file="${BACKUP_DIR}/bw_backup_${TIMESTAMP}.json.gz.enc"
    if mv "$encrypted_file" "$final_encrypted_file"; then
        COMPRESSED_FILE="$final_encrypted_file"
        log DEBUG "Renamed temporary encrypted file to final name: $COMPRESSED_FILE"
    else
        log ERROR "Failed to rename temporary encrypted file to final name."
        exit "$EXIT_UNEXPECTED"
    fi

     # Set secure permissions on the final encrypted file (rw------- for owner) - redundant for ephemeral, but good practice
    if ! chmod 600 "$COMPRESSED_FILE"; then
        log WARN "Could not set secure permissions (600) on backup file: $COMPRESSED_FILE"
    fi
    log INFO "Backup file permissions set to 600."
}

compress_backup() {
    log INFO "Compressing backup file..."
    local temp_compressed_file="${BACKUP_DIR}/bw_backup_${TIMESTAMP}.json.gz.temp"

    if gzip -c -9 "$RAW_FILE" > "$temp_compressed_file"; then
        COMPRESSED_FILE="$temp_compressed_file"
        log SUCCESS "Backup compressed to temporary file: $temp_compressed_file"
    else
        log ERROR "Failed to compress backup file: $RAW_FILE."
        rm -f "$temp_compressed_file" || true
        exit "$EXIT_COMPRESS_FAILED"
    fi

    # RAW_FILE is no longer needed after successful compression
    rm -f "$RAW_FILE" || log WARN "Failed to remove raw file after compression: $RAW_FILE"
}

upload_backup() {
    log INFO "Uploading backup to remote storage using rclone..."
    if [ ! -f "$COMPRESSED_FILE" ]; then
        log ERROR "Backup file not found: $COMPRESSED_FILE. Cannot upload."
        exit "$EXIT_INVALID_BACKUP"
    fi

    log DEBUG "Running rclone copy '$COMPRESSED_FILE' '$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/'"
    if ! rclone --stats-one-line -v copy "$COMPRESSED_FILE" "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/"; then
        log ERROR "Failed to upload backup to rclone remote '$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/'."
        exit "$EXIT_UNEXPECTED"
    fi

    log SUCCESS "Backup uploaded successfully to rclone remote '$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/'."
}

prune_old_backups_r2() {
    log INFO "Pruning old backups from R2..."

    local backups_to_keep=${R2_RETENTION_COUNT:-240} # Default 240 backups (approx 8 months daily)
    if [ "$backups_to_keep" -lt 1 ]; then
        log WARN "R2_RETENTION_COUNT is less than 1 ($backups_to_keep). Skipping pruning."
        return 0
    fi
    log INFO "Retention policy: Keeping last $backups_to_keep backup files ending in .enc"

    local backup_list_json
    if ! backup_list_json=$(rclone lsjson --no-modtime "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/" 2>/dev/null); then
        log ERROR "Failed to list files on rclone remote for pruning."
        return 1 # Indicate failure
    fi

    # Use jq to filter for .enc files, sort by Name, reverse sort, and extract Name
    local backup_names_sorted_newest_first
    backup_names_sorted_newest_first=$(echo "$backup_list_json" | \
        jq -r '.[] | select(.Name | endswith(".enc")) | .Name' | sort -r)

    if [ -z "$backup_names_sorted_newest_first" ]; then
        log INFO "No backup files found on R2 for pruning."
        return 0
    fi

    local total_backups=$(echo "$backup_names_sorted_newest_first" | wc -l)
    log INFO "Found $total_backups backup files ending in .enc."

    if [ "$total_backups" -le "$backups_to_keep" ]; then
        log INFO "Total backups ($total_backups) is within the retention count ($backups_to_keep). No pruning needed."
        return 0
    fi

    local files_to_delete_array=()
    while IFS= read -r line; do
        files_to_delete_array+=("$line")
    done <<< "$(echo "$backup_names_sorted_newest_first" | tail -n +$((backups_to_keep + 1)))"

    local files_to_delete_count=${#files_to_delete_array[@]}
    log INFO "Identified $files_to_delete_count files to delete based on retention policy."

    local success_count=0
    local failed_deletions=()

    for file in "${files_to_delete_array[@]}"; do
        if [ -z "$file" ]; then
            log WARN "Skipping empty filename in list during pruning."
            continue
        fi
        log INFO "Attempting to delete old backup: $file"
        local delete_exit_status=0
        local delete_output
        delete_output=$(rclone --stats=0 delete "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/$file" 2>&1) || delete_exit_status=$?

        if [ "$delete_exit_status" -eq 0 ]; then
            log DEBUG "Successfully deleted: $file"
            success_count=$((success_count + 1))
        else
            local ls_exit_status=0
            rclone ls "$RCLONE_R2_REMOTE_NAME:$RCLONE_R2_BUCKET_NAME/$file" >/dev/null 2>&1 || ls_exit_status=$?
            if [ "$ls_exit_status" -ne 0 ]; then
                 log DEBUG "File $file not found after delete attempt (ls failed), assuming successful removal."
                 success_count=$((success_count + 1))
            else
                 log ERROR "Failed to delete file $file. rclone output: $delete_output"
                 failed_deletions+=("$file")
            fi
        fi
    done

    log SUCCESS "Attempted to delete $files_to_delete_count files. Successfully confirmed $success_count removals (deleted or already gone)."

    if [ ${#failed_deletions[@]} -gt 0 ]; then
        log ERROR "The following files could not be deleted and still exist on R2:"
        printf "%s\n" "${failed_deletions[@]}" >&2
    fi

    return 0
}


# --- Main Execution ---
main() {
    log INFO "Starting Bitwarden backup process..."

    # Perform initial steps regardless of changes
    bw_logout
    check_dependencies
    validate_environment
    bw_login
    bw_unlock
    export_data
    validate_export

    # Calculate hash of the newly exported raw data
    local current_raw_hash
    current_raw_hash=$(get_local_file_hash "$RAW_FILE")
    log DEBUG "Current raw export hash: $current_raw_hash"

    # Get hash of the last uploaded backup from R2
    local last_saved_hash
    last_saved_hash=$(get_last_remote_hash)
    log DEBUG "Last saved hash from R2: ${last_saved_hash:-'None found'}"

    local changes_detected=false

    # Compare hashes
    if [ -z "$last_saved_hash" ]; then
        log INFO "No previous backup hash found in R2. Assuming first run or state file missing. Proceeding with backup and upload."
        changes_detected=true
    elif [ "$current_raw_hash" != "$last_saved_hash" ]; then
        log INFO "Changes detected in vault data (hash mismatch). Proceeding with backup and upload."
        changes_detected=true
    else
        log INFO "No changes detected in vault data since last successful backup (hash match). Skipping compression, encryption, and upload."
        changes_detected=false
    fi

    if [ "$changes_detected" = true ]; then
        # Proceed with compression, encryption, and upload
        compress_backup # Creates temp .gz file
        encrypt_backup  # Encrypts temp .gz, creates temp .enc, removes .gz, updates COMPRESSED_FILE
        encrypt_verify  # Verifies temp .enc, renames to final .enc, updates COMPRESSED_FILE, sets permissions
        upload_backup   # Uploads the final .enc file

        # If upload was successful, save the hash of the raw data to R2
        # Checking upload_backup's exit status isn't strictly needed due to set -e,
        # but good practice if set -e were removed.
        # The upload_backup call itself will cause script exit on failure.
        save_current_remote_hash "$current_raw_hash" || log WARN "Failed to save the new hash to R2 after successful backup upload."
    fi

    # Prune old backups from R2 regardless of whether a new backup was uploaded
    prune_old_backups_r2

    log SUCCESS "Bitwarden backup process completed."
    if [ "$changes_detected" = false ]; then
         log SUCCESS "No new backup uploaded as no changes were detected."
    else
         # COMPRESSED_FILE might be empty if compression/encryption failed, check existence before logging name
         if [ -n "$COMPRESSED_FILE" ] && [ -f "$COMPRESSED_FILE" ]; then
            log SUCCESS "New backup file uploaded: $(basename "$COMPRESSED_FILE")"
         else
             log SUCCESS "New backup was processed and uploaded." # Less specific if COMPRESSED_FILE isn't set/exists
         fi
    fi

    # Exit with code 0 on success. The trap will pick this up.
    exit "$EXIT_SUCCESS"
}

# Execute the main function
main
#!/usr/bin/env bash

# Bitwarden Vault Backup Script

# --- Strict Mode ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error and exit immediately.
# Exit immediately if any command in a pipeline fails.
set -euo pipefail

# --- Load Environment Variables ---
# Get the directory where this script is located (scripts/backup.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go up one level to find .env file in project root
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Source .env file if it exists, but preserve existing environment variables
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from: $ENV_FILE" >&2
    # Temporarily disable strict mode for reading .env
    set +u
    # Read .env file and only set variables that aren't already set
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip empty lines and comments
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Remove leading/trailing whitespace
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Remove quotes from value if present
        value=$(echo "$value" | sed 's/^"//;s/"$//')

        # Only set the variable if it's not already set (preserves Docker env vars)
        if [ -z "${!key:-}" ]; then
            export "$key=$value"
        else
            echo "Preserving existing environment variable: $key (Docker override detected)" >&2
        fi
    done < "$ENV_FILE"
    # Re-enable strict mode
    set -u
    echo "Environment variables loaded successfully." >&2
else
    echo "No .env file found at: $ENV_FILE" >&2
    echo "Assuming environment variables are already set." >&2
fi

# --- Constants ---
readonly BACKUP_DIR="${BACKUP_DIR:-/tmp/bw_backup}" # Use a temporary local directory
readonly MIN_BACKUP_SIZE="${MIN_BACKUP_SIZE:-1024}"  # 1KB minimum size check
readonly COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-9}"  # Max gzip compression
readonly BACKUP_PATH="${BACKUP_PATH:-bitwarden-backup}" # Remote path/bucket for backups

# Validate COMPRESSION_LEVEL is between 1-9
if ! [[ "$COMPRESSION_LEVEL" =~ ^[1-9]$ ]]; then
    echo "[ERROR] COMPRESSION_LEVEL must be between 1-9, got: $COMPRESSION_LEVEL" >&2
    exit 1
fi

# Project-specific rclone config path (set by setup-rclone.sh)
# Try to read from the persistent file first, then fall back to default
if [ -f "${BACKUP_DIR:-/tmp/bw_backup}/.rclone_config_path" ]; then
    # shellcheck source=/dev/null
    source "${BACKUP_DIR:-/tmp/bw_backup}/.rclone_config_path"
fi
readonly PROJECT_RCLONE_CONFIG_FILE="${PROJECT_RCLONE_CONFIG_FILE:-${BACKUP_DIR}/rclone/rclone.conf}"

# File within each remote to store the hash of the last successful backup
readonly HASH_FILENAME=".last_bw_backup_hash.sha256"
readonly APPRISE_URLS="${APPRISE_URLS:-}" # Allow empty, no notification if not set

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
changes_detected=false # Make this global so the trap can access it

# Retention settings
readonly RETENTION_COUNT="${RETENTION_COUNT:-240}" # Number of backups to keep per remote

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
# shellcheck disable=SC2317
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

    # Optional: Attempt to overwrite sensitive variables in memory before unsetting.
    declare -a sensitive_vars=(BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD ENCRYPTION_PASSWORD)
    for var in "${sensitive_vars[@]}"; do
        # Safer approach: directly unset without eval
        case "$var" in
            BW_SESSION) BW_SESSION="" ;;
            BW_CLIENTID) BW_CLIENTID="" ;;
            BW_CLIENTSECRET) BW_CLIENTSECRET="" ;;
            BW_PASSWORD) BW_PASSWORD="" ;;
            ENCRYPTION_PASSWORD) ENCRYPTION_PASSWORD="" ;;
        esac
    done

    # Unset sensitive variables from the current shell environment
    unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD ENCRYPTION_PASSWORD

    log INFO "Cleanup complete."

    # --- Send Final Apprise Notification ---
    local final_message=""
    local notify_level=""

    if [ "$exit_code" -eq "$EXIT_SUCCESS" ]; then
         # Use the global changes_detected variable
         if [ "$changes_detected" = false ]; then
             final_message="Bitwarden backup script completed successfully. No changes detected, no new backup uploaded."
         else
              # Use the global COMPRESSED_FILE variable
              # Check if COMPRESSED_FILE is set before trying to get basename
              if [ -n "$COMPRESSED_FILE" ] && [ -f "$COMPRESSED_FILE" ]; then
                  final_message="Bitwarden backup script completed successfully. New backup uploaded: $(basename "$COMPRESSED_FILE")."
              else
                  final_message="Bitwarden backup script completed successfully. New backup was processed and uploaded." # Fallback message
              fi
         fi
         notify_level="SUCCESS"
    else
        final_message="Bitwarden backup script failed with exit code $exit_code."
        # Add more context for common failures
        case "$exit_code" in
            "$EXIT_MISSING_VAR") final_message+="\nReason: Missing environment variable. Check documentation." ;;
            "$EXIT_MISSING_DEP") final_message+="\nReason: Missing dependencies. Check apprise, bw, jq, gzip, openssl, sha256sum/shasum, rclone." ;;
            "$EXIT_LOGIN_FAILED") final_message+="\nReason: Bitwarden login failed. Check BW_CLIENTID/BW_CLIENTSECRET." ;;
            "$EXIT_UNLOCK_FAILED") final_message+="\nReason: Bitwarden vault unlock failed. Check BW_PASSWORD." ;;
            "$EXIT_EXPORT_FAILED") final_message+="\nReason: Bitwarden export failed. Check permissions or vault state." ;;
            "$EXIT_INVALID_BACKUP") final_message+="\nReason: Exported backup file is empty, too small, or invalid JSON/gzip/encryption." ;;
            "$EXIT_COMPRESS_FAILED") final_message+="\nReason: Compression or encryption failed. Check ENCRYPTION_PASSWORD." ;;
            "$EXIT_BACKUP_DIR") final_message+="\nReason: Temporary backup directory could not be created or written to." ;;
            *) final_message+="\nReason: An unexpected error occurred. Review logs." ;;
        esac
    # Add script log file location to error message if available (requires passing it or using another env var)
    # Example: final_message+="\nLogs might be available at /path/to/log/file"
         notify_level="ERROR"
    fi

    send_notification "$notify_level" "$final_message"
    # --- End Apprise Notification ---


    # Re-exit with the original exit code
    exit "$exit_code"
}

# Trap for script exit (success or failure), interrupt (Ctrl+C), and termination signals
trap cleanup EXIT INT TERM


# --- Dependency Check ---
check_dependencies() {
    log INFO "Checking for required dependencies..."
    local deps=("bw" "jq" "gzip" "openssl" "rclone")

    # Add apprise only if notification URLs are configured
    if [ -n "$APPRISE_URLS" ]; then
        deps+=("apprise")
        log DEBUG "Apprise notifications configured, checking for 'apprise'."
    fi

    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    # Check for SHA256 utilities (cross-platform)
    if ! command -v sha256sum >/dev/null 2>&1 && \
       ! command -v shasum >/dev/null 2>&1 && \
       ! command -v openssl >/dev/null 2>&1; then
        missing+=("sha256sum/shasum/openssl")
    fi

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
        if [ -z "${!var:-}" ]; then
            log ERROR "Missing or empty required variable: $var. Please set it."
            exit "$EXIT_MISSING_VAR"
        fi
    done

    # Check if rclone config is available
    if [ -z "${RCLONE_CONFIG_BASE64:-}" ] && [ ! -f "$PROJECT_RCLONE_CONFIG_FILE" ]; then
        log ERROR "Neither RCLONE_CONFIG_BASE64 nor PROJECT_RCLONE_CONFIG_FILE is available."
        log ERROR "Please run setup-rclone.sh first or provide RCLONE_CONFIG_BASE64."
        exit "$EXIT_MISSING_VAR"
    fi

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

    # Verify rclone config file exists
    if [ ! -f "$PROJECT_RCLONE_CONFIG_FILE" ]; then
        log ERROR "Project rclone config file not found: $PROJECT_RCLONE_CONFIG_FILE"
        log ERROR "Please run setup-rclone.sh first."
        exit "$EXIT_MISSING_VAR"
    fi

    # Check rclone config and remotes accessibility
    log INFO "Checking rclone configuration and remote accessibility..."
    local available_remotes
    available_remotes=$(get_available_remotes)
    if [ -z "$available_remotes" ]; then
        log ERROR "No remotes found in rclone configuration."
        exit "$EXIT_UNEXPECTED"
    fi

    local remote_count
    remote_count=$(echo "$available_remotes" | wc -l | tr -d ' ')
    log SUCCESS "Found $remote_count remote(s) in configuration."

    # Test accessibility of each remote
    echo "$available_remotes" | while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            log INFO "Testing remote: $remote"
            if ! test_remote_accessibility "$remote"; then
                log WARN "Remote '$remote' accessibility test failed. Backups may fail for this remote."
            else
                log DEBUG "Remote '$remote' is accessible."
            fi
        fi
    done
}

# --- Multi-Remote Helper Functions ---

# Get list of available remotes from rclone config
get_available_remotes() {
    if [ ! -f "$PROJECT_RCLONE_CONFIG_FILE" ]; then
        echo ""
        return 1
    fi

    # Extract remote names from the config file (lines starting with [remote_name])
    grep -E '^\[.*\]$' "$PROJECT_RCLONE_CONFIG_FILE" | sed 's/\[\(.*\)\]/\1/' | grep -v '^$' || true
}

# Test if a remote is accessible
test_remote_accessibility() {
    local remote="$1"
    if [ -z "$remote" ]; then
        return 1
    fi

    # Try to list the remote root (quietly)
    if ! rclone --config "$PROJECT_RCLONE_CONFIG_FILE" lsd "$remote:" >/dev/null 2>&1; then
        return 1
    fi

    # Ensure the backup path exists (create if necessary)
    if ! rclone --config "$PROJECT_RCLONE_CONFIG_FILE" mkdir "$remote:$BACKUP_PATH" >/dev/null 2>&1; then
        # If mkdir fails, test if path already exists
        if ! rclone --config "$PROJECT_RCLONE_CONFIG_FILE" lsd "$remote:$BACKUP_PATH" >/dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

# Get the hash of the last successful backup from a specific remote
get_last_remote_hash() {
    local remote="$1"
    if [ -z "$remote" ]; then
        echo ""
        return 1
    fi

    log DEBUG "Retrieving last backup hash from remote: $remote"
    local remote_hash_file="$remote:$BACKUP_PATH/$HASH_FILENAME"
    local last_hash=""

    # Use rclone cat to read the file directly
    if last_hash=$(rclone --config "$PROJECT_RCLONE_CONFIG_FILE" cat "$remote_hash_file" 2>/dev/null); then
        # Trim whitespace and validate hash is not empty
        last_hash=$(echo "$last_hash" | tr -d '[:space:]')
        if [ -n "$last_hash" ]; then
            log DEBUG "Successfully retrieved last backup hash from $remote."
            echo "$last_hash"
            return 0
        else
            log DEBUG "Hash file exists on $remote but is empty."
            echo ""
            return 1
        fi
    else
        local rclone_exit_status=$?
        if [ "$rclone_exit_status" -eq 1 ]; then
            log DEBUG "Hash file not found on $remote (likely first run)."
        else
            log DEBUG "Failed to retrieve hash from $remote (exit status $rclone_exit_status)."
        fi
        echo ""
        return 1
    fi
}

# Save the current hash to a specific remote
save_current_remote_hash() {
    local remote="$1"
    local current_hash="$2"

    if [ -z "$remote" ] || [ -z "$current_hash" ]; then
        log WARN "Cannot save hash: missing remote or hash value."
        return 1
    fi

    local remote_hash_file="$remote:$BACKUP_PATH/$HASH_FILENAME"
    log DEBUG "Saving current backup hash to $remote: $current_hash"

    # Use rclone rcat to write the hash from stdin to the remote file
    if echo "$current_hash" | rclone --config "$PROJECT_RCLONE_CONFIG_FILE" rcat "$remote_hash_file"; then
        log DEBUG "Successfully saved current hash to $remote."
        return 0
    else
        log ERROR "Failed to save current hash to $remote: $remote_hash_file"
        return 1
    fi
}

# Upload backup to a specific remote
upload_backup_to_remote() {
    local remote="$1"
    if [ -z "$remote" ]; then
        log ERROR "No remote specified for upload."
        return 1
    fi

    if [ ! -f "$COMPRESSED_FILE" ]; then
        log ERROR "Backup file not found: $COMPRESSED_FILE. Cannot upload to $remote."
        return 1
    fi

    log INFO "Uploading backup to remote: $remote"
    local backup_filename
    backup_filename=$(basename "$COMPRESSED_FILE")

    # Use rclone copy to directory (without specifying filename) to avoid creating subdirectories
    if rclone --config "$PROJECT_RCLONE_CONFIG_FILE" --stats-one-line -v copy "$COMPRESSED_FILE" "$remote:$BACKUP_PATH/"; then
        log SUCCESS "Backup uploaded successfully to remote: $remote as $BACKUP_PATH/$backup_filename"
        return 0
    else
        log ERROR "Failed to upload backup to remote: $remote"
        return 1
    fi
}

# Prune old backups from a specific remote
prune_old_backups_from_remote() {
    local remote="$1"
    if [ -z "$remote" ]; then
        log ERROR "No remote specified for pruning."
        return 1
    fi

    log INFO "Pruning old backups from remote: $remote"

    local backups_to_keep="$RETENTION_COUNT"
    if [ "$backups_to_keep" -lt 1 ]; then
        log WARN "RETENTION_COUNT is less than 1 ($backups_to_keep). Skipping pruning for $remote."
        return 0
    fi

    log DEBUG "Retention policy for $remote: Keeping last $backups_to_keep backup files ending in .enc"

    local backup_list_json
    if ! backup_list_json=$(rclone --config "$PROJECT_RCLONE_CONFIG_FILE" lsjson --no-modtime "$remote:$BACKUP_PATH/" 2>/dev/null); then
        log ERROR "Failed to list files on remote $remote for pruning."
        return 1
    fi

    # Use jq to filter for .enc files, sort by Name, reverse sort, and extract Name
    local backup_names_sorted_newest_first
    backup_names_sorted_newest_first=$(echo "$backup_list_json" | \
        jq -r '.[] | select(.Name | endswith(".enc")) | .Name' | sort -r)

    if [ -z "$backup_names_sorted_newest_first" ]; then
        log INFO "No backup files found on $remote for pruning."
        return 0
    fi

    local total_backups
    total_backups=$(echo "$backup_names_sorted_newest_first" | wc -l | tr -d ' ')
    log DEBUG "Found $total_backups backup files ending in .enc on $remote."

    if [ "$total_backups" -le "$backups_to_keep" ]; then
        log DEBUG "Total backups ($total_backups) on $remote is within retention count ($backups_to_keep). No pruning needed."
        return 0
    fi

    local files_to_delete_array=()
    while IFS= read -r line; do
        files_to_delete_array+=("$line")
    done <<< "$(echo "$backup_names_sorted_newest_first" | tail -n +$((backups_to_keep + 1)))"

    local files_to_delete_count=${#files_to_delete_array[@]}
    log INFO "Identified $files_to_delete_count files to delete from $remote based on retention policy."

    local success_count=0
    local failed_deletions=()

    for file in "${files_to_delete_array[@]}"; do
        if [ -z "$file" ]; then
            log WARN "Skipping empty filename in list during pruning on $remote."
            continue
        fi

        log DEBUG "Attempting to delete old backup from $remote: $file"
        if rclone --config "$PROJECT_RCLONE_CONFIG_FILE" --stats=0 delete "$remote:$BACKUP_PATH/$file" 2>/dev/null; then
            log DEBUG "Successfully deleted from $remote: $file"
            success_count=$((success_count + 1))
        else
            # Double-check if file still exists
            if ! rclone --config "$PROJECT_RCLONE_CONFIG_FILE" ls "$remote:$BACKUP_PATH/$file" >/dev/null 2>&1; then
                log DEBUG "File $file not found on $remote after delete attempt, assuming successful removal."
                success_count=$((success_count + 1))
            else
                log ERROR "Failed to delete file $file from $remote."
                failed_deletions+=("$file")
            fi
        fi
    done

    log INFO "Pruning results for $remote: Attempted $files_to_delete_count, successful $success_count."

    if [ ${#failed_deletions[@]} -gt 0 ]; then
        log ERROR "The following files could not be deleted from $remote:"
        printf "%s\n" "${failed_deletions[@]}" >&2
    fi

    return 0
}

# Check if changes exist across all remotes (returns list of remotes needing updates)
check_changes_across_remotes() {
    local current_raw_hash="$1"
    local available_remotes="$2"
    local remotes_needing_updates=()

    if [ -z "$current_raw_hash" ] || [ -z "$available_remotes" ]; then
        log WARN "Missing parameters for change detection. Assuming all remotes need updates."
        echo "$available_remotes"
        return 0
    fi

    log INFO "Checking for changes across all remotes..."

    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            local last_saved_hash
            last_saved_hash=$(get_last_remote_hash "$remote")

            if [ -z "$last_saved_hash" ]; then
                log INFO "No previous backup hash found on $remote (first run or missing hash file)."
                remotes_needing_updates+=("$remote")
            elif [ "$current_raw_hash" != "$last_saved_hash" ]; then
                log INFO "Changes detected on $remote (hash mismatch)."
                remotes_needing_updates+=("$remote")
            else
                log DEBUG "No changes detected on $remote (hash match)."
            fi
        fi
    done <<< "$available_remotes"

    if [ ${#remotes_needing_updates[@]} -gt 0 ]; then
        log INFO "Found ${#remotes_needing_updates[@]} remote(s) needing updates: ${remotes_needing_updates[*]}"
        printf "%s\n" "${remotes_needing_updates[@]}"
    else
        log INFO "No changes detected across any remotes. No updates needed."
        echo ""
    fi
}

# Upload backup to specific remotes only
upload_backup_to_specific_remotes() {
    local remotes_needing_updates_str="$1"

    if [ ! -f "$COMPRESSED_FILE" ]; then
        log ERROR "Backup file not found: $COMPRESSED_FILE. Cannot upload."
        exit "$EXIT_INVALID_BACKUP"
    fi

    if [ -z "$remotes_needing_updates_str" ]; then
        log INFO "No remotes need updates. Skipping upload."
        return 0
    fi

    log INFO "Starting selective upload to remotes needing updates..."
    local upload_success_count=0
    local upload_failed_remotes=()
    local total_target_remotes=0

    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            total_target_remotes=$((total_target_remotes + 1))
            if upload_backup_to_remote "$remote"; then
                upload_success_count=$((upload_success_count + 1))
            else
                upload_failed_remotes+=("$remote")
            fi
        fi
    done <<< "$remotes_needing_updates_str"

    if [ "$upload_success_count" -eq "$total_target_remotes" ]; then
        log SUCCESS "Backup uploaded successfully to all $total_target_remotes target remotes."
    elif [ "$upload_success_count" -gt 0 ]; then
        log WARN "Backup uploaded to $upload_success_count out of $total_target_remotes target remotes."
        if [ ${#upload_failed_remotes[@]} -gt 0 ]; then
            log ERROR "Failed uploads to remotes: ${upload_failed_remotes[*]}"
        fi
    else
        log ERROR "Failed to upload backup to any target remote."
        exit "$EXIT_UNEXPECTED"
    fi
}

# Save current hash to specific remotes only
save_hash_to_specific_remotes() {
    local current_hash="$1"
    local remotes_needing_updates_str="$2"

    if [ -z "$current_hash" ]; then
        log WARN "Cannot save empty hash to remotes."
        return 1
    fi

    if [ -z "$remotes_needing_updates_str" ]; then
        log INFO "No remotes need hash updates. Skipping."
        return 0
    fi

    log INFO "Saving current backup hash to updated remotes..."
    local hash_success_count=0
    local hash_failed_remotes=()

    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            if save_current_remote_hash "$remote" "$current_hash"; then
                hash_success_count=$((hash_success_count + 1))
            else
                hash_failed_remotes+=("$remote")
            fi
        fi
    done <<< "$remotes_needing_updates_str"

    if [ ${#hash_failed_remotes[@]} -gt 0 ]; then
        log WARN "Failed to save hash to some remotes: ${hash_failed_remotes[*]}"
    fi

    return 0
}

# --- Bitwarden Operations ---

bw_logout() {
    log INFO "Logging out from any existing Bitwarden session..."
    bw logout >/dev/null 2>&1 || log INFO "Already logged out or no session."
}

bw_login() {
    log INFO "Logging into Bitwarden using API key..."
    export BW_CLIENTID="${BW_CLIENTID}"
    export BW_CLIENTSECRET="${BW_CLIENTSECRET}"
    export BW_PASSWORD="${BW_PASSWORD}"

    # Capture both stdout and stderr for debugging
    local login_output
    if ! login_output=$(bw login --apikey 2>&1); then
        log ERROR "Failed to log into Bitwarden with API key. Error details:"
        log ERROR "$login_output"
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

    # Validate session token exists
    if [ -z "${BW_SESSION:-}" ]; then
        log ERROR "BW_SESSION is empty. Vault must be unlocked first."
        exit "$EXIT_UNLOCK_FAILED"
    fi

    log INFO "Syncing vault data..."
    if ! timeout 60 bw sync --session "$BW_SESSION" >/dev/null 2>&1; then
        log WARN "Vault sync failed or timed out after 60 seconds. Proceeding with export using potentially stale local data."
        log WARN "Consider checking your network connection and Bitwarden server status."
    else
        log SUCCESS "Vault sync completed successfully."
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
    # Cross-platform file size for log message
    local export_size
    if export_size=$(stat -c%s "$RAW_FILE" 2>/dev/null); then
        log INFO "Exported ${RAW_FILE} ($export_size bytes)"
    elif export_size=$(stat -f%z "$RAW_FILE" 2>/dev/null); then
        log INFO "Exported ${RAW_FILE} ($export_size bytes)"
    else
        log INFO "Exported ${RAW_FILE} (size unknown bytes)"
    fi
}

validate_export() {
    log INFO "Validating the exported file..."
    if [ ! -s "$RAW_FILE" ]; then
        log ERROR "Backup file is empty or does not exist: $RAW_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log INFO "Backup file exists and is not empty."

    local filesize
    # Cross-platform file size detection (Linux vs macOS)
    if command -v stat >/dev/null 2>&1; then
        # Try Linux format first, then macOS format
        if filesize=$(stat -c%s "$RAW_FILE" 2>/dev/null); then
            log INFO "Backup file size: $filesize bytes."
        elif filesize=$(stat -f%z "$RAW_FILE" 2>/dev/null); then
            log INFO "Backup file size: $filesize bytes."
        else
            log WARN "Could not get size of backup file '$RAW_FILE' (tried both Linux and macOS stat formats). Skipping size check."
            filesize=""
        fi

        # Validate file size if we got it
        if [ -n "$filesize" ] && [ "$filesize" -lt "$MIN_BACKUP_SIZE" ]; then
            log WARN "Backup file size ($filesize bytes) is less than the minimum expected size ($MIN_BACKUP_SIZE bytes). This might indicate an issue."
            exit "$EXIT_INVALID_BACKUP" # Making minimum size a hard error
        fi
    else
        log WARN "stat command not found. Skipping file size check."
    fi

    if ! jq empty "$RAW_FILE" >/dev/null 2>&1; then
        log ERROR "Backup file contains invalid JSON: $RAW_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log SUCCESS "Backup file is valid JSON."
}


# Cross-platform SHA256 calculation
calculate_sha256() {
    local filepath="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        # Linux/GNU coreutils
        sha256sum "$filepath" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        # macOS/BSD systems
        shasum -a 256 "$filepath" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        # Fallback to OpenSSL (available on most systems)
        openssl dgst -sha256 "$filepath" | awk '{print $NF}'
    else
        log ERROR "No SHA256 utility found (tried sha256sum, shasum, openssl)"
        exit "$EXIT_MISSING_DEP"
    fi
}

# Calculate SHA256 hash of a file
get_local_file_hash() {
    local filepath="$1"
    if [ -f "$filepath" ]; then
        calculate_sha256 "$filepath"
    else
        echo "" # Return empty string if file doesn't exist locally
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

    # Encrypt with AES-256-CBC and PBKDF2.
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
    local temp_decrypted_file # Declare the variable
    temp_decrypted_file=$(mktemp "${BACKUP_DIR}/bw_decrypt_verify.XXXXXXXXXX.gz") # Assign the result of mktemp

    # Set secure permissions immediately after creation
    chmod 600 "$temp_decrypted_file" || {
        log ERROR "Failed to set secure permissions on temporary file"
        rm -f "$temp_decrypted_file" || true
        exit "$EXIT_INVALID_BACKUP"
    }

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

    if gzip -c -"${COMPRESSION_LEVEL}" "$RAW_FILE" > "$temp_compressed_file"; then
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

# --- Notification Function (requires 'apprise' command) ---
# shellcheck disable=SC2317
send_notification() {
    local level="$1"
    local message="$2"
    local title="Bitwarden Backup Notification" # Default title

    # Only send if APPRISE_URLS is set and not empty
    if [ -z "$APPRISE_URLS" ]; then
        log DEBUG "APPRISE_URLS not set. Skipping notification."
        return 0 # Do nothing if no URLs are configured
    fi

    # Determine Apprise tag and title based on message level
    case "$level" in
        SUCCESS)
            title="Bitwarden Backup SUCCESS"
            ;;
        WARN)
            title="Bitwarden Backup WARNING"
            ;;
        ERROR)
            title="Bitwarden Backup FAILURE"
            ;;
        INFO|DEBUG)
            # Optionally send INFO/DEBUG if needed, default is just INFO/DEBUG logs
            # If you want *all* logs sent, remove this return
             log DEBUG "Skipping INFO/DEBUG notification level."
             return 0
            ;;
        *)
            title="Bitwarden Backup Notification" # Fallback title
            ;;
    esac

    log DEBUG "Attempting to send $level notification via Apprise..."

    # Use a loop to handle multiple URLs from the environment variable
    # Assumes URLs are separated by space or newline
    IFS=$'\n ' read -ra urls_array <<< "$APPRISE_URLS"
    local apprise_exit_status=0

    for url in "${urls_array[@]}"; do
         if [ -n "$url" ]; then # Check if URL is not empty
             if ! apprise -v -t "$title" -b "$message" "$url" >/dev/null 2>&1; then
                 apprise_exit_status=$?
                 log WARN "Failed to send Apprise notification to $url (Exit status $apprise_exit_status). Check Apprise URL or configuration."
             fi
         fi
    done

    log DEBUG "Apprise notification attempt finished."
    return 0 # Always return 0 so notification failure doesn't kill the script
}

# Prune old backups from all remotes
prune_old_backups_from_all_remotes() {
    log INFO "Pruning old backups from all remotes..."

    local available_remotes
    available_remotes=$(get_available_remotes)
    if [ -z "$available_remotes" ]; then
        log WARN "No remotes found for pruning."
        return 0
    fi

    local total_remotes
    total_remotes=$(echo "$available_remotes" | wc -l | tr -d ' ')
    log INFO "Starting pruning process for $total_remotes remotes..."

    # Use parallel processing if more than 3 remotes
    if [ "$total_remotes" -gt 3 ] && command -v xargs >/dev/null 2>&1; then
        log INFO "Using parallel processing for pruning ($total_remotes remotes)..."
        local prune_success_count=0

        # Create a function for xargs to call
        export -f prune_old_backups_from_remote log
        export PROJECT_RCLONE_CONFIG_FILE BACKUP_PATH RETENTION_COUNT
        export COLOR_RESET COLOR_INFO COLOR_WARN COLOR_ERROR COLOR_SUCCESS COLOR_DEBUG

        # Run pruning in parallel (max 4 concurrent jobs)
        if echo "$available_remotes" | xargs -I {} -P 4 -n 1 bash -c 'prune_old_backups_from_remote "$@"' _ {}; then
            log SUCCESS "Parallel pruning completed for all remotes."
        else
            log WARN "Some parallel pruning operations may have failed."
        fi
        return 0
    fi

    # Sequential processing (original logic)
    local prune_success_count=0
    local prune_failed_remotes=()

    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            if prune_old_backups_from_remote "$remote"; then
                prune_success_count=$((prune_success_count + 1))
            else
                prune_failed_remotes+=("$remote")
            fi
        fi
    done <<< "$available_remotes"

    if [ "$prune_success_count" -eq "$total_remotes" ]; then
        log SUCCESS "Pruning completed successfully on all $total_remotes remotes."
    else
        log WARN "Pruning completed on $prune_success_count out of $total_remotes remotes."
        if [ ${#prune_failed_remotes[@]} -gt 0 ]; then
            log ERROR "Pruning failed on remotes: ${prune_failed_remotes[*]}"
        fi
    fi

    return 0
}

# --- Main Execution ---
main() {
    log INFO "Starting Bitwarden backup process with multi-remote support..."

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

    # Get available remotes
    local available_remotes
    available_remotes=$(get_available_remotes)
    if [ -z "$available_remotes" ]; then
        log ERROR "No remotes found in configuration. Cannot proceed."
        exit "$EXIT_UNEXPECTED"
    fi

    local remote_count
    remote_count=$(echo "$available_remotes" | wc -l | tr -d ' ')
    log INFO "Found $remote_count configured remote(s) for backup operations."

    # Check for changes across all remotes
    local changes_result
    changes_result=$(check_changes_across_remotes "$current_raw_hash" "$available_remotes")

    if [ -n "$changes_result" ]; then
        changes_detected=true
        local remotes_needing_updates_count
        remotes_needing_updates_count=$(echo "$changes_result" | wc -l | tr -d ' ')
        log INFO "Found $remotes_needing_updates_count remote(s) needing updates. Proceeding with selective backup."

        # Proceed with compression, encryption, and upload
        compress_backup # Creates temp .gz file
        encrypt_backup  # Encrypts temp .gz, creates temp .enc, removes .gz, updates COMPRESSED_FILE
        encrypt_verify  # Verifies temp .enc, renames to final .enc, updates COMPRESSED_FILE, sets permissions

        # Upload to specific remotes only
        upload_backup_to_specific_remotes "$changes_result"

        # If upload was successful, save the hash of the raw data to updated remotes only
        save_hash_to_specific_remotes "$current_raw_hash" "$changes_result" || log WARN "Failed to save the new hash to some remotes after successful backup upload."

    else
        changes_detected=false
        log INFO "No changes detected across any remotes. Skipping backup creation and upload."
    fi

    # Prune old backups from all remotes
    prune_old_backups_from_all_remotes

    log SUCCESS "Bitwarden backup process completed."
    if [ "$changes_detected" = false ]; then
         log SUCCESS "No new backup uploaded as no changes were detected across $remote_count remotes."
    else
         # Show actual count of updated remotes instead of total remotes
         local updated_remotes_count
         updated_remotes_count=$(echo "$changes_result" | wc -l | tr -d ' ')
         if [ -n "$COMPRESSED_FILE" ] && [ -f "$COMPRESSED_FILE" ]; then
            log SUCCESS "New backup file uploaded to $updated_remotes_count out of $remote_count remotes: $(basename "$COMPRESSED_FILE")"
         else
             log SUCCESS "New backup was processed and uploaded to $updated_remotes_count out of $remote_count remotes."
         fi
    fi

    # Exit with code 0 on success. The trap will pick this up.
    exit "$EXIT_SUCCESS"
}

# Execute the main function
main

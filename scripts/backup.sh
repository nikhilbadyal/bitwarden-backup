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
COMPRESSED_FILE="" # Will be set during secure pipe-based export
export NODE_NO_DEPRECATION=1 # Suppress Node.js deprecation warnings from bw CLI
changes_detected=false # Make this global so the trap can access it

# Global arrays to track remote success/failure for final notification
declare -a SUCCESSFUL_REMOTES=()
declare -a FAILED_REMOTES=()
declare -a ALL_REMOTES=()

readonly RETENTION_COUNT="${RETENTION_COUNT:-240}"
readonly PBKDF2_ITERATIONS="${PBKDF2_ITERATIONS:-600000}"
readonly BITWARDEN_SYNC_TIMEOUT="${BITWARDEN_SYNC_TIMEOUT:-60}"
readonly PARALLEL_THRESHOLD="${PARALLEL_THRESHOLD:-3}"
readonly MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-4}"

# Export configuration
readonly EXPORT_PERSONAL="${EXPORT_PERSONAL:-true}"
readonly EXPORT_ORGANIZATIONS="${EXPORT_ORGANIZATIONS:-false}"
readonly BW_ORGANIZATION_IDS="${BW_ORGANIZATION_IDS:-}"

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

    # Remove the compressed/encrypted file if it exists, regardless of success,
    # as it's only kept temporarily for upload from this ephemeral server.
    if [ -f "$COMPRESSED_FILE" ]; then
        log DEBUG "Removing temporary compressed/encrypted file: $COMPRESSED_FILE"
        rm -f "$COMPRESSED_FILE" || log WARN "Failed to remove temporary compressed/encrypted file: $COMPRESSED_FILE"
    fi

    # Clean up any temporary jq files that might be left behind
    if [ -n "${BACKUP_DIR:-}" ] && [ -d "${BACKUP_DIR}" ]; then
        log DEBUG "Cleaning up temporary jq files..."
        find "${BACKUP_DIR}" -name "jq_temp_*" -type f -delete 2>/dev/null || true
        find "${BACKUP_DIR}" -name "org_temp_*" -type f -delete 2>/dev/null || true
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
             # Add remote status summary even when no changes
             if [ ${#ALL_REMOTES[@]} -gt 0 ]; then
                 final_message+="

🔍 Remote Status:"
                 for remote in "${ALL_REMOTES[@]}"; do
                     final_message+="
  ✅ $remote: Up to date"
                 done
             fi
         else
              # Use the global COMPRESSED_FILE variable
              # Check if COMPRESSED_FILE is set before trying to get basename
              if [ -n "$COMPRESSED_FILE" ] && [ -f "$COMPRESSED_FILE" ]; then
                  final_message="Bitwarden backup script completed successfully. New backup uploaded: $(basename "$COMPRESSED_FILE")."
              else
                  final_message="Bitwarden backup script completed successfully. New backup was processed and uploaded." # Fallback message
              fi

              # Add detailed remote status
              if [ ${#ALL_REMOTES[@]} -gt 0 ]; then
                  final_message+="

📊 Remote Status:"

                  # Show successful remotes
                  if [ ${#SUCCESSFUL_REMOTES[@]} -gt 0 ]; then
                      for remote in "${SUCCESSFUL_REMOTES[@]}"; do
                          final_message+="
  ✅ $remote: Success"
                      done
                  fi

                  # Show failed remotes
                  if [ ${#FAILED_REMOTES[@]} -gt 0 ]; then
                      for remote in "${FAILED_REMOTES[@]}"; do
                          final_message+="
  ❌ $remote: Failed"
                      done
                  fi

                  # Show remotes that were up to date (not in success or failed arrays)
                  local up_to_date_remotes=()
                  for remote in "${ALL_REMOTES[@]}"; do
                      local found_successful=false
                      local found_failed=false

                      # Check if remote is in successful array
                      for successful_remote in "${SUCCESSFUL_REMOTES[@]}"; do
                          if [ "$remote" = "$successful_remote" ]; then
                              found_successful=true
                              break
                          fi
                      done

                      # Check if remote is in failed array
                      if [ "$found_successful" = false ]; then
                          for failed_remote in "${FAILED_REMOTES[@]}"; do
                              if [ "$remote" = "$failed_remote" ]; then
                                  found_failed=true
                                  break
                              fi
                          done
                      fi

                      # If not found in either, it was up to date
                      if [ "$found_successful" = false ] && [ "$found_failed" = false ]; then
                          up_to_date_remotes+=("$remote")
                      fi
                  done

                  # Show up-to-date remotes
                  for remote in "${up_to_date_remotes[@]}"; do
                      final_message+="
  ✅ $remote: Up to date"
                  done

                  # Add summary with emojis for better readability
                  local summary=""
                  if [ ${#SUCCESSFUL_REMOTES[@]} -gt 0 ]; then
                      summary+="📤 ${#SUCCESSFUL_REMOTES[@]} uploaded"
                  fi
                  if [ ${#up_to_date_remotes[@]} -gt 0 ]; then
                      if [ -n "$summary" ]; then summary+=", "; fi
                      summary+="✅ ${#up_to_date_remotes[@]} up-to-date"
                  fi
                  if [ ${#FAILED_REMOTES[@]} -gt 0 ]; then
                      if [ -n "$summary" ]; then summary+=", "; fi
                      summary+="❌ ${#FAILED_REMOTES[@]} failed"
                  fi

                  final_message+="

📋 Summary: $summary"
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

        # Add remote status if backup process started and remotes were initialized
        if [ ${#ALL_REMOTES[@]} -gt 0 ]; then
            final_message+="

⚠️ Remote Status at time of failure:"

            # Show successful remotes if any
            if [ ${#SUCCESSFUL_REMOTES[@]} -gt 0 ]; then
                for remote in "${SUCCESSFUL_REMOTES[@]}"; do
                    final_message+="
  ✅ $remote: Success"
                done
            fi

            # Show failed remotes if any
            if [ ${#FAILED_REMOTES[@]} -gt 0 ]; then
                for remote in "${FAILED_REMOTES[@]}"; do
                    final_message+="
  ❌ $remote: Failed"
                done
            fi

            # Show remotes that weren't processed yet
            local unprocessed_remotes=()
            for remote in "${ALL_REMOTES[@]}"; do
                local found=false

                # Check if remote is in successful or failed arrays
                for processed_remote in "${SUCCESSFUL_REMOTES[@]}" "${FAILED_REMOTES[@]}"; do
                    if [ "$remote" = "$processed_remote" ]; then
                        found=true
                        break
                    fi
                done

                # If not found in either, it was not processed
                if [ "$found" = false ]; then
                    unprocessed_remotes+=("$remote")
                fi
            done

            # Show unprocessed remotes
            for remote in "${unprocessed_remotes[@]}"; do
                final_message+="
  ⏸️ $remote: Not processed"
            done
        fi

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

    # Test Bitwarden CLI execution
    if command -v bw >/dev/null 2>&1; then
        log DEBUG "Testing Bitwarden CLI execution..."
        if ! bw --version >/dev/null 2>&1; then
            log ERROR "Bitwarden CLI found but cannot execute."
            log ERROR "If installing manually, use: sudo npm install -g @bitwarden/cli"
            exit "$EXIT_MISSING_DEP"
        fi
        log DEBUG "Bitwarden CLI is working correctly."
    fi

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
                SUCCESSFUL_REMOTES+=("$remote")
            else
                upload_failed_remotes+=("$remote")
                FAILED_REMOTES+=("$remote")
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

configure_bitwarden_server() {
    log INFO "Configuring Bitwarden server settings..."

    # Check if any server configuration is provided
    if [ -n "${BW_SERVER:-}" ]; then
        log INFO "Configuring Bitwarden server: $BW_SERVER"
        if ! bw config server "$BW_SERVER" >/dev/null 2>&1; then
            log ERROR "Failed to configure Bitwarden server: $BW_SERVER"
            exit "$EXIT_LOGIN_FAILED"
        fi
        log SUCCESS "Bitwarden server configured: $BW_SERVER"
    elif [ -n "${BW_WEB_VAULT:-}" ] || [ -n "${BW_API:-}" ] || [ -n "${BW_IDENTITY:-}" ] || [ -n "${BW_ICONS:-}" ] || [ -n "${BW_NOTIFICATIONS:-}" ] || [ -n "${BW_EVENTS:-}" ] || [ -n "${BW_KEY_CONNECTOR:-}" ]; then
        log INFO "Configuring individual Bitwarden service URLs..."

        # Build the config command with individual service URLs
        local config_cmd="bw config server"

        [ -n "${BW_WEB_VAULT:-}" ] && config_cmd+=" --web-vault \"$BW_WEB_VAULT\""
        [ -n "${BW_API:-}" ] && config_cmd+=" --api \"$BW_API\""
        [ -n "${BW_IDENTITY:-}" ] && config_cmd+=" --identity \"$BW_IDENTITY\""
        [ -n "${BW_ICONS:-}" ] && config_cmd+=" --icons \"$BW_ICONS\""
        [ -n "${BW_NOTIFICATIONS:-}" ] && config_cmd+=" --notifications \"$BW_NOTIFICATIONS\""
        [ -n "${BW_EVENTS:-}" ] && config_cmd+=" --events \"$BW_EVENTS\""
        [ -n "${BW_KEY_CONNECTOR:-}" ] && config_cmd+=" --key-connector \"$BW_KEY_CONNECTOR\""

        log INFO "Executing: $config_cmd"
        if ! eval "$config_cmd" >/dev/null 2>&1; then
            log ERROR "Failed to configure individual Bitwarden service URLs"
            exit "$EXIT_LOGIN_FAILED"
        fi
        log SUCCESS "Individual Bitwarden service URLs configured"
    else
        log INFO "No custom Bitwarden server configuration provided, using default (vault.bitwarden.com)"
    fi

    # Display current server configuration
    local current_server
    if current_server=$(bw config server 2>/dev/null); then
        if [ -n "$current_server" ]; then
            log INFO "Current Bitwarden server: $current_server"
        else
            log INFO "Using default Bitwarden server: vault.bitwarden.com"
        fi
    else
        log WARN "Could not retrieve current Bitwarden server configuration"
    fi
}

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
    local max_attempts="${BW_UNLOCK_RETRIES:-3}"
    local attempt=1
    local retry_delay="${BW_UNLOCK_RETRY_DELAY:-5}"  # seconds between attempts

        while [ "$attempt" -le "$max_attempts" ]; do
        log INFO "Unlock attempt $attempt of $max_attempts..."

        if unlock_output=$(bw unlock --raw --passwordenv BW_PASSWORD 2>&1); then
            # Success - validate session token
            if [ -n "$unlock_output" ]; then
                BW_SESSION="$unlock_output"
                export BW_SESSION
                log SUCCESS "Vault unlocked successfully on attempt $attempt."
                return 0
            else
                log WARN "Attempt $attempt: Unlock command succeeded but returned an empty session token."
            fi
        else
            log WARN "Attempt $attempt failed. Output: ${unlock_output}"
        fi

        # If this wasn't the last attempt, wait before retrying
        if [ "$attempt" -lt "$max_attempts" ]; then
            log INFO "Waiting ${retry_delay} seconds before retry..."
            sleep "$retry_delay"
        fi

        attempt=$((attempt + 1))
    done

    # All attempts failed
    log ERROR "Failed to unlock vault after $max_attempts attempts. Check BW_PASSWORD."
    log ERROR "Last attempt output: ${unlock_output}"
    exit "$EXIT_UNLOCK_FAILED"
}

export_data() {
    log INFO "Exporting vault data..."

    # Validate session token exists
    if [ -z "${BW_SESSION:-}" ]; then
        log ERROR "BW_SESSION is empty. Vault must be unlocked first."
        exit "$EXIT_UNLOCK_FAILED"
    fi

    log INFO "Syncing vault data..."
    if ! timeout "$BITWARDEN_SYNC_TIMEOUT" bw sync --session "$BW_SESSION" >/dev/null 2>&1; then
        log WARN "Vault sync failed or timed out after $BITWARDEN_SYNC_TIMEOUT seconds. Proceeding with export using potentially stale local data."
        log WARN "Consider checking your network connection and Bitwarden server status."
    else
        log SUCCESS "Vault sync completed successfully."
    fi

    # Check what should be exported
    if [[ "$EXPORT_PERSONAL" != "true" && "$EXPORT_ORGANIZATIONS" != "true" ]]; then
        log ERROR "No export types enabled. Set EXPORT_PERSONAL=true and/or EXPORT_ORGANIZATIONS=true"
        exit "$EXIT_EXPORT_FAILED"
    fi

    # Determine if we need consolidated format (when organizations are exported)
    local use_consolidated_format=false
    if [[ "$EXPORT_ORGANIZATIONS" == "true" && -n "$BW_ORGANIZATION_IDS" ]]; then
        use_consolidated_format=true
    fi

    local final_data=""
    local export_count=0

    # Export personal vault if requested
    local personal_export=""
    if [[ "$EXPORT_PERSONAL" == "true" ]]; then
        log INFO "Exporting personal vault..."

        if ! personal_export=$(echo "$BW_PASSWORD" | bw export --raw --session "$BW_SESSION" --format json 2>/dev/null); then
            log ERROR "Failed to export personal vault data."
            exit "$EXIT_EXPORT_FAILED"
        fi

        # Validate personal export
        if [ -z "$personal_export" ] || ! echo "$personal_export" | jq empty >/dev/null 2>&1; then
            log ERROR "Personal vault export is empty or contains invalid JSON."
            exit "$EXIT_EXPORT_FAILED"
        fi

        export_count=$((export_count + 1))
        log SUCCESS "Personal vault exported successfully"
    fi

    # Export organization vaults if requested
    local org_exports=""
    if [[ "$EXPORT_ORGANIZATIONS" == "true" ]]; then
        if [ -z "$BW_ORGANIZATION_IDS" ]; then
            log WARN "EXPORT_ORGANIZATIONS is enabled but BW_ORGANIZATION_IDS is empty."
            log INFO "To get organization IDs, run: bw list organizations --session \$BW_SESSION"
            # If personal export is also disabled, this is an error
            if [[ "$EXPORT_PERSONAL" != "true" ]]; then
                log ERROR "Cannot export organizations without BW_ORGANIZATION_IDS and personal export is disabled."
                log ERROR "Either set BW_ORGANIZATION_IDS or enable EXPORT_PERSONAL=true"
                exit "$EXIT_EXPORT_FAILED"
            fi
        else
            log INFO "Exporting organization vaults..."

            # Initialize organizations object
            org_exports='{}'

            # Split organization IDs by comma
            IFS=',' read -ra ORG_IDS <<< "$BW_ORGANIZATION_IDS"

            for org_id in "${ORG_IDS[@]}"; do
                # Trim whitespace
                org_id=$(echo "$org_id" | tr -d '[:space:]')

                if [ -n "$org_id" ]; then
                    log INFO "Exporting organization: $org_id"

                    local org_export
                    if ! org_export=$(echo "$BW_PASSWORD" | bw export --raw --session "$BW_SESSION" --format json --organizationid "$org_id" 2>/dev/null); then
                        log ERROR "Failed to export organization $org_id."
                        exit "$EXIT_EXPORT_FAILED"
                    fi

                    # Validate organization export (allow empty organizations)
                    if [ -n "$org_export" ] && echo "$org_export" | jq empty >/dev/null 2>&1; then
                        # Add organization data to organizations object using temporary files
                        local temp_org_base="${BACKUP_DIR}/org_temp_${TIMESTAMP}_${org_id}"
                        local temp_org_export="${temp_org_base}_export.json"
                        local temp_org_current="${temp_org_base}_current.json"

                        # Write current org_exports and new org_export to temp files
                        echo "$org_exports" > "$temp_org_current"
                        echo "$org_export" > "$temp_org_export"

                        # Use jq with slurpfile to avoid command line argument limits
                        org_exports=$(jq --slurpfile org "$temp_org_export" --arg orgid "$org_id" '.[$orgid] = $org[0]' "$temp_org_current")

                        # Clean up temporary files
                        rm -f "$temp_org_export" "$temp_org_current" 2>/dev/null || true

                        export_count=$((export_count + 1))
                        log SUCCESS "Organization $org_id exported successfully"
                    else
                        log WARN "Organization $org_id export is empty or invalid (organization may be empty)"
                    fi
                fi
            done
        fi
    fi

    # Check if we have any exports
    if [ "$export_count" -eq 0 ]; then
        log ERROR "No vault data was exported. Check your configuration."
        exit "$EXIT_EXPORT_FAILED"
    fi

    # Create final data based on format requirements
    if [ "$use_consolidated_format" = true ]; then
        # Use consolidated format when organizations are exported
        log INFO "Creating consolidated backup with personal and organization data..."
        local consolidated_data='{"personal": null, "organizations": {}}'

        # Use temporary files to avoid "Argument list too long" error with large exports
        local temp_base="${BACKUP_DIR}/jq_temp_${TIMESTAMP}"
        local temp_consolidated="${temp_base}_consolidated.json"
        local temp_personal="${temp_base}_personal.json"
        local temp_orgs="${temp_base}_orgs.json"

        # Write consolidated_data to temp file
        echo "$consolidated_data" > "$temp_consolidated"

        if [[ "$EXPORT_PERSONAL" == "true" ]]; then
            # Write personal export to temp file
            echo "$personal_export" > "$temp_personal"
            # Use jq with slurpfile to read from file instead of command line
            consolidated_data=$(jq --slurpfile personal "$temp_personal" '.personal = $personal[0]' "$temp_consolidated")
            echo "$consolidated_data" > "$temp_consolidated"
        fi

        if [[ -n "$org_exports" && "$org_exports" != "{}" ]]; then
            # Write org exports to temp file
            echo "$org_exports" > "$temp_orgs"
            # Use jq with slurpfile to read from file instead of command line
            consolidated_data=$(jq --slurpfile orgs "$temp_orgs" '.organizations = $orgs[0]' "$temp_consolidated")
            echo "$consolidated_data" > "$temp_consolidated"
        fi

        final_data="$consolidated_data"

        # Clean up temporary files
        rm -f "$temp_consolidated" "$temp_personal" "$temp_orgs" 2>/dev/null || true

        log INFO "Using consolidated format for $export_count export(s)"
    else
        # Use standard format for personal-only exports
        if [[ "$EXPORT_PERSONAL" == "true" ]]; then
            final_data="$personal_export"
            log INFO "Using standard Bitwarden format for personal vault export"
        else
            log ERROR "No valid export configuration for standard format."
            exit "$EXIT_EXPORT_FAILED"
        fi
    fi

    log INFO "Performing secure compression and encryption..."

    local temp_encrypted_file="${BACKUP_DIR}/bw_backup_${TIMESTAMP}.json.gz.enc"

    if [ -z "${ENCRYPTION_PASSWORD:-}" ]; then
        log ERROR "ENCRYPTION_PASSWORD not set. Cannot encrypt backup."
        exit "$EXIT_COMPRESS_FAILED"
    fi

    # Secure pipe: final JSON -> gzip -> openssl encrypt -> file
    # This ensures unencrypted data never touches the disk
    if ! echo "$final_data" | jq -c '.' | \
         gzip -c -"${COMPRESSION_LEVEL}" | \
         openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITERATIONS" -salt -pass env:ENCRYPTION_PASSWORD > "$temp_encrypted_file"; then
        log ERROR "Failed to create secure encrypted backup."
        rm -f "$temp_encrypted_file" || true
        exit "$EXIT_EXPORT_FAILED"
    fi

    # Set secure permissions on encrypted file
    chmod 600 "$temp_encrypted_file" || {
        log WARN "Could not set secure permissions on encrypted backup file."
    }

    # Update global variable to point to encrypted file
    COMPRESSED_FILE="$temp_encrypted_file"

    # Get file size for logging
    local backup_size
    if backup_size=$(stat -c%s "$COMPRESSED_FILE" 2>/dev/null); then
        log SUCCESS "Secure encrypted backup created: $COMPRESSED_FILE ($backup_size bytes)"
    elif backup_size=$(stat -f%z "$COMPRESSED_FILE" 2>/dev/null); then
        log SUCCESS "Secure encrypted backup created: $COMPRESSED_FILE ($backup_size bytes)"
    else
        log SUCCESS "Secure encrypted backup created: $COMPRESSED_FILE"
    fi
}

validate_export() {
    log INFO "Validating the encrypted backup file..."

    # Validate the encrypted file directly
    if [ ! -s "$COMPRESSED_FILE" ]; then
        log ERROR "Encrypted backup file is empty or does not exist: $COMPRESSED_FILE"
        exit "$EXIT_INVALID_BACKUP"
    fi
    log INFO "Encrypted backup file exists and is not empty."

    local filesize
    # Cross-platform file size detection (Linux vs macOS)
    if command -v stat >/dev/null 2>&1; then
        # Try Linux format first, then macOS format
        if filesize=$(stat -c%s "$COMPRESSED_FILE" 2>/dev/null); then
            log INFO "Encrypted backup file size: $filesize bytes."
        elif filesize=$(stat -f%z "$COMPRESSED_FILE" 2>/dev/null); then
            log INFO "Encrypted backup file size: $filesize bytes."
        else
            log WARN "Could not get size of encrypted backup file '$COMPRESSED_FILE' (tried both Linux and macOS stat formats). Skipping size check."
            filesize=""
        fi

        # Validate file size if we got it (encrypted files will be larger, so adjust minimum)
        local min_encrypted_size=$((MIN_BACKUP_SIZE + 200))  # Account for encryption overhead
        if [ -n "$filesize" ] && [ "$filesize" -lt "$min_encrypted_size" ]; then
            log WARN "Encrypted backup file size ($filesize bytes) is less than expected minimum size ($min_encrypted_size bytes). This might indicate an issue."
            exit "$EXIT_INVALID_BACKUP"
        fi
    else
        log WARN "stat command not found. Skipping file size check."
    fi

    # Validate that the file can be decrypted and contains valid JSON
    log INFO "Validating encrypted backup can be decrypted and contains valid JSON..."

    # Test decryption and JSON validation (should succeed with current iteration count)
    if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter "$PBKDF2_ITERATIONS" -salt \
         -in "$COMPRESSED_FILE" -pass env:ENCRYPTION_PASSWORD 2>/dev/null | \
         gzip -dc | \
         jq empty > /dev/null 2>&1; then
        log ERROR "Encrypted backup file failed validation (decryption, decompression, or JSON parsing failed)"
        exit "$EXIT_INVALID_BACKUP"
    fi

    log SUCCESS "Encrypted backup file validation passed - can be decrypted and contains valid JSON."
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
    # Temporarily disable strict mode for command substitution to prevent silent exit
    set +e
    available_remotes=$(get_available_remotes)
    local remotes_exit_code=$?
    set -e

    if [ $remotes_exit_code -ne 0 ] || [ -z "$available_remotes" ]; then
        log WARN "Failed to get available remotes for pruning (exit code: $remotes_exit_code)."
        log WARN "Skipping pruning operation."
        return 0
    fi

    local total_remotes
    # Temporarily disable strict mode for command substitution to prevent silent exit
    set +e
    total_remotes=$(echo "$available_remotes" | wc -l | tr -d ' ')
    local count_exit_code=$?
    set -e

    if [ $count_exit_code -ne 0 ] || [ -z "$total_remotes" ]; then
        log WARN "Failed to count remotes for pruning, attempting to continue..."
        total_remotes="unknown"
    fi
    log INFO "Starting pruning process for $total_remotes remotes..."

    # Use parallel processing if more than threshold remotes
    if [ "$total_remotes" -gt "$PARALLEL_THRESHOLD" ] && command -v xargs >/dev/null 2>&1; then
        log INFO "Using parallel processing for pruning ($total_remotes remotes)..."
        local prune_success_count=0

        # Create a function for xargs to call
        export -f prune_old_backups_from_remote log
        export PROJECT_RCLONE_CONFIG_FILE BACKUP_PATH RETENTION_COUNT
        export COLOR_RESET COLOR_INFO COLOR_WARN COLOR_ERROR COLOR_SUCCESS COLOR_DEBUG

        # Run pruning in parallel (configurable max concurrent jobs)
        if echo "$available_remotes" | xargs -I {} -P "$MAX_PARALLEL_JOBS" -n 1 bash -c 'prune_old_backups_from_remote "$@"' _ {}; then
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
    configure_bitwarden_server
    bw_login
    bw_unlock
    export_data
    validate_export

    # Calculate hash of the encrypted backup
    local current_backup_hash
    # Temporarily disable strict mode for command substitution to prevent silent exit
    set +e
    current_backup_hash=$(get_local_file_hash "$COMPRESSED_FILE")
    local hash_exit_code=$?
    set -e

    if [ $hash_exit_code -ne 0 ] || [ -z "$current_backup_hash" ]; then
        log ERROR "Failed to calculate hash of encrypted backup file: $COMPRESSED_FILE"
        log ERROR "Hash calculation exit code: $hash_exit_code"
        log ERROR "Ensure the file exists and SHA256 utilities are available."
        exit "$EXIT_INVALID_BACKUP"
    fi
    log DEBUG "Current encrypted backup hash: $current_backup_hash"

    # Get available remotes
    local available_remotes
    # Temporarily disable strict mode for command substitution to prevent silent exit
    set +e
    available_remotes=$(get_available_remotes)
    local remotes_exit_code=$?
    set -e

    if [ $remotes_exit_code -ne 0 ] || [ -z "$available_remotes" ]; then
        log ERROR "Failed to get available remotes from rclone configuration."
        log ERROR "get_available_remotes exit code: $remotes_exit_code"
        log ERROR "Check your rclone configuration and PROJECT_RCLONE_CONFIG_FILE."
        exit "$EXIT_UNEXPECTED"
    fi

    # Populate ALL_REMOTES array for final notification tracking
    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            ALL_REMOTES+=("$remote")
        fi
    done <<< "$available_remotes"

    local remote_count
    # Temporarily disable strict mode for command substitution to prevent silent exit
    set +e
    remote_count=$(echo "$available_remotes" | wc -l | tr -d ' ')
    local count_exit_code=$?
    set -e

    if [ $count_exit_code -ne 0 ] || [ -z "$remote_count" ]; then
        log WARN "Failed to count remotes, using array length instead."
        remote_count=${#ALL_REMOTES[@]}
    fi
    log INFO "Found $remote_count configured remote(s) for backup operations."

    # Check for changes across all remotes
    local changes_result
    # Temporarily disable strict mode for command substitution to prevent silent exit
    set +e
    changes_result=$(check_changes_across_remotes "$current_backup_hash" "$available_remotes")
    local changes_exit_code=$?
    set -e

    if [ $changes_exit_code -ne 0 ]; then
        log ERROR "Failed to check for changes across remotes."
        log ERROR "check_changes_across_remotes exit code: $changes_exit_code"
        log ERROR "Backup process cannot continue safely."
        exit "$EXIT_UNEXPECTED"
    fi

    if [ -n "$changes_result" ]; then
        changes_detected=true
        local remotes_needing_updates_count
        # Temporarily disable strict mode for command substitution to prevent silent exit
        set +e
        remotes_needing_updates_count=$(echo "$changes_result" | wc -l | tr -d ' ')
        local updates_count_exit_code=$?
        set -e

        if [ $updates_count_exit_code -ne 0 ] || [ -z "$remotes_needing_updates_count" ]; then
            log WARN "Failed to count remotes needing updates, using default message."
            log INFO "Found remotes needing updates. Proceeding with selective backup."
        else
            log INFO "Found $remotes_needing_updates_count remote(s) needing updates. Proceeding with selective backup."
        fi

        # Upload to specific remotes only (backup already created by export_data)
        upload_backup_to_specific_remotes "$changes_result"

        # If upload was successful, save the hash of the encrypted backup to updated remotes only
        save_hash_to_specific_remotes "$current_backup_hash" "$changes_result" || log WARN "Failed to save the new hash to some remotes after successful backup upload."

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
         # Temporarily disable strict mode for command substitution to prevent silent exit
         set +e
         updated_remotes_count=$(echo "$changes_result" | wc -l | tr -d ' ')
         local final_count_exit_code=$?
         set -e

         if [ $final_count_exit_code -ne 0 ] || [ -z "$updated_remotes_count" ]; then
             log WARN "Failed to count updated remotes for final message."
             if [ -n "$COMPRESSED_FILE" ] && [ -f "$COMPRESSED_FILE" ]; then
                log SUCCESS "New backup file uploaded to remotes: $(basename "$COMPRESSED_FILE")"
             else
                 log SUCCESS "New backup was processed and uploaded to remotes."
             fi
         else
             if [ -n "$COMPRESSED_FILE" ] && [ -f "$COMPRESSED_FILE" ]; then
                log SUCCESS "New backup file uploaded to $updated_remotes_count out of $remote_count remotes: $(basename "$COMPRESSED_FILE")"
             else
                 log SUCCESS "New backup was processed and uploaded to $updated_remotes_count out of $remote_count remotes."
             fi
         fi
    fi

    # Exit with code 0 on success. The trap will pick this up.
    exit "$EXIT_SUCCESS"
}

# --- Test Notification Mode ---
test_notification_mode() {
    log INFO "Running notification test mode..."

    # Load environment variables for notification testing
    check_dependencies() {
        # Only check for apprise when testing notifications
        if [ -n "${APPRISE_URLS:-}" ]; then
            if ! command -v "apprise" >/dev/null 2>&1; then
                log ERROR "apprise command not found but APPRISE_URLS is set."
                exit 1
            fi
        fi
    }

    check_dependencies

    # Mock some remotes for testing (use your actual remotes if setup-rclone was run)
    if [ -f "$PROJECT_RCLONE_CONFIG_FILE" ]; then
        local available_remotes
        available_remotes=$(get_available_remotes)
        if [ -n "$available_remotes" ]; then
            log INFO "Using actual configured remotes for test..."
            while IFS= read -r remote; do
                if [ -n "$remote" ]; then
                    ALL_REMOTES+=("$remote")
                fi
            done <<< "$available_remotes"
        fi
    fi

    # Fall back to mock remotes if no real ones configured
    if [ ${#ALL_REMOTES[@]} -eq 0 ]; then
        log INFO "No remotes configured, using mock remotes for test..."
        ALL_REMOTES=("r2" "e2" "aws-s3" "google-drive")
    fi

    # Test different notification scenarios
    case "${1:-success}" in
        success-all)
            log INFO "Testing SUCCESS notification (all remotes successful)..."
            # Mock all remotes as successful
            for remote in "${ALL_REMOTES[@]}"; do
                SUCCESSFUL_REMOTES+=("$remote")
            done
            changes_detected=true
            COMPRESSED_FILE="/tmp/bw_backup_20241218123456.json.gz.enc"
            ;;
        success-mixed)
            log INFO "Testing SUCCESS notification (mixed results)..."
            # Mock mixed results
            SUCCESSFUL_REMOTES+=("${ALL_REMOTES[0]}")
            if [ ${#ALL_REMOTES[@]} -gt 1 ]; then
                SUCCESSFUL_REMOTES+=("${ALL_REMOTES[1]}")
            fi
            if [ ${#ALL_REMOTES[@]} -gt 2 ]; then
                FAILED_REMOTES+=("${ALL_REMOTES[2]}")
            fi
            changes_detected=true
            COMPRESSED_FILE="/tmp/bw_backup_20241218123456.json.gz.enc"
            ;;
        no-changes)
            log INFO "Testing SUCCESS notification (no changes)..."
            changes_detected=false
            ;;
        failure)
            log INFO "Testing FAILURE notification..."
            # Mock partial failure
            if [ ${#ALL_REMOTES[@]} -gt 0 ]; then
                SUCCESSFUL_REMOTES+=("${ALL_REMOTES[0]}")
            fi
            if [ ${#ALL_REMOTES[@]} -gt 1 ]; then
                FAILED_REMOTES+=("${ALL_REMOTES[1]}")
            fi
            changes_detected=true
            # Simulate failure and trigger cleanup
            exit 8  # This will trigger the cleanup function with error code 8
            ;;
        *)
            log ERROR "Unknown test type: ${1}. Use: success-all, success-mixed, no-changes, or failure"
            exit 1
            ;;
    esac

    # Trigger cleanup which will send the notification
    log SUCCESS "Test notification will be sent via cleanup function..."
    exit 0  # This will trigger cleanup with success code
}

# Check for test notification mode
if [ "${1:-}" = "--test-notification" ]; then
    shift  # Remove the flag
    test_notification_mode "$@"
fi

# Execute the main function
main

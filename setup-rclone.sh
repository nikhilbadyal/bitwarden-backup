#!/bin/bash
set -euo pipefail

# Bitwarden Backup - Rclone Configuration Setup
# This script accepts an rclone configuration via base64 encoding to avoid typing errors
# and stores it in a project-specific location to avoid interfering with global rclone config

# --- Load Environment Variables ---
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Source .env file if it exists
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from: $ENV_FILE"
    # Export all variables from .env file
    set -a  # automatically export all variables
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a  # disable automatic export
    echo "Environment variables loaded successfully."
else
    echo "No .env file found at: $ENV_FILE"
    echo "Assuming environment variables are already set."
fi

# --- Colors for output ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;37m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[1;31m"
readonly COLOR_SUCCESS="\033[1;32m"

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
        *) level="DEBUG"; color="" ;;
    esac

    printf "%b[%s %s]%b %s\n" "$color" "$timestamp" "$level" "$COLOR_RESET" "$message" >&2
}

# --- Configuration Paths ---
# Use project-specific config location to avoid conflicts with user's global rclone config
readonly PROJECT_RCLONE_CONFIG_DIR="${BACKUP_DIR:-/tmp/bw_backup}/rclone"
readonly PROJECT_RCLONE_CONFIG_FILE="$PROJECT_RCLONE_CONFIG_DIR/rclone.conf"

# --- Environment Variable Validation ---
log INFO "Validating rclone configuration setup..."

# Check if base64 config is provided
if [ -z "${RCLONE_CONFIG_BASE64:-}" ]; then
    log ERROR "RCLONE_CONFIG_BASE64 environment variable is missing or empty."
    log ERROR "Please provide your rclone configuration as a base64 encoded string."
    log ERROR "Example: RCLONE_CONFIG_BASE64=\$(base64 -w 0 < ~/.config/rclone/rclone.conf)"
    exit 1
fi

log SUCCESS "RCLONE_CONFIG_BASE64 environment variable found."

# --- Rclone Configuration Setup ---
log INFO "Setting up project-specific rclone configuration..."

# Create project-specific config directory
if ! mkdir -p "$PROJECT_RCLONE_CONFIG_DIR"; then
    log ERROR "Failed to create project rclone config directory: $PROJECT_RCLONE_CONFIG_DIR"
    exit 1
fi
log SUCCESS "Project rclone config directory created: $PROJECT_RCLONE_CONFIG_DIR"

# Decode base64 config and write to project-specific location
log INFO "Decoding and writing rclone configuration..."
if ! echo "$RCLONE_CONFIG_BASE64" | base64 -d > "$PROJECT_RCLONE_CONFIG_FILE"; then
    log ERROR "Failed to decode base64 rclone configuration or write to file."
    log ERROR "Please check that RCLONE_CONFIG_BASE64 contains valid base64 encoded data."
    exit 1
fi

# Verify the decoded config file exists and is not empty
if [ ! -s "$PROJECT_RCLONE_CONFIG_FILE" ]; then
    log ERROR "Decoded rclone config file is empty or does not exist: $PROJECT_RCLONE_CONFIG_FILE"
    exit 1
fi

log SUCCESS "Rclone configuration decoded and written to: $PROJECT_RCLONE_CONFIG_FILE"

# Set secure permissions on the config file (owner read/write only)
if ! chmod 600 "$PROJECT_RCLONE_CONFIG_FILE"; then
    log WARN "Could not set secure permissions (600) on rclone config file."
else
    log INFO "Secure permissions (600) set on rclone config file."
fi

# --- Parse and Display Available Remotes ---
log INFO "Parsing available remotes from rclone configuration..."

# Extract remote names from the config file (lines starting with [remote_name])
available_remotes=$(grep -E '^\[.*\]$' "$PROJECT_RCLONE_CONFIG_FILE" | sed 's/\[\(.*\)\]/\1/' | grep -v '^$' || true)

if [ -z "$available_remotes" ]; then
    log ERROR "No remotes found in the rclone configuration."
    log ERROR "Please ensure your rclone config contains at least one remote configuration."
    exit 1
fi

log SUCCESS "Found the following remotes in configuration:"
echo "$available_remotes" | while IFS= read -r remote; do
    if [ -n "$remote" ]; then
        log INFO "  - $remote"
    fi
done

# --- Validate Remotes Accessibility (Optional Test) ---
if command -v rclone >/dev/null 2>&1; then
    log INFO "Testing remote accessibility (this may take a moment)..."

    # Test each remote by trying to list its root
    failed_remotes=()
    successful_remotes=()

    # Use process substitution to avoid subshell issues
    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            log INFO "Testing remote: $remote"
            if rclone --config "$PROJECT_RCLONE_CONFIG_FILE" lsd "$remote:" >/dev/null 2>&1; then
                log SUCCESS "  ✓ Remote '$remote' is accessible"
                successful_remotes+=("$remote")
            else
                log WARN "  ✗ Remote '$remote' failed accessibility test (credentials or network issue)"
                failed_remotes+=("$remote")
            fi
        fi
    done <<< "$available_remotes"

    if [ ${#failed_remotes[@]} -gt 0 ]; then
        log WARN "Some remotes failed accessibility tests. Backups may fail for these remotes:"
        for remote in "${failed_remotes[@]}"; do
            log WARN "  - $remote"
        done
    fi

    if [ ${#successful_remotes[@]} -gt 0 ]; then
        log SUCCESS "Successfully validated ${#successful_remotes[@]} remote(s)."
    fi
else
    log WARN "rclone command not found. Skipping remote accessibility test."
fi

# --- Export Configuration Path ---
# Write the config file path to a temp file for backup script to read
# (Export alone doesn't work across separate process invocations)
echo "PROJECT_RCLONE_CONFIG_FILE=\"$PROJECT_RCLONE_CONFIG_FILE\"" > "${BACKUP_DIR:-/tmp/bw_backup}/.rclone_config_path"
export PROJECT_RCLONE_CONFIG_FILE
log SUCCESS "Exported PROJECT_RCLONE_CONFIG_FILE=$PROJECT_RCLONE_CONFIG_FILE"
log SUCCESS "Config path written to ${BACKUP_DIR:-/tmp/bw_backup}/.rclone_config_path for backup script"

log SUCCESS "Rclone configuration setup completed successfully!"
log INFO "Backup script will use: --config $PROJECT_RCLONE_CONFIG_FILE"
log INFO "Total remotes configured: $(echo "$available_remotes" | wc -l)"

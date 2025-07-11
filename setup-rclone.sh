#!/bin/bash
set -euo pipefail

# Bitwarden Backup - Rclone Configuration Setup
# This script accepts an rclone configuration via base64 encoding to avoid typing errors
# and stores it in a project-specific location to avoid interfering with global rclone config

# --- Load Environment Variables ---
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Source .env file if it exists, but preserve existing environment variables
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from: $ENV_FILE"
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
            echo "Preserving existing environment variable: $key (Docker override detected)"
        fi
    done < "$ENV_FILE"
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

# First validate base64 format with verbose debugging
log INFO "DEBUG: Starting base64 validation..."
log INFO "DEBUG: Base64 string length: ${#RCLONE_CONFIG_BASE64}"
if [[ ${#RCLONE_CONFIG_BASE64} -lt 10 ]]; then
    log ERROR "RCLONE_CONFIG_BASE64 is too short to be valid base64 data."
    log ERROR "Please ensure you have provided a valid base64 encoded rclone configuration."
    exit 1
fi
# Clean base64 string (remove surrounding quotes if present)
CLEAN_RCLONE_CONFIG_BASE64="$RCLONE_CONFIG_BASE64"
log INFO "DEBUG: Original base64 starts with: ${RCLONE_CONFIG_BASE64:0:20}..."
log INFO "DEBUG: Original base64 ends with: ...${RCLONE_CONFIG_BASE64: -20}"
if [[ "$RCLONE_CONFIG_BASE64" == \"*\" ]]; then
    CLEAN_RCLONE_CONFIG_BASE64="${RCLONE_CONFIG_BASE64%\"}"
    CLEAN_RCLONE_CONFIG_BASE64="${CLEAN_RCLONE_CONFIG_BASE64#\"}"
    log INFO "DEBUG: Removed surrounding quotes from base64 string"
    log INFO "DEBUG: Cleaned length: ${#CLEAN_RCLONE_CONFIG_BASE64}"
    log INFO "DEBUG: Cleaned base64 starts with: ${CLEAN_RCLONE_CONFIG_BASE64:0:20}..."
    log INFO "DEBUG: Cleaned base64 ends with: ...${CLEAN_RCLONE_CONFIG_BASE64: -20}"
else
    log INFO "DEBUG: No quotes found to remove"
fi

# Test base64 decoding with detailed error output
log INFO "DEBUG: About to test base64 decoding..."
log INFO "DEBUG: First 50 chars of cleaned base64: ${CLEAN_RCLONE_CONFIG_BASE64:0:50}..."
log INFO "DEBUG: Last 50 chars of cleaned base64: ...${CLEAN_RCLONE_CONFIG_BASE64: -50}"

# Temporarily disable strict mode for command substitution to prevent silent exit
set +e
base64_test_output=$(echo "$CLEAN_RCLONE_CONFIG_BASE64" | base64 -d 2>&1)
base64_exit_code=$?
set -e

log INFO "DEBUG: Base64 decode exit code: $base64_exit_code"
if [ $base64_exit_code -ne 0 ]; then
    log ERROR "RCLONE_CONFIG_BASE64 contains invalid base64 data."
    log ERROR "Base64 decode error: $base64_test_output"
    log ERROR "Please check your base64 encoding. You can test with: echo 'your_base64' | base64 -d"
    log INFO "DEBUG: For comparison, try: echo '$RCLONE_CONFIG_BASE64' | base64 -d"
    log INFO "DEBUG: Original base64 string (first 100 chars): ${RCLONE_CONFIG_BASE64:0:100}..."
    log INFO "DEBUG: Cleaned base64 string (first 100 chars): ${CLEAN_RCLONE_CONFIG_BASE64:0:100}..."

    # Additional debugging - check for common issues
    if [[ "$CLEAN_RCLONE_CONFIG_BASE64" == *$'\n'* ]]; then
        log ERROR "DEBUG: Base64 string contains newlines - this can cause decoding issues"
    fi
    if [[ "$CLEAN_RCLONE_CONFIG_BASE64" == *$'\r'* ]]; then
        log ERROR "DEBUG: Base64 string contains carriage returns - this can cause decoding issues"
    fi
    if [[ "$CLEAN_RCLONE_CONFIG_BASE64" =~ [^A-Za-z0-9+/=] ]]; then
        log ERROR "DEBUG: Base64 string contains invalid characters"
    fi

    # Try to determine what base64 command we're using
    set +e
    base64_version=$(base64 --version 2>&1 || echo "version unknown")
    set -e
    log INFO "DEBUG: Base64 command version: $base64_version"

    exit 1
fi

log SUCCESS "DEBUG: Base64 validation passed successfully"

# Decode to temporary file first for validation
log INFO "DEBUG: Creating temporary file for validation..."
# Temporarily disable strict mode for mktemp to prevent silent exit
set +e
temp_config_file=$(mktemp "${PROJECT_RCLONE_CONFIG_DIR}/rclone.conf.tmp.XXXXXX")
mktemp_exit_code=$?
set -e

if [ $mktemp_exit_code -ne 0 ] || [ -z "$temp_config_file" ]; then
    log ERROR "Failed to create temporary file for rclone configuration validation."
    log ERROR "mktemp exit code: $mktemp_exit_code"
    log ERROR "Check permissions and available space in: $PROJECT_RCLONE_CONFIG_DIR"
    exit 1
fi
log INFO "DEBUG: Created temp file: $temp_config_file"

log INFO "DEBUG: Decoding base64 to temporary file..."
if ! echo "$CLEAN_RCLONE_CONFIG_BASE64" | base64 -d > "$temp_config_file" 2>&1; then
    log ERROR "Failed to decode base64 rclone configuration to temporary file."
    if [ -f "$temp_config_file" ]; then
        temp_file_size=$(stat -c%s "$temp_config_file" 2>/dev/null || stat -f%z "$temp_config_file" 2>/dev/null || echo "unknown")
        log ERROR "DEBUG: Temp file size after failed decode: $temp_file_size bytes"
        log ERROR "DEBUG: Temp file contents (first 200 chars): $(head -c 200 "$temp_config_file" 2>/dev/null || echo 'unable to read')"
    fi
    rm -f "$temp_config_file" || true
    exit 1
fi

# Verify the decoded config file exists and is not empty
if [ ! -s "$temp_config_file" ]; then
    log ERROR "Decoded rclone config is empty."
    if [ -f "$temp_config_file" ]; then
        temp_file_size=$(stat -c%s "$temp_config_file" 2>/dev/null || stat -f%z "$temp_config_file" 2>/dev/null || echo "unknown")
        log ERROR "DEBUG: Temp file size: $temp_file_size bytes"
    else
        log ERROR "DEBUG: Temp file doesn't exist"
    fi
    rm -f "$temp_config_file" || true
    exit 1
fi

log INFO "DEBUG: Decoded config file validation - checking for remote sections..."
# Basic validation of config format
if ! grep -q '^\[.*\]$' "$temp_config_file" 2>/dev/null; then
    log ERROR "Decoded config doesn't appear to be a valid rclone configuration (no remote sections found)."
    temp_file_size=$(stat -c%s "$temp_config_file" 2>/dev/null || stat -f%z "$temp_config_file" 2>/dev/null || echo "unknown")
    log ERROR "DEBUG: Temp file size: $temp_file_size bytes"
    log ERROR "DEBUG: Temp file contents (first 500 chars): $(head -c 500 "$temp_config_file" 2>/dev/null || echo 'unable to read')"
    rm -f "$temp_config_file" || true
    exit 1
fi

log SUCCESS "DEBUG: Base64 decode and validation successful!"

# Move temp file to final location
if ! mv "$temp_config_file" "$PROJECT_RCLONE_CONFIG_FILE"; then
    log ERROR "Failed to move decoded config to final location."
    rm -f "$temp_config_file" || true
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

#!/bin/bash

# Helper script to generate base64 encoded rclone configuration
# for use with Bitwarden Backup Multi-Remote Support

set -euo pipefail

# Colors for output
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;37m"
readonly COLOR_SUCCESS="\033[1;32m"
readonly COLOR_ERROR="\033[1;31m"
readonly COLOR_WARN="\033[1;33m"

log() {
    local level=$1
    shift
    local color=""
    local message="$*"

    case "$level" in
        INFO) color="$COLOR_INFO" ;;
        SUCCESS) color="$COLOR_SUCCESS" ;;
        ERROR) color="$COLOR_ERROR" ;;
        WARN) color="$COLOR_WARN" ;;
        *) color="" ;;
    esac

    printf "%b%s%b %s\n" "$color" "[$level]" "$COLOR_RESET" "$message" >&2
}

# --- Load Environment Variables ---
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Source .env file if it exists
if [ -f "$ENV_FILE" ]; then
    log INFO "Loading environment variables from: $ENV_FILE"
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    log SUCCESS "Environment variables loaded successfully."
else
    log WARN "No .env file found at: $ENV_FILE"
    log INFO "Proceeding without .env file."
fi

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [RCLONE_CONFIG_FILE]

Generate base64 encoded rclone configuration for Bitwarden Backup.

OPTIONS:
    -h, --help          Show this help message
    -i, --interactive   Interactive mode: configure remotes via rclone config
    -t, --test          Test the generated config by listing remotes
    -o, --output FILE   Output the base64 config to a file instead of stdout

ARGUMENTS:
    RCLONE_CONFIG_FILE  Path to existing rclone config file
                        (default: ~/.config/rclone/rclone.conf)

EXAMPLES:
    # Generate from existing config
    $0

    # Generate from specific config file
    $0 /path/to/custom/rclone.conf

    # Interactive mode to create new config
    $0 --interactive

    # Test the config and save to file
    $0 --test --output rclone-base64.txt

EOF
}

# Default values
RCLONE_CONFIG_FILE="$HOME/.config/rclone/rclone.conf"
INTERACTIVE_MODE=false
TEST_CONFIG=false
OUTPUT_FILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -i|--interactive)
            INTERACTIVE_MODE=true
            shift
            ;;
        -t|--test)
            TEST_CONFIG=true
            shift
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -*)
            log ERROR "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            RCLONE_CONFIG_FILE="$1"
            shift
            ;;
    esac
done

log INFO "Bitwarden Backup - Rclone Config Base64 Generator"

# Interactive mode
if [ "$INTERACTIVE_MODE" = true ]; then
    log INFO "Starting interactive rclone configuration..."

    # Create temporary config file
    TEMP_CONFIG=$(mktemp)
    trap 'rm -f "$TEMP_CONFIG"' EXIT

    log INFO "You can now configure your remotes. Type 'q' when done."
    log INFO "Common remote types: s3, drive, dropbox, onedrive, swift, etc."

    # Run rclone config with temporary file
    if ! rclone config --config "$TEMP_CONFIG"; then
        log ERROR "Rclone configuration failed."
        exit 1
    fi

    # Check if any remotes were configured
    if ! grep -q '^\[.*\]$' "$TEMP_CONFIG" 2>/dev/null; then
        log ERROR "No remotes found in configuration."
        exit 1
    fi

    RCLONE_CONFIG_FILE="$TEMP_CONFIG"
    log SUCCESS "Interactive configuration completed."
fi

# Check if config file exists
if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
    log ERROR "Rclone config file not found: $RCLONE_CONFIG_FILE"
    log INFO "Available options:"
    log INFO "  1. Use --interactive to create a new config"
    log INFO "  2. Run 'rclone config' to create config first"
    log INFO "  3. Specify a different config file path"
    exit 1
fi

log INFO "Using rclone config file: $RCLONE_CONFIG_FILE"

# Validate config file has remotes
if ! grep -q '^\[.*\]$' "$RCLONE_CONFIG_FILE" 2>/dev/null; then
    log ERROR "No remotes found in config file: $RCLONE_CONFIG_FILE"
    log INFO "Please add at least one remote using 'rclone config'"
    exit 1
fi

# List available remotes
log INFO "Found remotes in configuration:"
REMOTES=$(grep -E '^\[.*\]$' "$RCLONE_CONFIG_FILE" | sed 's/\[\(.*\)\]/\1/')
echo "$REMOTES" | while IFS= read -r remote; do
    if [ -n "$remote" ]; then
        log INFO "  - $remote"
    fi
done

REMOTE_COUNT=$(echo "$REMOTES" | wc -l)
log SUCCESS "Total remotes: $REMOTE_COUNT"

# Test configuration if requested
if [ "$TEST_CONFIG" = true ]; then
    log INFO "Testing remote accessibility..."

    ACCESSIBLE_COUNT=0
    FAILED_REMOTES=()

    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            log INFO "Testing remote: $remote"
            if rclone --config "$RCLONE_CONFIG_FILE" lsd "$remote:" >/dev/null 2>&1; then
                log SUCCESS "  ✓ $remote is accessible"
                ACCESSIBLE_COUNT=$((ACCESSIBLE_COUNT + 1))
            else
                log WARN "  ✗ $remote failed accessibility test"
                FAILED_REMOTES+=("$remote")
            fi
        fi
    done <<< "$REMOTES"

    if [ ${#FAILED_REMOTES[@]} -gt 0 ]; then
        log WARN "Some remotes failed accessibility tests:"
        for remote in "${FAILED_REMOTES[@]}"; do
            log WARN "  - $remote"
        done
    fi

    log INFO "Accessibility test completed."
fi

# Generate base64 config
log INFO "Generating base64 encoded configuration..."

if ! command -v base64 >/dev/null 2>&1; then
    log ERROR "base64 command not found. Please install it."
    exit 1
fi

BASE64_CONFIG=$(base64 -w 0 < "$RCLONE_CONFIG_FILE")

if [ -z "$BASE64_CONFIG" ]; then
    log ERROR "Failed to generate base64 configuration."
    exit 1
fi

log SUCCESS "Base64 configuration generated successfully."

# Output the result
if [ -n "$OUTPUT_FILE" ]; then
    echo "$BASE64_CONFIG" > "$OUTPUT_FILE"
    log SUCCESS "Base64 configuration saved to: $OUTPUT_FILE"
    log INFO "Add this line to your .env file:"
    log INFO "RCLONE_CONFIG_BASE64=\"$BASE64_CONFIG\""
else
    log INFO "Add this line to your .env file:"
    echo
    echo "RCLONE_CONFIG_BASE64=\"$BASE64_CONFIG\""
    echo
fi

log SUCCESS "Configuration ready for Bitwarden Backup!"
log INFO "Your backups will automatically be sent to all $REMOTE_COUNT configured remotes."

# Show next steps
cat << EOF

NEXT STEPS:
1. Copy the RCLONE_CONFIG_BASE64 line above to your .env file
2. Ensure your other .env variables are set (BW_CLIENTID, BW_CLIENTSECRET, etc.)
3. Run the backup: ./setup-rclone.sh && ./scripts/backup.sh
4. Or use Docker: docker-compose up --build

Your backups will be automatically uploaded to ALL configured remotes!
EOF

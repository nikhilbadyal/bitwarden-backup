#!/bin/bash
set -euo pipefail

# Bitwarden Backup Restoration Script
# This script can decrypt and decompress encrypted backup files back to plain JSON format

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

        # Only set the variable if it's not already set (preserves existing env vars)
        if [ -z "${!key:-}" ]; then
            export "$key=$value"
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

# --- Configuration ---
readonly BACKUP_DIR="${BACKUP_DIR:-/tmp/bw_backup}"
readonly PROJECT_RCLONE_CONFIG_FILE="${PROJECT_RCLONE_CONFIG_FILE:-${BACKUP_DIR}/rclone/rclone.conf}"
readonly BACKUP_PATH="${BACKUP_PATH:-bitwarden-backup}"
readonly PBKDF2_ITERATIONS="${PBKDF2_ITERATIONS:-600000}"

# --- Usage Function ---
print_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [BACKUP_FILE]

Restore and decrypt Bitwarden backup files to plain JSON format.
Supports both personal-only and consolidated (personal + organizations) formats.

OPTIONS:
    -h, --help              Show this help message
    -o, --output FILE       Output file path (default: ./restored_backup_TIMESTAMP.json)
    -r, --remote REMOTE     Download latest backup from specified remote
    --specific-file FILE    Download and decrypt a specific file from a remote (requires -r)
    -l, --list              List available backup files from all configured remotes
    --list-remote REMOTE    List available backup files from specific remote
    -f, --file FILE         Decrypt local backup file
    --download-only         Download backup file without decrypting
    --personal              Extract only personal vault (for consolidated backups)
    --org ORG_ID            Extract specific organization vault (for consolidated backups)

ARGUMENTS:
    BACKUP_FILE            Local encrypted backup file to decrypt (same as -f)

EXAMPLES:
    # Decrypt local backup file
    $0 bw_backup_20241218123456.json.gz.enc

    # Decrypt local file and specify output
    $0 -f backup.enc -o restored_vault.json

    # Extract only personal vault from consolidated backup
    $0 -f backup.enc --personal -o personal_vault.json

    # Extract specific organization vault
    $0 -f backup.enc --org 12345678-1234-1234-1234-123456789012 -o org_vault.json

    # Download and decrypt latest backup from S3 remote
    $0 -r s3-remote

    # List all available backups from all remotes
    $0 -l

    # List backups from specific remote
    $0 --list-remote gdrive-remote

    # Just download latest backup without decrypting
    $0 -r s3-remote --download-only

REQUIREMENTS:
    - ENCRYPTION_PASSWORD must be set (in .env or environment)
    - For remote operations: RCLONE_CONFIG_BASE64 or rclone config setup
    - openssl, gzip, jq commands available

NOTES:
    - Standard backups contain only personal vault data (default)
    - Consolidated backups contain personal + organization data
    - Without --personal or --org flags, full backup is restored as-is
    - Use --personal to get Bitwarden CLI compatible format from consolidated backups

EOF
}

# --- Default values ---
OUTPUT_FILE=""
REMOTE_NAME=""
LIST_ALL=false
LIST_REMOTE=""
BACKUP_FILE=""
DOWNLOAD_ONLY=false
EXTRACT_PERSONAL=false
EXTRACT_ORG=""
SPECIFIC_FILE=""

# --- Parse command line arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -r|--remote)
            REMOTE_NAME="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ALL=true
            shift
            ;;
        --list-remote)
            LIST_REMOTE="$2"
            shift 2
            ;;
        -f|--file)
            BACKUP_FILE="$2"
            shift 2
            ;;
        --download-only)
            DOWNLOAD_ONLY=true
            shift
            ;;
        --personal)
            EXTRACT_PERSONAL=true
            shift
            ;;
        --org)
            EXTRACT_ORG="$2"
            shift 2
            ;;
        --specific-file)
            SPECIFIC_FILE="$2"
            shift 2
            ;;
        -*)
            log ERROR "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            if [ -z "$BACKUP_FILE" ]; then
                BACKUP_FILE="$1"
            else
                log ERROR "Multiple backup files specified"
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# --- Helper Functions ---

# Check dependencies
check_dependencies() {
    local deps=("openssl" "gzip" "jq")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log ERROR "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# Get available remotes from rclone config
get_available_remotes() {
    if [ ! -f "$PROJECT_RCLONE_CONFIG_FILE" ]; then
        # Try to setup rclone config if it doesn't exist
        if [ -n "${RCLONE_CONFIG_BASE64:-}" ]; then
            log INFO "Rclone config not found, setting up from RCLONE_CONFIG_BASE64..."
            if command -v ./setup-rclone.sh >/dev/null 2>&1; then
                ./setup-rclone.sh >/dev/null 2>&1 || {
                    log ERROR "Failed to setup rclone configuration"
                    return 1
                }
            else
                log ERROR "setup-rclone.sh not found and no rclone config available"
                return 1
            fi
        else
            log ERROR "No rclone configuration found and RCLONE_CONFIG_BASE64 not set"
            return 1
        fi
    fi

    # Extract remote names from the config file
    grep -E '^\[.*\]$' "$PROJECT_RCLONE_CONFIG_FILE" | sed 's/\[\(.*\)\]/\1/' | grep -v '^$' || true
}

# List backup files from a remote
list_remote_backups() {
    local remote="$1"
    if [ -z "$remote" ]; then
        return 1
    fi

    log INFO "Listing backup files from remote: $remote"

    if ! rclone --config "$PROJECT_RCLONE_CONFIG_FILE" lsjson "$remote:$BACKUP_PATH/" 2>/dev/null | \
         jq -r '.[] | select(.Name | endswith(".enc")) | "\(.Name) (\(.Size) bytes) \(.ModTime)"' | \
         sort -r; then
        log WARN "No backup files found or failed to list files from remote: $remote"
        return 1
    fi
}

# Download a specific backup file from a remote
download_specific_backup() {
    local remote="$1"
    local filename="$2"

    if [ -z "$remote" ] || [ -z "$filename" ]; then
        log ERROR "Remote and filename are required for specific download"
        return 1
    fi

    log INFO "Downloading specific backup: $filename from remote: $remote"

    # Create temporary directory for download
    mkdir -p "$BACKUP_DIR"
    local downloaded_file="$BACKUP_DIR/$filename"

    if rclone --config "$PROJECT_RCLONE_CONFIG_FILE" copy "$remote:$BACKUP_PATH/$filename" "$BACKUP_DIR/"; then
        log SUCCESS "Downloaded backup: $downloaded_file"
        echo "$downloaded_file"
        return 0
    else
        log ERROR "Failed to download backup from remote: $remote"
        return 1
    fi
}

# Download latest backup from remote
download_latest_backup() {
    local remote="$1"
    if [ -z "$remote" ]; then
        log ERROR "No remote specified"
        return 1
    fi

    log INFO "Finding latest backup from remote: $remote"

    local latest_backup
    latest_backup=$(rclone --config "$PROJECT_RCLONE_CONFIG_FILE" lsjson "$remote:$BACKUP_PATH/" 2>/dev/null | \
                   jq -r '.[] | select(.Name | endswith(".enc")) | .Name' | \
                   sort -r | head -n1)

    if [ -z "$latest_backup" ]; then
        log ERROR "No backup files found on remote: $remote"
        return 1
    fi

    log INFO "Latest backup found: $latest_backup"

    # Create temporary directory for download
    mkdir -p "$BACKUP_DIR"
    local downloaded_file="$BACKUP_DIR/$latest_backup"

    if rclone --config "$PROJECT_RCLONE_CONFIG_FILE" copy "$remote:$BACKUP_PATH/$latest_backup" "$BACKUP_DIR/"; then
        log SUCCESS "Downloaded backup: $downloaded_file"
        echo "$downloaded_file"
        return 0
    else
        log ERROR "Failed to download backup from remote: $remote"
        return 1
    fi
}

# Extract personal vault data from either format
extract_personal_vault() {
    local backup_file="$1"
    local output_file="$2"

    if jq -e '.personal' "$backup_file" >/dev/null 2>&1; then
        # New consolidated format - extract personal vault
        log INFO "Extracting personal vault from consolidated format..."
        if ! jq '.personal' "$backup_file" > "$output_file"; then
            log ERROR "Failed to extract personal vault from consolidated backup"
            return 1
        fi
    else
        # Standard format - file is already in personal vault format
        log INFO "Backup is already in personal vault format..."
        if ! cp "$backup_file" "$output_file"; then
            log ERROR "Failed to copy standard format backup"
            return 1
        fi
    fi

    # Validate the extracted personal vault
    if ! jq -e '.items' "$output_file" >/dev/null 2>&1; then
        log ERROR "Extracted data does not contain valid personal vault structure"
        return 1
    fi

    log SUCCESS "Personal vault data extracted successfully"
    return 0
}

# Extract organization vault data from consolidated format
extract_organization_vault() {
    local backup_file="$1"
    local org_id="$2"
    local output_file="$3"

    if ! jq -e '.organizations' "$backup_file" >/dev/null 2>&1; then
        log ERROR "Backup does not contain organization data"
        return 1
    fi

    if ! jq -e --arg org_id "$org_id" '.organizations[$org_id]' "$backup_file" >/dev/null 2>&1; then
        log ERROR "Organization $org_id not found in backup"
        return 1
    fi

    log INFO "Extracting organization vault: $org_id"
    if ! jq --arg org_id "$org_id" '.organizations[$org_id]' "$backup_file" > "$output_file"; then
        log ERROR "Failed to extract organization $org_id from backup"
        return 1
    fi

    log SUCCESS "Organization vault $org_id extracted successfully"
    return 0
}

# Decrypt and decompress backup file
restore_backup() {
    local encrypted_file="$1"
    local output_file="$2"

    if [ ! -f "$encrypted_file" ]; then
        log ERROR "Backup file not found: $encrypted_file"
        return 1
    fi

    if [ -z "${ENCRYPTION_PASSWORD:-}" ]; then
        log ERROR "ENCRYPTION_PASSWORD not set. Cannot decrypt backup."
        log ERROR "Set it in your .env file or environment variables."
        return 1
    fi

    log INFO "Decrypting backup file: $encrypted_file"

    # Create temporary files for intermediate steps
    local temp_compressed
    temp_compressed=$(mktemp "${BACKUP_DIR:-/tmp}/restore_compressed.XXXXXX.gz")
    local temp_json
    temp_json=$(mktemp "${BACKUP_DIR:-/tmp}/restore_json.XXXXXX.json")

    # Set secure permissions on temp files
    chmod 600 "$temp_compressed" "$temp_json"

    # Cleanup function for temp files
    cleanup_temp_files() {
        rm -f "$temp_compressed" "$temp_json" 2>/dev/null || true
    }
    trap cleanup_temp_files EXIT

    # Step 1: Decrypt the backup with auto-detection of iteration count
    # Try current setting first, then legacy hardcoded value
    local iteration_counts=("$PBKDF2_ITERATIONS" "100000")
    local decryption_successful=false

    for iter_count in "${iteration_counts[@]}"; do
        log DEBUG "Attempting decryption with $iter_count PBKDF2 iterations..."
        if openssl enc -aes-256-cbc -d -pbkdf2 -iter "$iter_count" \
           -salt -in "$encrypted_file" -pass env:ENCRYPTION_PASSWORD -out "$temp_compressed" 2>/dev/null; then
            log INFO "Successfully decrypted backup using $iter_count PBKDF2 iterations."
            decryption_successful=true
            break
        fi
    done

    if [ "$decryption_successful" = false ]; then
        log ERROR "Failed to decrypt backup file with any known iteration count."
        log ERROR "Tried iteration counts: ${iteration_counts[*]}"
        log ERROR "Check your ENCRYPTION_PASSWORD or backup file integrity."
        return 1
    fi
    log SUCCESS "Backup decrypted successfully"

    # Step 2: Verify it's valid gzip
    if ! gzip -t "$temp_compressed" >/dev/null 2>&1; then
        log ERROR "Decrypted file is not valid gzip compressed data"
        return 1
    fi
    log SUCCESS "Compressed data validated"

    # Step 3: Decompress
    if ! gzip -dc "$temp_compressed" > "$temp_json"; then
        log ERROR "Failed to decompress backup data"
        return 1
    fi
    log SUCCESS "Backup decompressed successfully"

    # Step 4: Validate JSON
    if ! jq empty "$temp_json" >/dev/null 2>&1; then
        log ERROR "Decompressed data is not valid JSON"
        return 1
    fi
    log SUCCESS "JSON data validated"

    # Step 5: Move to final output location
    if ! mv "$temp_json" "$output_file"; then
        log ERROR "Failed to save restored backup to: $output_file"
        return 1
    fi

    # Set secure permissions on output file
    chmod 600 "$output_file"

    local file_size
    if file_size=$(stat -c%s "$output_file" 2>/dev/null) || file_size=$(stat -f%z "$output_file" 2>/dev/null); then
        log SUCCESS "Backup successfully restored to: $output_file ($file_size bytes)"
    else
        log SUCCESS "Backup successfully restored to: $output_file"
    fi

    # Show some basic info about the restored vault
    # Detect format and show appropriate information
    local item_count
    if jq -e '.personal' "$output_file" >/dev/null 2>&1; then
        # New consolidated format
        log INFO "Detected consolidated backup format"
        if jq -e '.personal' "$output_file" >/dev/null 2>&1; then
            local personal_items
            if personal_items=$(jq '.personal.items | length' "$output_file" 2>/dev/null); then
                log INFO "Personal vault contains $personal_items items"
            fi
        fi
        if jq -e '.organizations | keys | length > 0' "$output_file" >/dev/null 2>&1; then
            local org_count
            org_count=$(jq '.organizations | keys | length' "$output_file" 2>/dev/null)
            log INFO "Backup contains $org_count organization vault(s)"
            # Show items per organization
            jq -r '.organizations | to_entries[] | "\(.key): \(.value.items | length) items"' "$output_file" 2>/dev/null | while read -r org_info; do
                log INFO "  Organization $org_info"
            done
        fi
    elif item_count=$(jq '.items | length' "$output_file" 2>/dev/null); then
        # Standard format
        log INFO "Detected standard backup format"
        log INFO "Vault contains $item_count items"
    else
        log WARN "Could not determine backup format or item count"
    fi

    # Clean up temp files explicitly
    cleanup_temp_files
    trap - EXIT

    return 0
}

# --- Main Logic ---

log INFO "Starting Bitwarden backup restoration..."

# Check dependencies
check_dependencies

# Handle listing operations
if [ "$LIST_ALL" = true ]; then
    log INFO "Listing all available backups from configured remotes..."
    available_remotes=$(get_available_remotes)
    if [ -z "$available_remotes" ]; then
        log ERROR "No remotes found in configuration"
        exit 1
    fi

    while IFS= read -r remote; do
        if [ -n "$remote" ]; then
            echo
            log INFO "=== Remote: $remote ==="
            list_remote_backups "$remote" || log WARN "Failed to list backups from $remote"
        fi
    done <<< "$available_remotes"
    exit 0
fi

if [ -n "$LIST_REMOTE" ]; then
    list_remote_backups "$LIST_REMOTE"
    exit 0
fi

# Determine input file
INPUT_FILE=""
CLEANUP_INPUT=false

if [ -n "$REMOTE_NAME" ]; then
    # Download from remote
    if [ -n "$SPECIFIC_FILE" ]; then
        if ! INPUT_FILE=$(download_specific_backup "$REMOTE_NAME" "$SPECIFIC_FILE"); then
            log ERROR "Failed to download specific backup from remote: $REMOTE_NAME"
            exit 1
        fi
    else
        if ! INPUT_FILE=$(download_latest_backup "$REMOTE_NAME"); then
            log ERROR "Failed to download latest backup from remote: $REMOTE_NAME"
            exit 1
        fi
    fi
    CLEANUP_INPUT=true
elif [ -n "$BACKUP_FILE" ]; then
    # Use local file
    INPUT_FILE="$BACKUP_FILE"
else
    log ERROR "No input specified. Use -f for local file or -r for remote download."
    print_usage
    exit 1
fi

# Handle download-only mode
if [ "$DOWNLOAD_ONLY" = true ]; then
    if [ "$CLEANUP_INPUT" = true ]; then
        # Move downloaded file to current directory with a better name
        final_name="downloaded_$(basename "$INPUT_FILE")"
        if mv "$INPUT_FILE" "./$final_name"; then
            log SUCCESS "Backup downloaded to: ./$final_name"
        else
            log SUCCESS "Backup downloaded to: $INPUT_FILE"
        fi
    else
        log INFO "File already local: $INPUT_FILE"
    fi
    exit 0
fi

# Determine output file
if [ -z "$OUTPUT_FILE" ]; then
    TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
    if [ "$EXTRACT_PERSONAL" = true ]; then
        OUTPUT_FILE="./personal_vault_${TIMESTAMP}.json"
    elif [ -n "$EXTRACT_ORG" ]; then
        OUTPUT_FILE="./org_${EXTRACT_ORG}_${TIMESTAMP}.json"
    else
        OUTPUT_FILE="./restored_backup_${TIMESTAMP}.json"
    fi
fi

# Perform restoration
temp_restored_file=""
if [ "$EXTRACT_PERSONAL" = true ] || [ -n "$EXTRACT_ORG" ]; then
    # For extractions, first restore to temp file, then extract
    temp_restored_file=$(mktemp "${BACKUP_DIR:-/tmp}/temp_restore.XXXXXX.json")
    chmod 600 "$temp_restored_file"

    if restore_backup "$INPUT_FILE" "$temp_restored_file"; then
        if [ "$EXTRACT_PERSONAL" = true ]; then
            if extract_personal_vault "$temp_restored_file" "$OUTPUT_FILE"; then
                log SUCCESS "Personal vault extraction completed successfully!"
                log INFO "Personal vault saved to: $OUTPUT_FILE"
                log INFO "This file is compatible with Bitwarden CLI import."
            else
                log ERROR "Personal vault extraction failed"
                rm -f "$temp_restored_file"
                exit 1
            fi
        elif [ -n "$EXTRACT_ORG" ]; then
            if extract_organization_vault "$temp_restored_file" "$EXTRACT_ORG" "$OUTPUT_FILE"; then
                log SUCCESS "Organization vault extraction completed successfully!"
                log INFO "Organization vault saved to: $OUTPUT_FILE"
                log INFO "This file is compatible with Bitwarden CLI import."
            else
                log ERROR "Organization vault extraction failed"
                rm -f "$temp_restored_file"
                exit 1
            fi
        fi
        rm -f "$temp_restored_file"
    else
        log ERROR "Initial restoration failed"
        rm -f "$temp_restored_file"
        exit 1
    fi
else
    # Normal full restoration
    if restore_backup "$INPUT_FILE" "$OUTPUT_FILE"; then
        log SUCCESS "Restoration completed successfully!"
        log INFO "You can now import this JSON file back into Bitwarden if needed."
        log INFO "Keep this file secure and delete it when no longer needed."
    else
        log ERROR "Restoration failed"
        exit 1
    fi
fi

# Cleanup downloaded file if it was temporary
if [ "$CLEANUP_INPUT" = true ] && [ -f "$INPUT_FILE" ]; then
    rm -f "$INPUT_FILE"
    log INFO "Cleaned up temporary downloaded file"
fi

log SUCCESS "Restoration process completed!"

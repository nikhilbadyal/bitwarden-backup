#!/bin/bash
set -e

# --- Environment Variable Validation ---
# Check required environment variables directly from the environment.
# When using docker run --env-file, variables are injected into the environment,
# so checking for the .env file on the filesystem is not reliable.
REQUIRED_VARS=(
    "RCLONE_R2_REMOTE_NAME"
    "RCLONE_R2_BUCKET_NAME"
    "RCLONE_R2_ENDPOINT"
    "RCLONE_R2_ACCESS_KEY_ID"
    "RCLONE_R2_SECRET_ACCESS_KEY"
)

echo "Checking for required environment variables..."
for var in "${REQUIRED_VARS[@]}"; do
    # Check if the variable is set AND not empty
    # ${!var:-} expands to the value of the variable, or an empty string if unset or null.
    # This check works whether the variables came from a .env file loaded manually
    # or were injected directly into the environment (e.g., by Docker).
    if [ -z "${!var:-}" ]; then
        echo "❌ Environment variable '$var' is missing or empty. Please ensure it is set."
        exit 1
    fi
done
echo "✅ All required environment variables are set."

# --- Rclone Configuration Setup ---

# Set paths for the rclone config file.
# $HOME will resolve correctly inside the container or on the host.
RCLONE_CONFIG_DIR="$HOME/.config/rclone"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"

echo "Configuring rclone..."

# Create config directory if it doesn't exist.
# Use -p flag to avoid error if directory already exists.
mkdir -p "$RCLONE_CONFIG_DIR" || { echo "❌ Failed to create rclone config directory: $RCLONE_CONFIG_DIR"; exit 1; }
echo "✅ Rclone config directory ensured: $RCLONE_CONFIG_DIR"

# Write the rclone config file using the environment variables.
# The variables are guaranteed to be set due to the check above.
cat > "$RCLONE_CONFIG_FILE" <<EOF
[$RCLONE_R2_REMOTE_NAME]
type = s3
provider = Cloudflare
access_key_id = $RCLONE_R2_ACCESS_KEY_ID
secret_access_key = $RCLONE_R2_SECRET_ACCESS_KEY
endpoint = ${RCLONE_R2_ENDPOINT}
region = auto
EOF

echo "✅ Rclone config created successfully at: $RCLONE_CONFIG_FILE"

# Optional: Set secure permissions on the config file (owner read/write only)
chmod 600 "$RCLONE_CONFIG_FILE" || echo "⚠️ Could not set secure permissions (600) on rclone config file."

echo "Setup complete."

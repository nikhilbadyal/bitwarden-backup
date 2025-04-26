#!/bin/bash
set -e

# Load environment variables from .env file
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "❌ .env file not found."
    exit 1
fi

# Check required environment variables
REQUIRED_VARS=("RCLONE_R2_REMOTE_NAME" "RCLONE_R2_BUCKET_NAME" "RCLONE_R2_ENDPOINT" "RCLONE_R2_ACCESS_KEY_ID" "RCLONE_R2_SECRET_ACCESS_KEY")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Environment variable '$var' is missing."
        exit 1
    fi
done

# Set paths
RCLONE_CONFIG_DIR="$HOME/.config/rclone"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"

# Create config directory if needed
mkdir -p "$RCLONE_CONFIG_DIR"

# Write the rclone config file
cat > "$RCLONE_CONFIG_FILE" <<EOF
[$RCLONE_R2_REMOTE_NAME]
type = s3
provider = Cloudflare
access_key_id = $RCLONE_R2_ACCESS_KEY_ID
secret_access_key = $RCLONE_R2_SECRET_ACCESS_KEY
endpoint = ${RCLONE_R2_ENDPOINT}
region = auto
EOF

echo "✅ Rclone config created at: $RCLONE_CONFIG_FILE"

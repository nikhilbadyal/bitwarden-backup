FROM debian:bookworm-slim

# Install all dependencies in a single RUN layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        jq \
        nodejs \
        npm \
        python3 \
        python3-pip \
        rclone \
        unzip \
        wget && \
    # Install Apprise using pip (with --break-system-packages for Debian 12)
    pip3 install apprise --break-system-packages && \
    # Install Bitwarden CLI via npm with explicit version pinning for reproducibility
    npm cache clean --force && \
    npm install -g @bitwarden/cli@2026.3.0 && \
    # Clean up apt cache and temporary files
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.npm && \
    # Create non-root user for security \
    groupadd -r backupuser && \
    useradd -r -g backupuser -s /bin/bash backupuser && \
    # Set up Bitwarden CLI config directory \
    mkdir -p /home/backupuser/.config/Bitwarden\ CLI && \
    chown -R backupuser:backupuser /home/backupuser/.config

WORKDIR /app
COPY . .

# Make scripts executable and set ownership
RUN chmod +x setup-rclone.sh scripts/backup.sh && \
    chown -R backupuser:backupuser /app

# Switch to non-root user
USER backupuser

# Health check: ensure all required commands exist
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD command -v bw >/dev/null && command -v rclone >/dev/null && command -v jq >/dev/null || exit 1

# Entrypoint: run setup and backup
ENTRYPOINT ["bash", "-c", "./setup-rclone.sh && ./scripts/backup.sh"]

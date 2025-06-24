FROM debian:bookworm-slim

# Install all dependencies in a single RUN layer
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        python3 \
        python3-pip \
        unzip \
        build-essential \
        wget && \
    # Install Node.js LTS (auto-detects arch, supports ARM/x86)
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    # Install Apprise using pip (with --break-system-packages for Debian 12)
    pip3 install apprise --break-system-packages && \
    # Install Bitwarden CLI via npm (works on all architectures)
    npm cache clean --force && \
    npm install -g semver && \
    npm install -g @bitwarden/cli && \
    # Install rclone (auto-detect architecture)
    curl https://rclone.org/install.sh | bash && \
    # Clean up apt cache and temporary files
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.npm

# Create non-root user for security
RUN groupadd -r backupuser && useradd -r -g backupuser -s /bin/bash backupuser

# Set up Bitwarden CLI config directory
RUN mkdir -p /home/backupuser/.config/Bitwarden\ CLI && \
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

FROM debian:bullseye-slim

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
        wget && \
    # Install Apprise using pip
    pip3 install apprise && \
    # Install Bitwarden CLI
    wget --quiet -O /tmp/bitwarden-cli.zip "https://vault.bitwarden.com/download/?app=cli&platform=linux" && \
    unzip /tmp/bitwarden-cli.zip -d /usr/local/bin/ && \
    rm -f /tmp/bitwarden-cli.zip && \
    chmod +x /usr/local/bin/bw && \
    # Install rclone (auto-detect architecture)
    curl https://rclone.org/install.sh | bash && \
    # Clean up apt cache and temporary files
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create non-root user for security
RUN groupadd -r backupuser && useradd -r -g backupuser -s /bin/bash backupuser

# Set up Bitwarden CLI configuration directory
RUN mkdir -p /home/backupuser/.config/Bitwarden\ CLI && \
    chown -R backupuser:backupuser /home/backupuser/.config

WORKDIR /app
COPY . .

# Make scripts executable and set ownership
RUN chmod +x setup-rclone.sh scripts/backup.sh && \
    chown -R backupuser:backupuser /app

# Switch to non-root user
USER backupuser

# Add health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD command -v bw >/dev/null && command -v rclone >/dev/null && command -v jq >/dev/null || exit 1

# Entrypoint: run setup and backup
ENTRYPOINT ["bash", "-c", "./setup-rclone.sh && ./scripts/backup.sh"]

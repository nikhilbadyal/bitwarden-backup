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

# Set up Bitwarden CLI configuration directory (often /root/.config/Bitwarden CLI)
# This is where the bw CLI might store config or session files, good practice to create it.
RUN mkdir -p /root/.config/Bitwarden\ CLI

WORKDIR /app
COPY . .

# Make scripts executable
RUN chmod +x setup-rclone.sh scripts/backup.sh

# Entrypoint: run setup and backup
ENTRYPOINT ["bash", "-c", "./setup-rclone.sh && ./scripts/backup.sh"]

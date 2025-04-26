# Use the latest Alpine image as the base
FROM alpine:latest

# Install necessary packages
RUN apk add --no-cache \
    bash \
    curl \
    openssl \
    rclone \
    nodejs \
    npm \
    git \
    ca-certificates \
    tzdata

# Install Bitwarden CLI
RUN npm install -g @bitwarden/cli

# Set the working directory
WORKDIR /app

# Copy the backup script into the container
COPY scripts/backup.sh /app/backup.sh

# Make the script executable
RUN chmod +x /app/backup.sh

# Set the entrypoint to the backup script
ENTRYPOINT ["/app/backup.sh"]

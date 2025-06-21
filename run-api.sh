#!/bin/bash

# Script to run the Bitwarden Backup API in Docker

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Starting Bitwarden Backup API...${NC}"

# Check if .env file exists
if [ ! -f ".env" ]; then
    echo -e "${RED}❌ Error: .env file not found!${NC}"
    echo -e "${YELLOW}Please create a .env file in the root directory with your configuration.${NC}"
    echo -e "${YELLOW}You can use env.example as a template.${NC}"
    echo -e "${YELLOW}Required variables for API: API_TOKEN, REDIS_URL, BW_CLIENTID, BW_CLIENTSECRET, BW_PASSWORD, ENCRYPTION_PASSWORD, RCLONE_CONFIG_BASE64${NC}"
    exit 1
fi

# Check if required API variables are set in .env
echo -e "${YELLOW}🔍 Checking required API configuration...${NC}"
missing_vars=()
required_vars=("API_TOKEN" "BW_CLIENTID" "BW_CLIENTSECRET" "BW_PASSWORD" "ENCRYPTION_PASSWORD" "RCLONE_CONFIG_BASE64")

for var in "${required_vars[@]}"; do
    if ! grep -q "^${var}=" .env; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo -e "${RED}❌ Error: Missing required variables in .env file:${NC}"
    for var in "${missing_vars[@]}"; do
        echo -e "${RED}  - $var${NC}"
    done
    echo -e "${YELLOW}Please add these variables to your .env file.${NC}"
    echo -e "${YELLOW}You can use env.example as a template.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Required configuration found${NC}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}❌ Error: Docker is not running!${NC}"
    echo -e "${YELLOW}Please start Docker and try again.${NC}"
    exit 1
fi

# Build and run the API service
echo -e "${GREEN}🔨 Building API container...${NC}"
docker-compose -f docker-compose.api.yml build --no-cache

echo -e "${GREEN}🚀 Starting API service...${NC}"
docker-compose -f docker-compose.api.yml up -d

echo -e "${GREEN}✅ API is starting up...${NC}"
echo -e "${GREEN}📡 API will be available at: http://localhost:5050${NC}"
echo -e "${GREEN}📚 API documentation will be available at: http://localhost:5050/api/v1/docs${NC}"

# Wait for the service to be healthy
echo -e "${YELLOW}⏳ Waiting for API to be ready...${NC}"
for i in {1..30}; do
    if curl -f http://localhost:5050/ > /dev/null 2>&1; then
        echo -e "${GREEN}✅ API is ready!${NC}"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo -e "${RED}❌ API failed to start within 30 seconds${NC}"
        echo -e "${YELLOW}Check logs with: docker-compose -f docker-compose.api.yml logs${NC}"
        exit 1
    fi
    sleep 1
done

echo -e "${GREEN}🎉 Bitwarden Backup API is now running!${NC}"
echo -e "${GREEN}Use 'docker-compose -f docker-compose.api.yml logs -f' to view logs${NC}"
echo -e "${GREEN}Use 'docker-compose -f docker-compose.api.yml down' to stop the service${NC}"

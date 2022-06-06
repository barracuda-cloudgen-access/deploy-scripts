#!/usr/bin/env bash
#
# Copyright (c) 2020-present, Barracuda Networks Inc.
#

# Set error handling

set -euo pipefail

# Functions

function log_entry() {
    local LOG_TYPE="${1:?Needs log type}"
    local LOG_MSG="${2:?Needs log message}"
    local COLOR='\033[93m'
    local ENDCOLOR='\033[0m'

    echo -e "${COLOR}$(date "+%Y-%m-%d %H:%M:%S") [$LOG_TYPE] ${LOG_MSG}${ENDCOLOR}"
}

function is_linux {
    if [[ "$(uname)" == "Linux" ]]; then
        return 0
    fi
    return 1
}

function is_macos {
    if [[ "$(uname)" == "Darwin" ]]; then
        return 0
    fi
    return 1
}

# Set download links

URL_DOCKER_LINUX="https://get.docker.com"
URL_DOCKER_MACOS="https://docs.docker.com/docker-for-mac/install/"
URL_DOCKER_INFO="https://docs.docker.com/install/overview/"
URL_COMPOSE_LINUX="https://github.com/docker/compose/releases/download/v2.5.0/docker-compose-linux-"
URL_COMPOSE_INFO="https://docs.docker.com/compose/install/"
URL_MANIFEST_BASE="https://raw.githubusercontent.com/barracuda-cloudgen-access/deploy-scripts/main/cga-proxy/docker/docker-compose.yml"
URL_MANIFEST_TEST="https://raw.githubusercontent.com/barracuda-cloudgen-access/deploy-scripts/main/cga-proxy/docker/docker-compose-httptest.yml"

# Check for minimum bash version

if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    log_entry "ERROR" "Bash version must be at least 4"
    exit 1
fi

# Check if run as root

if [[ "${EUID}" != "0" ]]; then
    log_entry "ERROR" "This script needs to be run as root"
    exit 1
fi

# Request information

log_entry "INFO" "Please provide required variables"

read -r -p "Specify CloudGen Access Proxy public port (443): " PUBLIC_PORT
PUBLIC_PORT=${PUBLIC_PORT:-"443"}

read -r -p "Install test resource (N/y): " INSTALL_TEST
INSTALL_TEST=${INSTALL_TEST:-"N"}

while [[ -z "${PROXY_TOKEN:-}" ]]; do
    read -r -p "Paste the CloudGen Access Proxy enrollment token: " PROXY_TOKEN
    echo ""
    if [[ -z "${PROXY_TOKEN:-}" ]]; then
        log_entry "ERROR" "CloudGen Access Proxy enrollment link cannot be empty"
    elif ! [[ "${PROXY_TOKEN:-}" =~ ^http[s]?://[^/]+/proxies/v[0-9]+/enrollment/[0-9a-f-]+\?proxy_auth_token=[^\&]+\&tenant_id=[0-9a-f-]+$ ]]; then
        log_entry "ERROR" "CloudGen Access Proxy enrollment token is invalid, please try again"
        unset PROXY_TOKEN
    fi
done

# Get docker install script and execute (linux only)

log_entry "INFO" "Checking docker"

if docker version &>/dev/null; then
    log_entry "INFO" "Docker detected"
else
    log_entry "WARNING" "Docker not detected"

    if is_linux; then
        log_entry "INFO" "Installing docker"
        curl -fsSL "${URL_DOCKER_LINUX}" -o get-docker.sh
        sh get-docker.sh

        log_entry "INFO" "Enable docker service on boot"
        systemctl enable docker

        log_entry "INFO" "Starting docker"
        systemctl start docker
    elif is_macos; then
        log_entry "ERROR" "Could not detect docker in MacOS"
        log_entry "ERROR" "Please install manually and re-run script"
        log_entry "ERROR" "More info: ${URL_DOCKER_MACOS}"
        exit 1
    else
        log_entry "ERROR" "Could not detect system type"
        log_entry "ERROR" "Please install docker manually and re-run script"
        log_entry "ERROR" "More info: ${URL_DOCKER_INFO}"
        exit 1
    fi
fi

# Instal docker compose

log_entry "INFO" "Checking docker compose"

if docker compose version &>/dev/null; then
    log_entry "INFO" "Docker compose detected"
else
    if is_linux; then
        log_entry "INFO" "Installing docker compose"
        DOCKER_CONFIG=${DOCKER_CONFIG:-"/usr/local/lib/docker/cli-plugins"}
        mkdir -p "${DOCKER_CONFIG}"
        curl -fsSL "${URL_COMPOSE_LINUX}$(uname -m)" -o "${DOCKER_CONFIG}/docker-compose"
        chmod +x "${DOCKER_CONFIG}/docker-compose"
        docker compose version
    elif is_macos; then
        log_entry "ERROR" "Could not detect docker compose in MacOS"
        log_entry "ERROR" "Please install manually and re-run script"
        log_entry "ERROR" "More info: $URL_COMPOSE_INFO"
        exit 1
    else
        log_entry "ERROR" "Could not detect system type"
        log_entry "ERROR" "Please install docker compose manually and re-run script"
        log_entry "ERROR" "More info: $URL_COMPOSE_INFO"
        exit 1
    fi
fi

# Get docker compose manifest and replace values

log_entry "INFO" "Downloading docker compose manifest(s)"
if [[ "${INSTALL_TEST,,}" =~ ^(y|yes)$ ]]; then
    log_entry "INFO" "Including test resource"
    COMPOSE_FILES=(-f docker-compose.yml -f docker-compose-httptest.yml)
    curl -fsSL "${URL_MANIFEST_BASE}" -o docker-compose.yml
    curl -fsSL "${URL_MANIFEST_TEST}" -o docker-compose-httptest.yml
else
    log_entry "INFO" "Skipping test resource"
    COMPOSE_FILES=(-f docker-compose.yml)
    curl -fsSL "${URL_MANIFEST_BASE}" -o docker-compose.yml
fi

log_entry "INFO" "Replacing variables"
sed -i -E "s|443:8000|${PUBLIC_PORT}:8000|" docker-compose.yml
if [[ "$(sed --version 2>/dev/null)" =~ ^.*GNU.*$ ]]; then
    SED_FIND='(<paste\ here\ your\ CloudGen\ Access\ Proxy\ enrollment\ link>)'
else
    SED_FIND='\(<paste\ here\ your\ CloudGen\ Access\ Proxy\ enrollment\ link>\)'
fi
sed -i -E "s|${SED_FIND}|${PROXY_TOKEN/\&/\\&}|g" docker-compose.yml

# Start containers

log_entry "INFO" "Starting containers"
docker compose "${COMPOSE_FILES[@]}" up -d

log_entry "WARNING" "Manifest(s) saved in this folder"
log_entry "INFO" "To check container logs please run:"
echo "sudo docker compose ${COMPOSE_FILES[*]} logs -f"

log_entry "INFO" "Complete."

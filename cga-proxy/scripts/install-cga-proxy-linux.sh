#!/usr/bin/env bash
#
# Copyright (c) 2020-present, Barracuda Networks Inc.
#

# Set error handling

set -euo pipefail

# Set help

function program_help {

    echo -e "Install CloudGen Access Proxy script

Available parameters:
  -e \\t\\t- Extra orchestrator environment variables (can be used multiple times)
  -h \\t\\t- Show this help
  -l string \\t- Loglevel (debug, info, warning, error, critical), defaults to info.
  -n \\t\\t- Don't start services after install
  -p int \\t- Specify public port (1-65535), required for unattended instalation
  -r string \\t- Specify Redis host to use for token cache <only required for HA architecture>
  -s int \\t- Specify Redis port <optional>
  -t token \\t- Specify CloudGen Access Proxy token
  -u \\t\\t- Unattended install, skip requesting input <optional>
  -z \\t\\t- Skip configuring ntp server <optional>

Example for unattended instalation with CloudGen Access Proxy token:
  - Specify the CloudGen Access Proxy token inside quotes

  ${0} -p 443 -t \"https://xxxxxxxxxxxx\" -u

Example for unattended instalation with CloudGen Access Proxy token with Redis endpoint:
  - Specify the CloudGen Access Proxy token inside quotes

  ${0} -p 443 -t \"https://xxxxxxxxxxxx\" -u -r localhost -s 6379

Example for unattended instalation, skipping services start, without CloudGen Access Proxy token:
  - The token can also be obtained automatically via AWS SSM/Secrets Manager
  - More info: https://campus.barracuda.com/product/cloudgenaccess/doc/93201605/access-proxy-parameters/

  ${0} -n -p 443 -u
"
    exit 0

}

function validate_proxy_token() {
    if [[ "${1}" =~ ^https:\/\/[a-zA-Z0-9.-]+\.(fyde\.com|access\.barracuda\.com)\/proxies/v[0-9]+\/enrollment\/[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\?proxy_auth_token=[0-9a-zA-Z]+\&tenant_id=[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
        return 0
    fi
    return 1
}

# Get parameters
EXTRA=()
REPO_URL="downloads.access.barracuda.com"

while getopts ":e:hl:np:r:s:t:uz" OPTION 2>/dev/null; do
    case "${OPTION}" in
    e)
        VALUE="$(echo "${OPTARG}" | cut -d= -f1 | tr '[:lower:]-' '[:upper:]_')"
        if ! [[ "${VALUE}" =~ ^FYDE_ ]] && ! [[ "${VALUE}" =~ ^DISABLE_ ]]; then
            VALUE="FYDE_${VALUE}"
        fi
        EXTRA+=("${VALUE}=$(echo "${OPTARG}" | cut -d= -f2-)")
        ;;
    h)
        program_help
        ;;
    l)
        LOGLEVEL="${OPTARG}"
        ;;
    n)
        NO_START_SVC="true"
        ;;
    p)
        PUBLIC_PORT="${OPTARG}"
        ;;
    r)
        REDIS_HOST="${OPTARG}"
        ;;
    s)
        REDIS_PORT="${OPTARG}"
        ;;
    t)
        PROXY_TOKEN="${OPTARG}"
        if ! validate_proxy_token "${PROXY_TOKEN:-}"; then
            echo "CloudGen Access Proxy enrollment token is invalid, please try again"
            exit 3
        fi
        ;;
    u)
        UNATTENDED_INSTALL="true"
        ;;
    z)
        SKIP_NTP="true"
        ;;
    \?)
        echo "Invalid option: -${OPTARG}"
        exit 3
        ;;
    :)
        echo "Option -${OPTARG} requires an argument." >&2
        exit 3
        ;;
    *)
        echo "${OPTARG} is an unrecognized option"
        exit 3
        ;;
    esac
done

# Functions

function log_entry() {

    local LOG_TYPE="${1:?Needs log type}"
    local LOG_MSG="${2:?Needs log message}"
    local COLOR='\033[93m'
    local ENDCOLOR='\033[0m'

    echo -e "${COLOR}$(date "+%Y-%m-%d %H:%M:%S") [$LOG_TYPE] ${LOG_MSG}${ENDCOLOR}"

}

# Check if run as root

if [[ "$EUID" != "0" ]]; then
    log_entry "ERROR" "This script needs to be run as root"
    exit 1
fi

# Prepare inputs

if [[ "${UNATTENDED_INSTALL:-}" == "true" ]] || ! [[ -t 0 ]]; then
    if [[ -z "${PUBLIC_PORT:-}" ]]; then
        log_entry "ERROR" "Unattended install requires public port (-h for more info)"
        exit 1
    fi
else
    log_entry "INFO" "Please provide required variables"

    read -r -p "Specify CloudGen Access Proxy public port (443): " PUBLIC_PORT
    PUBLIC_PORT=${PUBLIC_PORT:-"443"}

    while [[ -z "${PROXY_TOKEN:-}" ]]; do
        read -r -p "Paste the CloudGen Access Proxy enrollment token: " PROXY_TOKEN
        echo ""
        if [[ -z "${PROXY_TOKEN:-}" ]]; then
            log_entry "ERROR" "CloudGen Access Proxy enrollment link cannot be empty"
        elif ! validate_proxy_token "${PROXY_TOKEN:-}"; then
            log_entry "ERROR" "CloudGen Access Proxy enrollment token is invalid, please try again"
            unset PROXY_TOKEN
        fi
    done

    read -r -p "Specify Redis host (only required for HA architecture): " REDIS_HOST
    if [ -n "${REDIS_HOST:-}" ]; then
        read -r -p "Specify Redis port (6379): " REDIS_PORT
        REDIS_PORT=${REDIS_PORT:-"6379"}
    fi

    if [[ -z "${EXTRA:-}" ]]; then
        read -r -p "Extra orchestrator environment variables (KEY=VALUE) (Enter an empty line to continue): " KV

        while [[ -n "${KV:-}" ]]; do
            VALUE="$(echo "${KV}" | cut -d= -f1 | tr '[:lower:]-' '[:upper:]_')"
            if ! [[ "${VALUE}" =~ ^FYDE_ ]] && ! [[ "${VALUE}" =~ ^DISABLE_ ]]; then
                VALUE="FYDE_${VALUE}"
            fi
            EXTRA+=("${VALUE}=$(echo "${KV}" | cut -d= -f2-)")
            read -r -p "Extra orchestrator environment variables (KEY=VALUE) (Enter an empty line to continue): " KV
        done
    fi
fi

# Pre-requisites

# shellcheck disable=SC1091
source /etc/os-release

log_entry "INFO" "Check for package manager lock file"
for i in $(seq 1 300); do
    if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
        if ! fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; then
            break
        fi
    elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
        if ! [ -f /var/run/yum.pid ]; then
            break
        fi
    else
        echo "Unrecognized distribution type: ${ID_LIKE}"
        exit 4
    fi
    echo "Lock found. Check ${i}/300"
    sleep 1
done

log_entry "INFO" "Install pre-requisites"
if [[ "${ID_LIKE:-}" =~ rhel ]]; then
    yum -y install yum-utils
fi

if [[ "${SKIP_NTP:-}" == "true" ]]; then
    log_entry "INFO" "Skipping NTP configuration"
else
    if [[ "${ID_LIKE:-}" =~ rhel ]]; then
        log_entry "INFO" "Ensure chrony daemon is enabled on system boot and started"
        yum -y install chrony
        systemctl enable chronyd
        systemctl start chronyd
    fi

    log_entry "INFO" "Ensure time synchronization is enabled"
    timedatectl set-ntp off
    timedatectl set-ntp on
fi

log_entry "INFO" "Add CloudGen repository"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    wget -q -O - "https://${REPO_URL}/fyde-public-key.asc" | apt-key add -
    cat >/etc/apt/sources.list.d/fyde.list <<EOF
deb https://${REPO_URL}/apt stable main
EOF
    sudo apt update
elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
    # Quick hack for "Error: GPG check FAILED"
    # The signature will be updated for next releases
    export OPENSSL_ENABLE_SHA1_SIGNATURES=1
    yum-config-manager -y --add-repo "https://${REPO_URL}/fyde.repo"
fi

# Set Journald configuration
echo "RateLimitBurst=10000" >>/etc/systemd/journald.conf
systemctl restart systemd-journald.service

# CloudGen Envoy Proxy

log_entry "INFO" "Install Envoy Proxy"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    apt -y install envoy
elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
    yum -y install envoy
fi
systemctl enable envoy

if [ "${PUBLIC_PORT}" -lt 1024 ]; then
    log_entry "INFO" "Configure Envoy Proxy"
    mkdir -p /etc/systemd/system/envoy.service.d
    cat >/etc/systemd/system/envoy.service.d/10-add-cap-net-bind.conf <<EOF
[Service]
Capabilities=CAP_NET_BIND_SERVICE+ep
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
SecureBits=keep-caps
EOF
    chmod 600 /etc/systemd/system/envoy.service.d/10-add-cap-net-bind.conf

    systemctl --system daemon-reload
fi

if [[ "${NO_START_SVC:-}" == true ]]; then
    log_entry "INFO" "Skip Envoy Proxy daemon start"
else
    log_entry "INFO" "Ensure Envoy Proxy daemon is running with latest config"
    systemctl restart envoy
fi

# CloudGen Proxy Orchestrator

log_entry "INFO" "Install CloudGen Proxy Orchestrator"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    apt -y install fydeproxy
elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
    yum -y install fydeproxy
fi
systemctl enable fydeproxy

log_entry "INFO" "Configure CloudGen Proxy Orchestrator"

UNIT_OVERRIDE=("[Service]" "Environment='FYDE_ENVOY_LISTENER_PORT=${PUBLIC_PORT}'")
UNIT_OVERRIDE+=("Environment='FYDE_LOGLEVEL=${LOGLEVEL:-"info"}'")

if [[ -n "${PROXY_TOKEN:-}" ]]; then
    UNIT_OVERRIDE+=("Environment='FYDE_ENROLLMENT_TOKEN=${PROXY_TOKEN}'")
fi

if [[ -n "${REDIS_HOST:-}" ]]; then
    UNIT_OVERRIDE+=("Environment='FYDE_REDIS_HOST=${REDIS_HOST}'")
    if [[ -n "${REDIS_PORT:-}" ]]; then
        UNIT_OVERRIDE+=("Environment='FYDE_REDIS_PORT=${REDIS_PORT}'")
    fi
fi

mkdir -p /etc/systemd/system/fydeproxy.service.d
printf "%s\n" "${UNIT_OVERRIDE[@]}" >/etc/systemd/system/fydeproxy.service.d/10-environment.conf

if [[ "${#EXTRA[@]}" -gt 0 ]]; then
    printf "Environment='%s'\n" "${EXTRA[@]}" >>/etc/systemd/system/fydeproxy.service.d/10-environment.conf
fi
chmod 600 /etc/systemd/system/fydeproxy.service.d/10-environment.conf

log_entry "INFO" "Configure the firewall"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    if systemctl status ufw &>/dev/null; then
        ufw allow "${PUBLIC_PORT}/tcp"
        ufw reload
    else
        log_entry "WARNING" "UFW not started, skipping configuration"
    fi
elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
    if systemctl status firewalld &>/dev/null; then
        firewall-cmd --zone=public --add-port="${PUBLIC_PORT}/tcp" --permanent
        firewall-cmd --reload
    else
        log_entry "WARNING" "Firewalld not started, skipping configuration"
    fi
fi

systemctl --system daemon-reload

if [[ "${NO_START_SVC:-}" == "true" ]]; then
    log_entry "INFO" "Skip CloudGen Proxy Orchestrator start"
    log_entry "INFO" "Start services:"
    echo "systemctl start envoy"
    echo "systemctl start fydeproxy"
else
    log_entry "INFO" "Ensure CloudGen Proxy Orchestrator daemon is running with latest config"
    systemctl restart fydeproxy
fi

log_entry "INFO" "Check logs:"
echo "journalctl -u envoy -f"
echo "journalctl -u fydeproxy -f"

log_entry "INFO" "Complete."

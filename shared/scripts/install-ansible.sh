#!/usr/bin/env bash
#
# Copyright (c) 2021-present, Barracuda Networks Inc.
# All rights reserved.
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

# Check root

if [[ "${EUID}" != "0" ]]; then
    log_entry "ERROR" "This script needs to be run as root"
    echo -e "whoami\t: $(whoami)"
    echo -e "id\t: $(id)"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

log_entry "INFO" "Check for package manager lock file"
for i in $(seq 1 300); do
    if [[ "${ID_LIKE:-}${ID:-}" =~ debian ]]; then
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

log_entry "INFO" "Install ansible"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y install ca-certificates software-properties-common gnupg2
    # shellcheck disable=SC2034
    if [[ "${ID}" =~ debian ]]; then
        DEBIAN_11="focal"
        DEBIAN_10="bionic"
        DEBIAN_9="xenial"
        CODENAME="${ID^^}_${VERSION_ID}"
        echo "deb http://ppa.launchpad.net/ansible/ansible/ubuntu ${!CODENAME} main" | \
            tee /etc/apt/sources.list.d/ansible.list
        apt-key adv --no-tty \
            --keyserver keyserver.ubuntu.com \
            --recv-keys 93C4A3FD7BB9C367
    else
        apt-add-repository --yes --update ppa:ansible/ansible
    fi
    apt-get update
    apt-get -y install ansible
elif [[ "${ID}" =~ amzn ]]; then
    amazon-linux-extras install epel -y
    yum install -y ca-certificates ansible
else
    COMMAND=(yum)
    if command -v dnf &> /dev/null; then
        COMMAND=(dnf)
    fi
    "${COMMAND[@]}" install -y yum-utils epel-release ca-certificates
    "${COMMAND[@]}" install -y ansible
fi

log_entry "INFO" "Configure ansible"
mkdir -pv /etc/ansible
tee /etc/ansible/ansible.cfg <<EOF
[defaults]
force_color = 1
stdout_callback = yaml
EOF

log_entry "INFO" "Ansible info"
ansible --version

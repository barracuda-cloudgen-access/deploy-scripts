#!/usr/bin/env bash
#
# Copyright (c) 2021-present, Barracuda Networks Inc.
# All rights reserved.
#

# Set error handling

set -euo pipefail

# Set help

function program_help {

    echo -e "Harden Linux script

Available parameters:
  -h \\t\\t- Show this help
  -p \\t\\t- Allow password-based authentication with the ssh server (true/false) (Default: true)
  -r \\t\\t- Allow ssh login as root (no/without-password/yes) (Default: no)
  -s \\t\\t- Maximum number of ssh authentication attempts permitted per connection (Default: 2)
  -u \\t\\t- Unattended install, skip requesting input (optional)
"
    exit 0

}

# Variables
ANSIBLE_OPTIONS=("--connection=local" "--become")
SSH_MAX_AUTH_RETRIES="2"
SSH_PERMIT_ROOT_LOGIN="no"
SSH_SERVER_PASSWORD_LOGIN="true"

# Functions
function log_entry() {
    local LOG_TYPE="${1:?Needs log type}"
    local LOG_MSG="${2:?Needs log message}"
    local COLOR='\033[93m'
    local ENDCOLOR='\033[0m'

    echo -e "${COLOR}$(date "+%Y-%m-%d %H:%M:%S") [$LOG_TYPE] ${LOG_MSG}${ENDCOLOR}"
}

# Check for root
if [[ "${EUID}" != "0" ]]; then
    log_entry "ERROR" "This script needs to be run as root"
    echo -e "whoami\t: $(whoami)"
    echo -e "id\t: $(id)"
    exit 1
fi

# Get parameters
while getopts ":hp:ur:s:" OPTION 2>/dev/null; do
    case "${OPTION}" in
        h)
            program_help
        ;;
        p)
            SSH_SERVER_PASSWORD_LOGIN="${OPTARG}"
        ;;
        r)
            SSH_PERMIT_ROOT_LOGIN="${OPTARG}"
        ;;
        s)
            SSH_MAX_AUTH_RETRIES="${OPTARG}"
        ;;
        u)
            UNATTENDED_INSTALL="true"
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

# Always clear tmp dir
TMP_DIR="$(mktemp -d)"
function clear_tmp() {
    local CLEAR_PATH="${1:?"Needs path to remove"}"
    local COUNT

    log_entry "INFO" "Clearing temporary folder(s)"
    COUNT="$(rm -rfv "${CLEAR_PATH}" | wc -l)"
    log_entry "INFO" "Removed ${COUNT} items"
}
trap 'clear_tmp ${TMP_DIR:?}' EXIT

# Prepare inputs
if [[ "${UNATTENDED_INSTALL:-}" != "true" ]] && [[ -t 0 ]]; then
    log_entry "INFO" "Please provide required variables"

    BOLD=$(tput bold)
    NORMAL=$(tput sgr0)

    read -r -p "Allow password-based authentication with the ssh server (${BOLD}true${NORMAL}/false): " READ_SSH_SERVER_PASSWORD_LOGIN
    SSH_SERVER_PASSWORD_LOGIN="${READ_SSH_SERVER_PASSWORD_LOGIN:-"${SSH_SERVER_PASSWORD_LOGIN}"}"
    read -r -p "Allow ssh login as root (${BOLD}no${NORMAL}/without-password/yes): " READ_SSH_PERMIT_ROOT_LOGIN
    SSH_PERMIT_ROOT_LOGIN="${READ_SSH_PERMIT_ROOT_LOGIN:-"${SSH_PERMIT_ROOT_LOGIN}"}"
    read -r -p "Maximum number of ssh authentication attempts permitted per connection (${BOLD}2${NORMAL}): " READ_SSH_MAX_AUTH_RETRIES
    SSH_MAX_AUTH_RETRIES="${READ_SSH_MAX_AUTH_RETRIES:-"${SSH_MAX_AUTH_RETRIES}"}"
fi

# shellcheck disable=SC1091
source /etc/os-release

# Install ansible
curl -fsSLo "${TMP_DIR}/install-ansible.sh" https://url.fyde.me/ansible
chmod +x "${TMP_DIR}/install-ansible.sh"
"${TMP_DIR}/install-ansible.sh"

# unattended-upgrades/yum-cron
log_entry "INFO" "Configure automatic updates"

if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    apt-get update
    apt-get install -y \
        ca-certificates \
        unattended-upgrades \
        software-properties-common \
        python3-pip
    ANSIBLE_OPTIONS+=("-e" "ansible_python_interpreter=/usr/bin/python3")
elif [[ "${ID:-}" == "amzn" ]]; then
    amazon-linux-extras install epel -y
    yum install -y yum-cron
    UPDATE_FILE="/etc/yum/yum-cron.conf"
    UPDATE_SVC="yum-cron"
else
    COMMAND=(yum)
    if command -v dnf &> /dev/null; then
        COMMAND=(dnf)
    fi
    "${COMMAND[@]}" install -y yum-utils epel-release
    "${COMMAND[@]}" install -y dnf-automatic
    rpm --import /etc/pki/rpm-gpg/*GPG*
    UPDATE_FILE="/etc/dnf/automatic.conf"
    UPDATE_SVC="dnf-automatic.timer"
fi

if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    tee "/etc/apt/apt.conf.d/20auto-upgrades" <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    tee -a "/etc/apt/apt.conf.d/50unattended-upgrades" <<EOF
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Origins-Pattern {
        "site=downloads.fyde.com,component=main";
};
EOF
else
    tee "${UPDATE_FILE}" <<EOF
[commands]
update_cmd = security
update_messages = yes
download_updates = yes
apply_updates = yes
random_sleep = 360
[emitters]
system_name = None
emit_via = stdio
output_width = 80
[email]
email_from = root@localhost
[base]
debuglevel = -2
mdpolicy = group:main
exclude = kernel*
EOF
    systemctl enable --now "${UPDATE_SVC}"
fi

# Ansible
log_entry "INFO" "Run Ansible playbooks"
ansible-galaxy collection install devsec.hardening
tee "${TMP_DIR}"/playbook.yml <<EOF
---
- hosts: localhost
  collections:
    - devsec.hardening
  roles:
    - ssh_hardening
    - os_hardening
  vars:
    ssh_max_auth_retries: "${SSH_MAX_AUTH_RETRIES}"
    ssh_permit_root_login: "${SSH_PERMIT_ROOT_LOGIN}"
    ssh_server_password_login: ${SSH_SERVER_PASSWORD_LOGIN}
    sshd_authenticationmethods: "publickey password"
EOF

ansible-playbook -i "localhost," \
    --connection=local --become \
    "${ANSIBLE_OPTIONS[@]}" \
    "${TMP_DIR}"/playbook.yml

log_entry "INFO" "Please REBOOT your instance before continuing"

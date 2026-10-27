#!/usr/bin/env bash

set -Eeuo pipefail
trap 'printf "Error: command failed at line %s\n" "$LINENO" >&2' ERR

readonly NVM_VERSION="v0.40.3"
readonly DOCKER_PRUNE_AGE="168h"
APT_UPDATED=false
NVM_INSTALLED=false
DOCKER_INSTALLED=false
WEB_SERVER="none"

confirm() {
  local prompt="$1"
  local reply

  while true; do
    read -r -p "${prompt} [y/N]: " reply
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) printf 'Please answer yes or no.\n' ;;
    esac
  done
}

apt_update_once() {
  if [[ "${APT_UPDATED}" == false ]]; then
    printf 'Refreshing the package index...\n'
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update
    APT_UPDATED=true
  fi
}

install_packages() {
  apt_update_once
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

if [[ "${EUID}" -eq 0 ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
  else
    printf 'Run this script as the login user, not directly as root.\n' >&2
    printf 'Example: ./ubuntu-server-init.sh\n' >&2
    exit 1
  fi
else
  TARGET_USER="${USER}"
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
if [[ -z "${TARGET_HOME}" || ! -d "${TARGET_HOME}" ]]; then
  printf 'Could not determine the home directory for %s.\n' "${TARGET_USER}" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf 'sudo is required.\n' >&2
  exit 1
fi

printf 'Ubuntu server initialization\n'
printf 'Target user: %s\n\n' "${TARGET_USER}"
sudo -v

if confirm 'Update the package index and upgrade installed packages?'; then
  apt_update_once
  sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi

if confirm 'Install btop and micro?'; then
  printf 'Installing btop and micro...\n'
  install_packages btop micro
fi

if confirm 'Configure swap memory?'; then
  SWAP_DIRECTORY="/swap"
  SWAP_FILE="${SWAP_DIRECTORY}/swapfile"

  if sudo swapon --show=NAME --noheadings | grep -Fxq "${SWAP_FILE}"; then
    printf 'Swap file %s is already active. It will not be recreated.\n' "${SWAP_FILE}"
  else
    while true; do
      read -r -p 'Enter the swap size in whole GB, for example 2 or 4: ' SWAP_SIZE_GB
      if [[ "${SWAP_SIZE_GB}" =~ ^[1-9][0-9]*$ ]]; then
        break
      fi
      printf 'Enter a positive whole number of GB.\n'
    done

    if [[ -e "${SWAP_FILE}" ]]; then
      if [[ ! -f "${SWAP_FILE}" ]]; then
        printf '%s exists but is not a regular file. Swap creation cannot continue.\n' \
          "${SWAP_FILE}" >&2
        exit 1
      fi

      if confirm "${SWAP_FILE} already exists but is not active. Replace it?"; then
        sudo rm -f "${SWAP_FILE}"
      else
        printf 'Swap configuration skipped.\n'
        SWAP_SIZE_GB=""
      fi
    fi

    if [[ -n "${SWAP_SIZE_GB}" ]]; then
      SWAP_SIZE_BYTES=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
      AVAILABLE_BYTES="$(df --output=avail -B1 / | tail -n 1 | tr -d '[:space:]')"

      if (( SWAP_SIZE_BYTES > AVAILABLE_BYTES )); then
        printf 'Not enough free disk space. Requested %s GB, available approximately %s GB.\n' \
          "${SWAP_SIZE_GB}" "$((AVAILABLE_BYTES / 1024 / 1024 / 1024))" >&2
        exit 1
      fi

      printf 'Creating a %s GB swap file at %s...\n' "${SWAP_SIZE_GB}" "${SWAP_FILE}"
      sudo install -d -m 0700 "${SWAP_DIRECTORY}"

      if ! sudo fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}"; then
        printf 'fallocate is unavailable for this filesystem. Using dd instead...\n'
        sudo dd if=/dev/zero of="${SWAP_FILE}" bs=1M \
          count="$((SWAP_SIZE_GB * 1024))" status=progress
      fi

      sudo chmod 0600 "${SWAP_FILE}"
      sudo mkswap "${SWAP_FILE}"
      sudo swapon "${SWAP_FILE}"
    fi
  fi

  if sudo swapon --show=NAME --noheadings | grep -Fxq "${SWAP_FILE}"; then
    if ! sudo grep -Eq '^[[:space:]]*/swap/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+sw([[:space:]]|$)' /etc/fstab; then
      printf '%s\n' '/swap/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    fi

    printf '\nActive swap:\n'
    sudo swapon --show
    printf '\nMemory summary:\n'
    free -h
  fi
fi

if confirm "Install NVM ${NVM_VERSION} for ${TARGET_USER}?"; then
  printf 'Installing NVM %s for %s...\n' "${NVM_VERSION}" "${TARGET_USER}"
  install_packages curl ca-certificates
  sudo -u "${TARGET_USER}" -H env PROFILE="${TARGET_HOME}/.bashrc" bash -o pipefail -c \
    "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
  NVM_INSTALLED=true
fi

if confirm 'Install Docker Engine?'; then
  printf 'Installing Docker Engine...\n'
  install_packages curl ca-certificates

  DOCKER_INSTALLER="$(mktemp)"
  trap 'rm -f "${DOCKER_INSTALLER}"' EXIT
  curl -fsSL https://get.docker.com -o "${DOCKER_INSTALLER}"
  sudo sh "${DOCKER_INSTALLER}"
  rm -f "${DOCKER_INSTALLER}"
  trap - EXIT

  sudo usermod -aG docker "${TARGET_USER}"

  printf 'Configuring Docker log rotation...\n'
  sudo install -d -m 0755 /etc/docker
  if [[ -e /etc/docker/daemon.json ]]; then
    sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.backup.$(date +%Y%m%d%H%M%S)"
  fi
  sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "10"
  }
}
JSON

  sudo systemctl enable --now docker.service containerd.service
  sudo systemctl restart docker.service
  DOCKER_INSTALLED=true

  if confirm 'Configure weekly Docker cleanup for resources older than seven days?'; then
    printf 'Configuring weekly Docker cleanup...\n'
    install_packages cron
    sudo tee /etc/cron.d/docker-prune >/dev/null <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 3 * * 0 root /usr/bin/docker system prune -af --filter "until=${DOCKER_PRUNE_AGE}" >> /var/log/docker-prune.log 2>&1
EOF
    sudo chmod 0644 /etc/cron.d/docker-prune
    sudo systemctl enable --now cron.service
  fi
fi

printf '\nSelect a web server:\n'
printf '  1) Nginx with the Certbot Nginx plugin\n'
printf '  2) Apache with the Certbot Apache plugin\n'
printf '  3) Do not install a web server\n'
while true; do
  read -r -p 'Enter your choice [1, 2, or 3]: ' web_choice
  case "${web_choice}" in
    1)
      printf 'Installing Nginx and its Certbot plugin...\n'
      install_packages nginx certbot python3-certbot-nginx
      sudo systemctl enable --now nginx.service
      WEB_SERVER="nginx"
      break
      ;;
    2)
      printf 'Installing Apache and its Certbot plugin...\n'
      install_packages apache2 certbot python3-certbot-apache
      sudo systemctl enable --now apache2.service
      WEB_SERVER="apache"
      break
      ;;
    3)
      break
      ;;
    *)
      printf 'Please enter 1, 2, or 3.\n'
      ;;
  esac
done

printf '\nInitialization completed successfully.\n'

if [[ "${DOCKER_INSTALLED}" == true ]]; then
  printf 'Log out and sign in again before using Docker without sudo.\n'
fi

if [[ "${NVM_INSTALLED}" == true ]]; then
  printf 'Load NVM now with: source "%s/.nvm/nvm.sh"\n' "${TARGET_HOME}"
fi

case "${WEB_SERVER}" in
  nginx)
    printf 'After DNS points to this server, configure TLS with: sudo certbot --nginx\n'
    ;;
  apache)
    printf 'After DNS points to this server, configure TLS with: sudo certbot --apache\n'
    ;;
esac

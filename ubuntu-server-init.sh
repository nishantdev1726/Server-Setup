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

if [[ ! -r /etc/os-release ]]; then
  printf 'Unable to identify the operating system.\n' >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  printf 'This script supports Ubuntu only. Detected: %s\n' "${PRETTY_NAME:-unknown}" >&2
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

if confirm 'Install PHP?'; then
  while true; do
    read -r -p 'Enter the PHP major and minor version, for example 8.3 or 8.4: ' PHP_VERSION
    if [[ "${PHP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
      break
    fi
    printf 'Enter a version in major.minor format, for example 8.4.\n'
  done

  INSTALL_COMMON_EXTENSIONS=false
  if confirm 'Install common PHP extensions for web applications?'; then
    INSTALL_COMMON_EXTENSIONS=true
  fi

  if [[ "${VERSION_CODENAME:-}" == "resolute" ]]; then
    PHP_REPOSITORY="packages.sury.org/php"
  else
    PHP_REPOSITORY="ppa:ondrej/php"
  fi

  printf '\nPHP installation summary:\n'
  printf '  PHP version: %s\n' "${PHP_VERSION}"
  printf '  Web server integration: %s\n' "${WEB_SERVER}"
  printf '  Common extensions: %s\n' "${INSTALL_COMMON_EXTENSIONS}"
  printf '  Package source: %s\n\n' "${PHP_REPOSITORY}"

  if confirm 'Continue with PHP installation?'; then
    printf 'Configuring the PHP package repository...\n'
    install_packages ca-certificates curl lsb-release

    if [[ "${VERSION_CODENAME:-}" == "resolute" ]]; then
      sudo rm -f \
        /etc/apt/sources.list.d/ondrej-ubuntu-php-resolute.list \
        /etc/apt/sources.list.d/ondrej-ubuntu-php-resolute.sources

      KEYRING_PACKAGE="$(mktemp --suffix=.deb)"
      trap 'rm -f "${KEYRING_PACKAGE}"' EXIT
      curl -fsSL https://packages.sury.org/debsuryorg-archive-keyring.deb \
        -o "${KEYRING_PACKAGE}"
      sudo dpkg -i "${KEYRING_PACKAGE}"
      rm -f "${KEYRING_PACKAGE}"
      trap - EXIT

      printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" \
        | sudo tee /etc/apt/sources.list.d/php.list >/dev/null
    else
      install_packages software-properties-common
      sudo add-apt-repository -y ppa:ondrej/php
    fi

    sudo env DEBIAN_FRONTEND=noninteractive apt-get update
    APT_UPDATED=true

    REQUIRED_PHP_PACKAGES=(
      "php${PHP_VERSION}-cli"
      "php${PHP_VERSION}-common"
    )

    if [[ "${WEB_SERVER}" != "none" ]]; then
      REQUIRED_PHP_PACKAGES+=("php${PHP_VERSION}-fpm")
    fi

    for package in "${REQUIRED_PHP_PACKAGES[@]}"; do
      if ! apt-cache show "${package}" >/dev/null 2>&1; then
        printf 'Required package %s is unavailable for %s. PHP was not installed.\n' \
          "${package}" "${PRETTY_NAME}" >&2
        exit 1
      fi
    done

    PHP_PACKAGES=("${REQUIRED_PHP_PACKAGES[@]}")

    if [[ "${INSTALL_COMMON_EXTENSIONS}" == true ]]; then
      OPTIONAL_PHP_PACKAGES=(
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-readline"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-zip"
      )

      if dpkg --compare-versions "${PHP_VERSION}" lt "8.5"; then
        OPTIONAL_PHP_PACKAGES+=("php${PHP_VERSION}-opcache")
      else
        printf 'PHP %s includes OPcache. No separate package is required.\n' \
          "${PHP_VERSION}"
      fi

      for package in "${OPTIONAL_PHP_PACKAGES[@]}"; do
        if apt-cache show "${package}" >/dev/null 2>&1; then
          PHP_PACKAGES+=("${package}")
        else
          printf 'Warning: optional package %s is unavailable and will be skipped.\n' \
            "${package}" >&2
        fi
      done
    fi

    printf 'Installing PHP %s packages...\n' "${PHP_VERSION}"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PHP_PACKAGES[@]}"

    if [[ -x "/usr/bin/php${PHP_VERSION}" ]]; then
      sudo update-alternatives --set php "/usr/bin/php${PHP_VERSION}"
    fi

    if [[ "${WEB_SERVER}" == "nginx" ]]; then
      sudo systemctl enable --now "php${PHP_VERSION}-fpm.service"
      sudo systemctl restart "php${PHP_VERSION}-fpm.service"
      printf 'PHP FPM socket for Nginx: /run/php/php%s-fpm.sock\n' "${PHP_VERSION}"
      printf 'Configure the Nginx server block to pass PHP requests to this socket.\n'
    elif [[ "${WEB_SERVER}" == "apache" ]]; then
      sudo a2enmod proxy_fcgi setenvif
      sudo a2enconf "php${PHP_VERSION}-fpm"
      sudo systemctl enable --now "php${PHP_VERSION}-fpm.service"
      sudo systemctl restart "php${PHP_VERSION}-fpm.service"
      sudo apache2ctl configtest
      sudo systemctl restart apache2.service
      printf 'Apache is configured to use PHP %s through PHP FPM.\n' "${PHP_VERSION}"
    else
      printf 'No web server was selected. PHP CLI was installed without PHP FPM.\n'
    fi

    printf 'Selected PHP CLI version: '
    php --version | head -n 1
  else
    printf 'PHP installation skipped.\n'
  fi
fi

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

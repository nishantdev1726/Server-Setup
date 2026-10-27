#!/usr/bin/env bash

set -Eeuo pipefail
trap 'printf "Error: command failed at line %s\n" "$LINENO" >&2' ERR

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

if [[ "${EUID}" -eq 0 ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
  else
    printf 'Run this script as the login user, not directly as root.\n' >&2
    printf 'Example: ./install-php.sh\n' >&2
    exit 1
  fi
else
  TARGET_USER="${USER}"
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

if [[ "${VERSION_CODENAME:-}" == "resolute" ]]; then
  PHP_REPOSITORY="packages.sury.org/php"
else
  PHP_REPOSITORY="ppa:ondrej/php"
fi

printf 'PHP installation for Ubuntu\n'
printf 'Detected system: %s\n\n' "${PRETTY_NAME}"

while true; do
  read -r -p 'Enter the PHP major and minor version to install, for example 8.3 or 8.4: ' PHP_VERSION
  if [[ "${PHP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    break
  fi
  printf 'Enter a version in major.minor format, for example 8.4.\n'
done

printf '\nSelect the installation profile:\n'
printf '  1) PHP CLI only\n'
printf '  2) PHP CLI and PHP FPM for Nginx\n'
printf '  3) PHP CLI and PHP FPM for Apache\n'
while true; do
  read -r -p 'Enter your choice [1, 2, or 3]: ' PROFILE_CHOICE
  case "${PROFILE_CHOICE}" in
    1)
      INSTALL_PROFILE="cli"
      break
      ;;
    2)
      INSTALL_PROFILE="nginx"
      break
      ;;
    3)
      INSTALL_PROFILE="apache"
      break
      ;;
    *)
      printf 'Please enter 1, 2, or 3.\n'
      ;;
  esac
done

INSTALL_COMMON_EXTENSIONS=false
if confirm 'Install common PHP extensions for web applications?'; then
  INSTALL_COMMON_EXTENSIONS=true
fi

printf '\nInstallation summary:\n'
printf '  PHP version: %s\n' "${PHP_VERSION}"
printf '  Profile: %s\n' "${INSTALL_PROFILE}"
printf '  Common extensions: %s\n' "${INSTALL_COMMON_EXTENSIONS}"
printf '  Package source: %s\n\n' "${PHP_REPOSITORY}"

if ! confirm 'Continue with this installation?'; then
  printf 'Installation cancelled.\n'
  exit 0
fi

sudo -v

printf 'Installing repository prerequisites...\n'

if [[ "${VERSION_CODENAME:-}" == "resolute" ]]; then
  # A previous failed run may have left an unsupported Resolute PPA source.
  sudo rm -f \
    /etc/apt/sources.list.d/ondrej-ubuntu-php-resolute.list \
    /etc/apt/sources.list.d/ondrej-ubuntu-php-resolute.sources
fi

sudo env DEBIAN_FRONTEND=noninteractive apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl lsb-release

if [[ "${VERSION_CODENAME:-}" == "resolute" ]]; then
  printf 'Adding the Sury PHP package repository for Ubuntu 26.04...\n'
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
  printf 'Adding the Ondrej PHP PPA...\n'
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
  sudo add-apt-repository -y ppa:ondrej/php
fi

sudo env DEBIAN_FRONTEND=noninteractive apt-get update

PHP_CLI_PACKAGE="php${PHP_VERSION}-cli"
if ! apt-cache show "${PHP_CLI_PACKAGE}" >/dev/null 2>&1; then
  printf 'PHP %s is not available for %s from the configured repository.\n' \
    "${PHP_VERSION}" "${PRETTY_NAME}" >&2
  printf 'No PHP packages were installed.\n' >&2
  exit 1
fi

REQUIRED_PACKAGES=(
  "php${PHP_VERSION}-cli"
  "php${PHP_VERSION}-common"
)

if [[ "${INSTALL_PROFILE}" != "cli" ]]; then
  REQUIRED_PACKAGES+=("php${PHP_VERSION}-fpm")
fi

for package in "${REQUIRED_PACKAGES[@]}"; do
  if ! apt-cache show "${package}" >/dev/null 2>&1; then
    printf 'Required package %s is not available for %s.\n' \
      "${package}" "${PRETTY_NAME}" >&2
    printf 'No PHP packages were installed.\n' >&2
    exit 1
  fi
done

PACKAGES=("${REQUIRED_PACKAGES[@]}")

if [[ "${INSTALL_COMMON_EXTENSIONS}" == true ]]; then
  OPTIONAL_PACKAGES=(
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

  # OPcache is built into PHP 8.5 and later, so no separate package exists.
  if dpkg --compare-versions "${PHP_VERSION}" lt "8.5"; then
    OPTIONAL_PACKAGES+=("php${PHP_VERSION}-opcache")
  else
    printf 'PHP %s includes OPcache. No separate OPcache package is required.\n' \
      "${PHP_VERSION}"
  fi

  for package in "${OPTIONAL_PACKAGES[@]}"; do
    if apt-cache show "${package}" >/dev/null 2>&1; then
      PACKAGES+=("${package}")
    else
      printf 'Warning: optional package %s is unavailable and will be skipped.\n' \
        "${package}" >&2
    fi
  done
fi

if [[ "${INSTALL_PROFILE}" == "nginx" ]] && ! command -v nginx >/dev/null 2>&1; then
  printf 'Nginx is not installed. Install Nginx before selecting the Nginx profile.\n' >&2
  exit 1
fi

if [[ "${INSTALL_PROFILE}" == "apache" ]] && ! command -v apache2ctl >/dev/null 2>&1; then
  printf 'Apache is not installed. Install Apache before selecting the Apache profile.\n' >&2
  exit 1
fi

printf 'Installing PHP %s packages...\n' "${PHP_VERSION}"
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

if [[ -x "/usr/bin/php${PHP_VERSION}" ]]; then
  sudo update-alternatives --set php "/usr/bin/php${PHP_VERSION}"
fi

if [[ "${INSTALL_PROFILE}" == "nginx" ]]; then
  sudo systemctl enable --now "php${PHP_VERSION}-fpm.service"
  sudo systemctl restart "php${PHP_VERSION}-fpm.service"
fi

if [[ "${INSTALL_PROFILE}" == "apache" ]]; then
  sudo a2enmod proxy_fcgi setenvif
  sudo a2enconf "php${PHP_VERSION}-fpm"
  sudo systemctl enable --now "php${PHP_VERSION}-fpm.service"
  sudo systemctl restart "php${PHP_VERSION}-fpm.service"
  sudo apache2ctl configtest
  sudo systemctl restart apache2.service
fi

printf '\nPHP %s installation completed successfully.\n' "${PHP_VERSION}"
printf 'Selected CLI version: '
php --version | head -n 1

if [[ "${INSTALL_PROFILE}" == "nginx" ]]; then
  printf 'PHP FPM socket for Nginx: /run/php/php%s-fpm.sock\n' "${PHP_VERSION}"
  printf 'Configure your Nginx server block to pass PHP requests to this socket.\n'
fi

if [[ "${INSTALL_PROFILE}" == "apache" ]]; then
  printf 'Apache is configured to use PHP %s through PHP FPM.\n' "${PHP_VERSION}"
fi

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
  printf 'Run this script as the login user, not directly as root.\n' >&2
  printf 'Example: ./create-nginx-site.sh\n' >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf 'sudo is required.\n' >&2
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  printf 'Nginx is not installed. Install Nginx before running this script.\n' >&2
  exit 1
fi

while true; do
  read -r -p 'Enter the domain name, for example app.example.com: ' DOMAIN_NAME
  DOMAIN_NAME="${DOMAIN_NAME,,}"

  if [[ "${DOMAIN_NAME}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    break
  fi

  printf 'Enter a valid domain name without http, https, a path, or a port.\n'
done

while true; do
  read -r -p 'Enter the application port [1-65535]: ' APPLICATION_PORT

  if [[ "${APPLICATION_PORT}" =~ ^[0-9]+$ ]] \
    && ((10#${APPLICATION_PORT} >= 1 && 10#${APPLICATION_PORT} <= 65535)); then
    APPLICATION_PORT="$((10#${APPLICATION_PORT}))"
    break
  fi

  printf 'Enter a valid TCP port from 1 through 65535.\n'
done

AVAILABLE_DIRECTORY="/etc/nginx/sites-available"
ENABLED_DIRECTORY="/etc/nginx/sites-enabled"
SITE_FILE="${AVAILABLE_DIRECTORY}/${DOMAIN_NAME}"
ENABLED_LINK="${ENABLED_DIRECTORY}/${DOMAIN_NAME}"
TEMP_FILE="$(mktemp)"
BACKUP_FILE=""
LINK_CREATED=false

cleanup() {
  rm -f "${TEMP_FILE}"
}
trap cleanup EXIT

cat >"${TEMP_FILE}" <<EOF
server {
    server_name ${DOMAIN_NAME};

    client_max_body_size 100M;

    location / {
        # try_files \$uri \$uri/ =404;
        proxy_pass http://localhost:${APPLICATION_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

printf '\nConfiguration summary:\n'
printf '  Domain: %s\n' "${DOMAIN_NAME}"
printf '  Application port: %s\n' "${APPLICATION_PORT}"
printf '  Configuration file: %s\n\n' "${SITE_FILE}"

if ! confirm 'Create and enable this Nginx site?'; then
  printf 'Site creation cancelled.\n'
  exit 0
fi

sudo -v
sudo install -d -m 0755 "${AVAILABLE_DIRECTORY}" "${ENABLED_DIRECTORY}"

if sudo test -L "${ENABLED_LINK}"; then
  CURRENT_TARGET="$(sudo readlink "${ENABLED_LINK}")"
  if [[ "${CURRENT_TARGET}" != "${SITE_FILE}" ]]; then
    printf '%s already links to %s. It was not changed.\n' \
      "${ENABLED_LINK}" "${CURRENT_TARGET}" >&2
    exit 1
  fi
elif sudo test -e "${ENABLED_LINK}"; then
  printf '%s already exists and is not a symbolic link. It was not changed.\n' \
    "${ENABLED_LINK}" >&2
  exit 1
fi

if sudo test -e "${SITE_FILE}"; then
  if ! confirm "${SITE_FILE} already exists. Replace it?"; then
    printf 'Existing configuration was not changed.\n'
    exit 0
  fi

  BACKUP_FILE="${SITE_FILE}.backup.$(date +%Y%m%d%H%M%S)"
  sudo cp "${SITE_FILE}" "${BACKUP_FILE}"
  printf 'Existing configuration backed up to %s.\n' "${BACKUP_FILE}"
fi

sudo install -m 0644 "${TEMP_FILE}" "${SITE_FILE}"

if ! sudo test -L "${ENABLED_LINK}"; then
  sudo ln -s "${SITE_FILE}" "${ENABLED_LINK}"
  LINK_CREATED=true
fi

if ! sudo nginx -t; then
  printf 'Nginx validation failed. Restoring the previous state.\n' >&2

  if [[ "${LINK_CREATED}" == true ]]; then
    sudo rm -f "${ENABLED_LINK}"
  fi

  if [[ -n "${BACKUP_FILE}" ]]; then
    sudo cp "${BACKUP_FILE}" "${SITE_FILE}"
  else
    sudo rm -f "${SITE_FILE}"
  fi

  exit 1
fi

sudo nginx -s reload

printf '\nNginx site created and enabled successfully.\n'
printf 'Domain: %s\n' "${DOMAIN_NAME}"
printf 'Proxy destination: http://localhost:%s\n' "${APPLICATION_PORT}"

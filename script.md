# Ubuntu Server Setup

Run these commands from the directory containing the scripts. Use your normal login user. The scripts request `sudo` when required.

## 1. Initialize the server

```bash
chmod +x ubuntu-server-init.sh
./ubuntu-server-init.sh
```

This interactive script can update Ubuntu packages, install `btop` and `micro`, configure persistent swap, install NVM, install Docker with log rotation and optional weekly cleanup, and install Nginx or Apache with the matching Certbot plugin.

## 2. Install PHP

Run this after server initialization, especially when selecting an Nginx or Apache profile.

```bash
chmod +x install-php.sh
./install-php.sh
```

This interactive script asks for a PHP version and installation profile. It configures the appropriate PHP package repository, installs PHP CLI, optionally installs PHP FPM and common extensions, selects the requested CLI version, and configures PHP FPM for Apache when selected. For Nginx, it reports the PHP FPM socket that must be added to the Nginx server block.

## Notes

1. These scripts support Ubuntu and require `sudo` access.
2. Do not run them from a direct root login.
3. Review each interactive choice before confirming it.
4. The Docker option can schedule automatic deletion of unused resources older than seven days.
5. When Docker is installed, log out and sign in again before using Docker without `sudo`.

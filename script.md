# Ubuntu Server Setup

Run the following commands from the directory containing the script. Use your normal login user. The script requests `sudo` when required.

```bash
chmod +x ubuntu-server-init.sh
./ubuntu-server-init.sh
```

The interactive script can perform the following tasks:

1. Update Ubuntu packages.
2. Install `btop` and `micro`.
3. Configure persistent swap memory.
4. Install NVM.
5. Install Docker with log rotation and optional weekly cleanup.
6. Install Nginx or Apache with the matching Certbot plugin.
7. Optionally install a selected PHP version and common extensions.

PHP installation is controlled by an `Install PHP?` confirmation. When Nginx is selected, the script installs and starts PHP FPM and reports its socket path for the Nginx configuration. When Apache is selected, it installs PHP FPM and enables the required Apache integration. When no web server is selected, it installs PHP CLI without PHP FPM.

## Notes

1. The script supports Ubuntu and requires `sudo` access.
2. Do not run it from a direct root login.
3. Review each interactive choice before confirming it.
4. The Docker cleanup option automatically removes unused Docker resources older than seven days.
5. After Docker installation, log out and sign in again before using Docker without `sudo`.
6. The standalone `install-php.sh` file remains available, but it is no longer required for the combined setup flow.

## Create an Nginx reverse proxy site

Run this script after Nginx is installed:

```bash
chmod +x create-nginx-site.sh
./create-nginx-site.sh
```

The script asks for a domain name and application port, creates `/etc/nginx/sites-available/domain.com`, and enables it through `/etc/nginx/sites-enabled/domain.com`. It validates the generated configuration with `nginx -t` before reloading Nginx. If validation fails, it restores the previous configuration.

If a configuration already exists for the domain, the script asks before replacing it and creates a timestamped backup.

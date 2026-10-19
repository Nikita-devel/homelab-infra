# homelab-infra

Infrastructure-as-code for a single-node home server running Debian 13 and Docker Compose.
Hardware: a used 15-inch laptop, internal NVMe for the OS, external USB SSD for service data.

## Services

| Service | Purpose | Compose directory |
|---|---|---|
| Nextcloud (+ MariaDB 10.6) | File sync and photo archive | `nextcloud/` |
| Finance Tracker | Shared expense tracking (SQLite) | `finance-tracker/` |
| Pi-hole | LAN DNS ad-blocking | `pihole/` |
| Homepage | Service dashboard | `homepage/` |
| Weather | Static nginx page | `weather/` |

Remote access is provided by Tailscale. No ports are open on the router.
Selected services are published with `tailscale serve` (HTTPS, tailnet-only).

## Layout

Service data lives on the external SSD mounted at `/mnt/usb512`:

- `/mnt/usb512/nextcloud/{app,data,db}`
- `/mnt/usb512/finance-tracker/data/finance.db`
- `/mnt/usb512/pihole/`, `/mnt/usb512/homepage/config/`, `/mnt/usb512/weather/`

Data and secrets are not stored in this repository.

## Configuration

Each service has a `.env.example` with placeholder values.
Create a real `.env` next to each `docker-compose.yml` and never commit it (`.gitignore` covers `.env`).

Values that are not in this repo and must be provided at deploy time:

- Tailscale hostname and IP
- LAN address of the host
- Database and admin passwords
- Restic repository credentials and healthcheck URL (in `/root/.restic-env`, mode 600)

## Backups

`backup.sh` runs daily from a systemd timer (`restic-backup.timer`, 03:30 with randomized delay).

1. Puts Nextcloud into maintenance mode and dumps its MariaDB database.
2. Takes a consistent SQLite snapshot of Finance Tracker with `.backup`.
3. Backs up data, dumps, and selected configs to Backblaze B2 with restic.
4. Applies retention (7 daily, 4 weekly, 6 monthly) and prunes.
5. Pings a healthcheck. A missing ping means the backup did not complete.

The script refuses to run over a mobile hotspot interface and always disables maintenance mode on exit.

## Restore order (from scratch)

1. Install Debian and Docker Engine, then Tailscale.
2. Restore `/mnt/usb512` contents from restic (`restic restore latest --target /`).
3. Recreate `.env` files from the `.env.example` templates.
4. Start services with `docker compose up -d` in each service directory.
5. Verify Nextcloud with `occ status` and Finance Tracker with `PRAGMA integrity_check`.

Restore has been tested on a sample of files. Full restore has not yet been tested end to end.

## Known limitations

- The Finance Tracker application source is in a separate repository. Its compose file expects a `build:` context from that source.
- Single-node setup, no high availability.
- The external SSD connection has been unstable in the past; data is planned to move to the internal NVMe.

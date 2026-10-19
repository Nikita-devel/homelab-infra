# homelab-infra

Infrastructure-as-code for a single-node home server: Debian 13, Docker Compose, Tailscale for remote access, restic to Backblaze B2 for backups.

This repo holds the Compose files, the backup script and the systemd units. It does not hold secrets, databases or user data. A fresh install from this repo gives the same services and configuration, but not the same data. See [Restore from scratch](#restore-from-scratch) and [Known gaps](#known-gaps).

## Services

| Service | LAN port | Tailnet URL (port) | Compose dir | Image |
|---|---|---|---|---|
| Nextcloud + MariaDB 10.6 | 8080 | `https://<host>.<tailnet>.ts.net` (443) | `nextcloud/` | `nextcloud`, `mariadb:10.6` |
| Pi-hole (DNS 53, web 8081) | 53, 8081 | `:10443` | `pihole/` | `pihole/pihole:latest` |
| Homepage | 3000 | `:8443` | `homepage/` | `ghcr.io/gethomepage/homepage:latest` |
| Weather (static nginx page) | 8082 | `:9443` | `weather/` | `nginx:alpine` |
| Finance Tracker (SQLite) | 8083 | `:11443` | `finance-tracker/` | built locally as `finance-tracker:local` |

No ports are open on the router. Services are reachable only through Tailscale.

## Host prerequisites

Tested on: Debian 13.6, kernel 6.12, Docker Engine 26.1.5, Compose plugin 2.26.1, git 2.47.3, restic 0.18.0, sqlite3 3.46.1.

- Docker Engine and the Compose plugin
- Tailscale, logged in to your tailnet
- restic, sqlite3, curl, git
- External SSD formatted as ext4. SQLite needs a POSIX filesystem. On exFAT or NTFS, journal deletes fail with `SQLITE_IOERR_DELETE`.

Mount the SSD at `/mnt/usb512`. Find its UUID with `blkid`, then add this line to `/etc/fstab`:

```
UUID=<ssd-uuid>  /mnt/usb512  ext4  defaults,nofail  0  2
```

Create the data directories:

```
mkdir -p /mnt/usb512/nextcloud/{app,data,db} \
         /mnt/usb512/finance-tracker/data \
         /mnt/usb512/pihole /mnt/usb512/homepage/config /mnt/usb512/weather
```

Host-specific values to check on a new machine:

- `backup.sh` skips the backup when the server runs over Wi-Fi. It checks for the interface `wlp2s0`, which is the NIC of this machine. Set yours: `ip route get 8.8.8.8`.
- `homepage/docker-compose.yml` has `group_add: "988"`, the GID of the `docker` group here. Check yours with `getent group docker`.

## Setup

1. Clone this repo to `/root/homelab-infra`.
2. In each service directory: `cp .env.example .env`, fill in the values (see Configuration), then `docker compose up -d`.
3. Finance Tracker: clone its source to `/opt/finance-tracker`. The compose file there matches `finance-tracker/docker-compose.yml` in this repo.
   `git clone git@github.com:Nikita-devel/finance-tracker.git /opt/finance-tracker`
   Create `.env` from `.env.example` and keep `FT_SEED: "0"`. Seeding is only for an empty database.
4. Publish the services over Tailscale. Check the syntax against `tailscale serve --help` for your version.

```
tailscale serve --bg --https=443   http://127.0.0.1:8080
tailscale serve --bg --https=10443 http://127.0.0.1:8081
tailscale serve --bg --https=8443  http://127.0.0.1:3000
tailscale serve --bg --https=9443  http://127.0.0.1:8082
tailscale serve --bg --https=11443 http://127.0.0.1:8083
```

5. Backups: see [Backups](#backups).

## Configuration

Each service has an `.env.example` with placeholder values. Copy it to `.env` in the same directory as its `docker-compose.yml`. `.env` files are never committed (see `.gitignore`).

Values that are not in this repo:

- Tailscale hostname and IP
- LAN address of the host
- Database and admin passwords
- Restic credentials and the healthcheck URL, in `/root/.restic-env` (mode 600). Template: `systemd/restic-env.example`

Keep these in a password manager. The repo cannot recreate them.

## Backups

`backup.sh` runs from a systemd timer (`restic-backup.timer`, 03:30, with up to 15 minutes of random delay).

1. Puts Nextcloud into maintenance mode and dumps its MariaDB database.
2. Takes a consistent SQLite snapshot of Finance Tracker with `.backup` and checks it with `PRAGMA integrity_check`.
3. Backs up to Backblaze B2 with restic: Nextcloud data, Nextcloud `config.php`, the database dump, the Finance Tracker snapshot, Homepage config and Pi-hole config.
4. Applies retention (7 daily, 4 weekly, 6 monthly) and prunes.
5. Pings a healthcheck. A missing ping means the backup did not complete.

The script always turns maintenance mode off on exit and deletes its temporary dumps.

Install:

```
install -m 700 /root/homelab-infra/backup.sh /root/backup.sh
cp /root/homelab-infra/systemd/restic-backup.service /root/homelab-infra/systemd/restic-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now restic-backup.timer
```

Run it once by hand and read the log:

```
systemctl start restic-backup.service
journalctl -u restic-backup.service -n 50 --no-pager
```

## Related repositories

- `Nikita-devel/finance-tracker`: Finance Tracker source (Next.js, Prisma, SQLite). Contains no database, no `.env` and no personal data.

## Restore from scratch

Restic stores absolute paths, so restore into a staging directory first and copy from there.

1. Install the host prerequisites and mount the SSD.
2. Restore the latest snapshot into staging:
   `restic restore latest --target /root/restore`
   Files appear under `/root/restore/mnt/usb512/...` and `/root/restore/root/...`.
3. Nextcloud: copy `/root/restore/mnt/usb512/nextcloud/data` into `/mnt/usb512/nextcloud/data`. Start only the database with `cd nextcloud && docker compose up -d db`, then import the dump:
   `docker exec -i nextcloud-db-1 sh -c 'mysql -unextcloud -p"$MYSQL_PASSWORD" nextcloud' < /root/restore/root/nextcloud-db.sql`
   Copy `/root/restore/mnt/usb512/nextcloud/app/config/config.php` to `/mnt/usb512/nextcloud/app/config/config.php`. Nextcloud does not start without it.
4. Finance Tracker: with its container stopped, copy the snapshot into place:
   `cp /root/restore/root/finance-tracker.db /mnt/usb512/finance-tracker/data/finance.db`
   Then `sqlite3 /mnt/usb512/finance-tracker/data/finance.db "PRAGMA integrity_check;"` must print `ok`.
5. Copy the Pi-hole and Homepage config from `/root/restore/mnt/usb512/` into `/mnt/usb512/`.
6. Start every service: `docker compose up -d` in each service directory. Check Nextcloud with `docker exec -u www-data nextcloud-app-1 php occ status` and Finance Tracker with `curl http://127.0.0.1:8083/api/health`.

Restore has been tested on a sample of files. A full restore has not been tested end to end.

## Known gaps

- Pi-hole and Homepage use `:latest` tags. Pin versions for reproducible rebuilds.
- Tailscale serve mappings are set by hand (see Setup).
- Single node, no high availability.
- The external SSD has been unstable in the past. The plan is to move data to the internal NVMe.

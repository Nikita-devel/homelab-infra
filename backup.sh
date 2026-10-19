#!/bin/bash
set -euo pipefail

source /root/.restic-env

# Захист від бекапу через мобільну мережу
ACTIVE_IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
if [ "$ACTIVE_IFACE" = "wlp2s0" ]; then
    echo "УВАГА: Сервер працює через Wi-Fi ($ACTIVE_IFACE). Бекап скасовано." >&2
    exit 1
fi

# Завжди вимикати режим обслуговування і прибирати тимчасові дампи, навіть при помилці
cleanup() {
    docker exec -u www-data nextcloud-app-1 php occ maintenance:mode --off >/dev/null 2>&1 || true
    rm -f /root/nextcloud-db.sql /root/finance-tracker.db
}
trap cleanup EXIT

echo "=== Backup started: $(date) ==="

docker exec -u www-data nextcloud-app-1 php occ maintenance:mode --on

# Пароль береться з env контейнера, а не зі скрипта і не з аргументів
docker exec nextcloud-db-1 sh -c 'mysqldump -unextcloud -p"$MYSQL_PASSWORD" --single-transaction --quick nextcloud' > /root/nextcloud-db.sql

docker exec -u www-data nextcloud-app-1 php occ maintenance:mode --off

# Finance Tracker: .backup узгоджений навіть під час запису
FT_DB=/mnt/usb512/finance-tracker/data/finance.db
if [ -f "$FT_DB" ]; then
  sqlite3 "$FT_DB" ".backup '/root/finance-tracker.db'"
  sqlite3 /root/finance-tracker.db "PRAGMA integrity_check;" | grep -q '^ok$'
else
  echo "УВАГА: $FT_DB не знайдено — finance-tracker зупинений?" >&2
fi

restic backup \
  /mnt/usb512/nextcloud/data \
  /root/nextcloud-db.sql \
  /root/finance-tracker.db \
  /mnt/usb512/homepage/config \
  /mnt/usb512/pihole \
  --exclude "*/appdata_*/preview/*" \
  --exclude "*/files_trashbin/*" \
  --tag auto

restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

curl -fsS -m 10 --retry 3 "$HC_PING_URL" > /dev/null
echo "=== Backup finished: $(date) ==="

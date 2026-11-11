#!/bin/sh
# backup.sh — copy the library databases to the user partition.
# Afterwards, copy /mnt/us/ccdb-repair/backup-* to your computer as well (MTP/USB).
set -e

DEST=/mnt/us/ccdb-repair/backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$DEST"

for f in cc.db cc.db-wal cc.db-shm ksdk.asset.db ksdk.asset.db-wal ksdk.asset.db-shm; do
  [ -f "/var/local/$f" ] && cp "/var/local/$f" "$DEST/" && echo "copied $f"
done

# small migration/flag files that describe the library state
( cd /var/local && tar cf "$DEST/var_local_flags.tar" \
    Ignite* LIBRARY_* ASSET_DB_MIGRATION FORCE_FULL_SYNC_TIME_LIBRARY_METADATA \
    SERIES_GROUPING_MIGRATION_DONE 2>/dev/null ) || true

sync
md5sum /var/local/cc.db "$DEST/cc.db"
echo "backup at: $DEST"

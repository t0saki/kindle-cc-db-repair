#!/bin/sh
# reset-ccdb.sh — move cc.db aside and reboot so the Kindle rebuilds it.
#
# What you lose: the "downloaded" state of every cloud item (files stay on disk),
# local-only collections that were never synced. Run restore-downloads.sh afterwards.
#
# Requires a backup made by backup.sh first.

BACKUP_ROOT=/mnt/us/ccdb-repair
ls -d $BACKUP_ROOT/backup-* >/dev/null 2>&1 || { echo "run backup.sh first"; exit 1; }

# !!! A firmware package left in the root of the user partition is installed
# automatically on the next boot, even if OTA is blocked by the jailbreak.
if ls /mnt/us/update*.bin /mnt/us/*.bin >/dev/null 2>&1; then
  echo "Found .bin files in /mnt/us — remove them first or the reboot will flash them:"
  ls -la /mnt/us/*.bin
  exit 1
fi

printf 'Move /var/local/cc.db aside and reboot now? [yes/N] '
read ans
[ "$ans" = "yes" ] || { echo aborted; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
cp /var/local/cc.db "$BACKUP_ROOT/cc.db.pre-reset-$STAMP" && sync
rm -f /var/local/cc.db /var/local/cc.db-wal /var/local/cc.db-shm /var/local/cc.db-journal
sync
echo "cc.db removed, rebooting in 3s"
sleep 3
reboot

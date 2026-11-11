#!/bin/sh
# verify.sh — after restore: which items from restore.list are still not
# registered as downloaded? Writes /mnt/us/ccdb-repair/retry.list, which you can
# feed back into restore-downloads.sh (delete restore.offset first).
#
# Typical leftovers: items that were queued when KOReader was opened or the
# device slept; they stay "DOWNLOADING" in ksdk.asset.db until re-submitted.

DIR=/mnt/us/ccdb-repair
LIST=${1:-$DIR/restore.list}
W=/var/local/ccdb-verify   # small, on the persistent /var/local partition
mkdir -p $W

sqlite3 "file:/var/local/cc.db?mode=ro" \
  "select p_cdeKey from Entries where p_type='Entry:Item' and p_isArchived=0
     and p_location is not null and p_cdeKey is not null;" | sort -u > $W/have
cut -d, -f1 "$LIST" | sort -u > $W/want
comm -23 $W/want $W/have > $W/missing

sqlite3 "file:/var/local/ksdk.asset.db?mode=ro" \
  "select ASIN from Nodes where DOWNLOAD_STATE='DOWNLOADING';" | sort -u > $W/stuck

cat $W/missing $W/stuck | sort -u | sed 's/$/,PDOC/' > $DIR/retry.list
echo "wanted=$(wc -l < $W/want) registered=$(comm -12 $W/want $W/have | wc -l)"
echo "missing=$(wc -l < $W/missing) stuck_downloading=$(wc -l < $W/stuck)"
echo "retry list: $DIR/retry.list ($(wc -l < $DIR/retry.list) items)"
echo "SQL logic error in current log: $(grep -c 'SQL logic error' /var/log/messages)"
rm -rf $W

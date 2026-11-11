#!/bin/sh
# build-restore-list.sh — from the OLD cc.db backup, list the items that were
# downloaded AND whose file still exists on disk.
#
# usage: build-restore-list.sh /mnt/us/ccdb-repair/backup-XXXX/cc.db
# output: /mnt/us/ccdb-repair/restore.list   ("cdeKey,cdeType" per line)
#         /mnt/us/ccdb-repair/stale.list     (marked downloaded, but file is gone)
#
# Why the stale list matters: while the old database was broken, deleting a book
# removed the file but failed to update the catalog. Those rows still say
# "downloaded". Do NOT restore them — that re-downloads books you deleted on
# purpose (in my case ~11 GB of comics that filled the device).
#
# TYPES: PDOC (personal documents) is what was tested. Set TYPES="'PDOC','EBOK'"
# to include purchased books (untested).

OLD=${1:?usage: $0 /path/to/old/cc.db}
TYPES=${TYPES:-"'PDOC'"}
OUTDIR=/mnt/us/ccdb-repair
mkdir -p $OUTDIR
OUT=$OUTDIR/restore.list
STALE=$OUTDIR/stale.list
: > $OUT; : > $STALE

sqlite3 -separator '|' "file:$OLD?mode=ro" \
  "select p_cdeKey, p_cdeType, p_location from Entries
   where p_type='Entry:Item' and p_isArchived=0
     and p_location is not null and p_cdeKey is not null
     and p_cdeType in ($TYPES);" |
while IFS='|' read k t l; do
  if [ -e "$l" ]; then echo "$k,$t" >> $OUT; else echo "$k,$t" >> $STALE; fi
done

echo "restore candidates (file present): $(wc -l < $OUT)  -> $OUT"
echo "stale rows (file missing, skipped): $(wc -l < $STALE)  -> $STALE"

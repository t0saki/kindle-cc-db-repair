#!/bin/sh
# diagnose.sh — check whether this Kindle has the broken-cc.db symptom.
# Read-only. Run as root on a jailbroken Kindle, with the native UI running
# (not inside KOReader), right after "Sync & Check for Items".

LOG=/var/log/messages

echo "== firmware"
cat /etc/prettyversion.txt 2>/dev/null; echo

echo "== log signatures (since last log rotation)"
printf 'SQL logic error (ccat change.lua) : %s\n' "$(grep -c 'SQL logic error' $LOG)"
printf 'ProcessArchiveItemFailed          : %s\n' "$(grep -c 'ProcessArchiveItemFailed' $LOG)"
printf 'UpdateCCatFailed                  : %s\n' "$(grep -c 'ProcessArchivedItemsUpdateCCatFailed' $LOG)"
printf 'database is locked                : %s\n' "$(grep -c 'database is locked' $LOG)"

echo
echo "== sample lines"
grep -E 'change.lua:[0-9]+:.*SQL logic error' $LOG | tail -2 | cut -c1-220
grep -E 'ProcessArchiveItemFailed' $LOG | tail -1 | cut -c1-220

echo
echo "== library state (read-only)"
sqlite3 "file:/var/local/cc.db?mode=ro" \
  "select 'cc.db  archived='||sum(p_isArchived=1)||' downloaded='||sum(p_isArchived=0 and p_location is not null) from Entries where p_type='Entry:Item';" 2>&1
sqlite3 "file:/var/local/ksdk.asset.db?mode=ro" \
  "select 'asset  '||DOWNLOAD_STATE||'='||count(*) from Nodes group by DOWNLOAD_STATE;" 2>&1

echo
echo "== storage"
df -h /mnt/us /var 2>/dev/null

cat <<'EOF'

How to read this:
  * Non-zero "SQL logic error" together with "ProcessArchiveItemFailed ... cdeType=PDOC,
    action=insert" means new personal documents cannot be written into the local
    content catalog (cc.db). That is the bug this repo deals with.
  * Network problems look different (tmd end_transfer:FAILED with curl/HTTP errors).
EOF

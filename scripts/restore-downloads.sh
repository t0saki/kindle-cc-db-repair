#!/bin/sh
# restore-downloads.sh — re-register downloaded items through the Kindle's own
# download pipeline (the same action as tapping "Download" in the library).
#
# When the file is already on disk the content request returns HTTP 304 and
# nothing is transferred; only a ~3 KB manifest is fetched. The catalog
# (cc.db) and the new asset DB (ksdk.asset.db) are both updated by Amazon's code.
#
# usage: restore-downloads.sh [list] [batch] [interval_seconds]
#   defaults: /mnt/us/ccdb-repair/restore.list 20 45
#
# Run it detached so it survives your SSH session:
#   setsid sh restore-downloads.sh </dev/null >/dev/null 2>&1 &
#
# Rules while it runs:
#   * stay on the native home screen, plugged in, Wi-Fi on
#   * do NOT open KOReader (it stops the framework; the download queue is lost)
# It is resumable: progress is kept in restore.offset; just run it again.

LIST=${1:-/mnt/us/ccdb-repair/restore.list}
BATCH=${2:-20}
INTERVAL=${3:-45}
DIR=/mnt/us/ccdb-repair
LOG=$DIR/restore.log
OFF=$DIR/restore.offset
STATS=$DIR/restore.stats
MSG=/var/log/messages
# /var is a 64 MB tmpfs (and /tmp lives in it). During bulk downloads the
# syslog grows by several MB per minute and fills it; keep it short.
MSG_LIMIT=12000000

mkdir -p $DIR
[ -f "$LIST" ] || { echo "no list: $LIST"; exit 1; }
total=$(wc -l < "$LIST")
i=$(cat $OFF 2>/dev/null || echo 0)
echo "$(date +%F_%T) start offset=$i total=$total" >> $LOG

lipc-set-prop com.lab126.powerd preventScreenSaver 1
trap 'lipc-set-prop com.lab126.powerd preventScreenSaver 0' EXIT INT TERM

guard_log() {
  sz=$(stat -c %s $MSG 2>/dev/null || echo 0)
  if [ "$sz" -gt $MSG_LIMIT ]; then
    echo "$(date +%T) http304=$(grep -c 'srv=304' $MSG) dl_failed=$(grep -c 'end_transfer:FAILED.*dir=down' $MSG) sqlerr=$(grep -c 'SQL logic error' $MSG)" >> $STATS
    : > $MSG
  fi
}

abort_if_sql_error() {
  if grep -q 'SQL logic error' $MSG; then
    echo "$(date +%T) SQL logic error seen again — stopping" >> $LOG
    exit 2
  fi
}

while [ "$i" -lt "$total" ]; do
  abort_if_sql_error
  items=$(sed -n "$((i+1)),$((i+BATCH))p" "$LIST" | tr '\n' ';' | sed 's/;$//')
  res=$(printf '{ kppItems = "%s" }\n' "$items" |
        lipc-hash-prop com.lab126.readnow kppDownloadAction 2>&1 |
        grep -o 'kppResponseCode = "[A-Z_]*"')
  i=$((i+BATCH)); [ $i -gt $total ] && i=$total
  echo $i > $OFF
  echo "$(date +%T) submitted=$i/$total $res" >> $LOG
  n=0; while [ $n -lt $INTERVAL ]; do sleep 5; n=$((n+5)); guard_log; done
done

# let the download queue drain (up to 30 min)
w=0
while [ $w -lt 1800 ]; do
  d=$(sqlite3 "file:/var/local/ksdk.asset.db?mode=ro" \
      "select count(*) from Nodes where DOWNLOAD_STATE='DOWNLOADING';" 2>/dev/null)
  [ "$d" = "0" ] && break
  sleep 30; w=$((w+30)); guard_log
done
echo "$(date +%F_%T) done (still downloading: ${d:-?})" >> $LOG

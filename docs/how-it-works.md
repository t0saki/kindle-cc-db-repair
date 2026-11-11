# How it works / 原理笔记

These are observations from one device (Kindle Paperwhite 12th gen Signature
Edition, firmware 5.19.6 → 5.20.1.0.2). Amazon's internals change between
releases; treat names and paths as "true on this firmware".

## Two library databases

| file | owner | role |
|---|---|---|
| `/var/local/cc.db` | `ccat` (Lua, running inside the Java framework, reachable on `127.0.0.1:9101`) | the classic Content Catalog: table `Entries`, one row per cloud ("archived", `p_isArchived=1`) item and one per downloaded copy (`p_isArchived=0`, `p_location` = file path) |
| `/var/local/ksdk.asset.db` | `KPPMainApp` (the new React-Native library UI) | table `Nodes`, `DOWNLOAD_STATE` = `DOWNLOADED` / `NOT_DOWNLOADED` / `DOWNLOADING`; this is what the library UI shows |

The two are kept in sync by a "double write" mechanism that lives in `cc.db`:
triggers on `Entries` (`EntriesAuditLog*Trigger`, `CompanionRelation*Trigger`)
insert into `CatalogChanges`, whose trigger fans out into `AuditLog`; the other
side replays `AuditLog`. The triggers call Lua user functions from
`/usr/lib/ccat/sql_functions.lua` and use `json_*` builtins. Several text
columns (and their indexes) use a custom `COLLATE icu`.

Consequences:

* You cannot safely edit `cc.db` with the stock `sqlite3` CLI: it has no `icu`
  collation and none of the Lua functions. With a different collation the
  indexes look corrupt (`SQLITE_CORRUPT_INDEX`, "database disk image is
  malformed") even when they are fine — and writes made that way would really
  corrupt them. Read-only queries that do not touch those indexes are fine
  (`sqlite3 "file:/var/local/cc.db?mode=ro"`).
* Deleting `cc.db` makes the system rebuild it; the deletion propagates, so the
  asset DB also flips every item to `NOT_DOWNLOADED`.

## The failure

When cloud sync runs (`archive` daemon fetches `archivedItems.xml`, HTTP 200),
`ccat` re-inserts each personal document (delete existing row by uuid, then
insert). On the broken database both statements failed:

```
java[...]: E rc:lwsf:http_code=400,handler=process_/change,... /usr/lib/ccat/change.lua:1969: {"http_status_code":400,"sqlite3_msg":"SQL logic error","sqlite3_code":1}
java[...]: E rc:lwsf:http_code=400,handler=process_/change,... /usr/lib/ccat/change.lua:2321: {"http_status_code":400,"sqlite3_msg":"SQL logic error","sqlite3_code":1}
archive[...]: E archive:ProcessArchiveItemFailed:errorMsg=nullResponse,cdeKey=<private>,cdeType=PDOC,title=<private>,action=insert:
archive[...]: W archive:ProcessArchivedItemsUpdateCCatFailed:reason=updateCCATFailed,status=-1:CCAT update failed
```

(`change.lua:1969` is the `DELETE FROM Entries WHERE p_uuid = ?` path,
`:2321` is the generic statement executor used for the `INSERT`.)
`ccat` reports `sqlite3_errstr()`, so the real reason is hidden behind the
generic "SQL logic error" (SQLITE_ERROR). I did not pin down the exact
statement; replaying the same DELETE on a copy with stub functions and a
REINDEX succeeded, so the schema/trigger chain itself is not inherently broken.
Some state inside that particular database file was.

User-visible effects, all from that one failure:

* newly sent (e-mail / Send to Kindle) documents never appear, not even in search
* "Sync to furthest page read" fails
* downloaded personal documents show only "Delete permanently" (they are no
  longer linked to their cloud entry)
* deleting a book removes the file but leaves a stale "downloaded" row

It was **not** a network problem, even though it looked network-dependent
(DNS, TCP, TLS, MTU were all verified fine with packet captures; the phone app
on the same Wi-Fi works because it has its own database). `tmd` 403s from
`AmazonS3` right after boot are a red herring: queued pre-signed URLs that
expired while Wi-Fi was coming up.

## Why the scanner does not bring "downloaded" back

`scanner` (runs only while the framework runs) watches `/mnt/us/documents`
including `Downloads/Items01`, but a full scan reports
`fullscan:OK:add=0,del=0,upd=0`: files in `Downloads/` are owned by the
download manager and are registered at download time, not by the scanner.
Waiting does not help.

## Re-registering via the official download action

The library's "Download" button ends up as a LIPC hash property:

```
echo '{ kppItems = "CDEKEY,PDOC;CDEKEY2,PDOC" }' | lipc-hash-prop com.lab126.readnow kppDownloadAction
# -> kppResponseCode = "OK"
```

(`DownloadActionHandler` in `/opt/amazon/ebook/lib/EInkReadNowService.jar`
splits `kppItems` on `;` then `,` into cdeKey/cdeType.)

The chain is `readnow` → `ContentToDoHandler` (manifest todo) → `tmd`. If the
file already exists, the content GET returns **304 Not Modified** and 0 bytes
are transferred; the `.sdr` sidecar (reading position `.yjr`, annotations) is
reused. Then `ccat` inserts the downloaded row and the asset DB follows.

Observed throughput: ~15–20 items/min. The queue (`BulkDownloadsQueueManager`)
lives in the framework; opening KOReader (which stops the framework) or letting
the device sleep loses it, leaving rows stuck in `DOWNLOADING` → re-submit them
(`verify.sh`).

## Removing a download the official way

```
echo '{ kppCdeKey = "CDEKEY", kppCdeType = "PDOC" }' | lipc-hash-prop com.lab126.readnow kppDeleteItemAction
```

(Parameter names come from the handler class; this exact invocation was **not
run** — test on a single item first.)

`DeleteItemHandler` deletes the downloaded copy. Only if the entry is a
*sample* **and** `kppFrom` equals `cloud` does it additionally revoke the
sample in the cloud. Do not pass `kppFrom`. (Not exercised in bulk; I removed
the extra items by hand in the UI.)

## Other traps hit on the way

* **Root `.bin` gets flashed on reboot.** Véra blocks OTA by renaming
  `/usr/bin/otaupd` and `/usr/bin/otav3` to `*.bck` (which also hides
  "Update your Kindle"), but a firmware package sitting in `/mnt/us` is still
  installed on the next boot.
* **`/var` is a 64 MB tmpfs and `/tmp` lives in it.** Bulk downloads make
  `/var/log/messages` grow by ~4 MB/min; together with a copied database it
  filled `/var` to 100 %. Don't copy databases to `/tmp`; truncate the log.
* **KOReader's SSH dies with KOReader.** To work while the native UI runs,
  start KOReader's bundled dropbear yourself:
  `cd /mnt/us/koreader && setsid ./dropbear -E -R -s -p 2223 -P /tmp/dropbear_2223.pid`
  (key-only; it reads `settings/SSH/authorized_keys` relative to that dir).
* **Don't `mtp-detect` this device** (libmtp): it makes the Kindle drop out of
  MTP mode. Use OpenMTP / Android File Transfer for copying.
* `pkill -f pattern` over SSH kills your own session when the pattern also
  appears in the command line. Use pid files.

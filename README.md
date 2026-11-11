# kindle-cc-db-repair

Fix for a Kindle whose local library database (`cc.db`) silently stopped
accepting writes: **Send-to-Kindle documents never show up, "Sync to furthest
page read" fails, and downloaded personal documents only offer "Delete
permanently"**. Includes a way to rebuild the database **without losing the
"downloaded" state** of thousands of items.

Requires a jailbroken Kindle with a root shell (e.g. Véra + KOReader's SSH).
Tested on a Kindle Paperwhite 12th gen Signature Edition, firmware 5.19.6
(failure) and 5.20.1.0.2 (rebuild + restore). Use at your own risk.

中文说明在下面。

---

## 症状

全部同时出现，或出现其中几条：

- 通过邮件 / Send to Kindle 发送的新文档**不出现**，搜也搜不到
- 「同步到最远阅读页」失败
- 下载过的个人文档长按只剩「永久删除」，没有「从设备移除」，像本地侧载文档一样
- 删除书以后，文件没了，但它仍然被算作「已下载」
- 手机 Kindle App 在同一个网络下一切正常，看起来像是 Wi-Fi 或网络的问题

**这不是网络问题。** 我抓包确认过，DNS、TCP、TLS 都正常，亚马逊也正常返回了文档列表。问题出在设备本地：Kindle 把这些文档写进自己的书库数据库时，写入失败了。

## 先确认是不是这个问题

在原生界面点一次「同步并检查新内容」，然后用 root 执行：

```sh
sh scripts/diagnose.sh
```

如果看到下面两类报错，就是这个问题：

```
... /usr/lib/ccat/change.lua:1969: {"http_status_code":400,"sqlite3_msg":"SQL logic error","sqlite3_code":1}
archive[...]: E archive:ProcessArchiveItemFailed:errorMsg=nullResponse,cdeKey=<private>,cdeType=PDOC,...,action=insert:
```

## 修复流程

把 `scripts/` 拷到 Kindle 上，比如 `/mnt/us/ccdb-repair/scripts/`。以下命令都以 root 身份执行。

### 0. 备份

```sh
sh scripts/backup.sh          # 备份到 /mnt/us/ccdb-repair/backup-<时间>/
```

再把这个目录拷到电脑上留一份。

### 1. 重建 cc.db

```sh
sh scripts/reset-ccdb.sh      # 检查根目录有没有 .bin，然后挪走 cc.db 并重启
```

> ⚠️ **根目录 `/mnt/us/` 里不能有固件包 `*.bin`。** Véra 只屏蔽了菜单入口和 OTA，挡不住开机时自动安装根目录里的 `.bin`。脚本会检查这一点，发现 `.bin` 就会拒绝继续。

重启后，Kindle 会从云端重新拉取书目。新文档能出现、进度同步也恢复后，**「已下载」会变成 0**，但文件其实都还在 `documents/Downloads/Items01/` 里。
- 重建 `cc.db` 会把下载状态同步清空到新书库 `ksdk.asset.db`。
- 本地扫描程序（`scanner`）不会重新登记 `Downloads/` 目录里的文件。

所以等多久都不会自己恢复，需要做下一步。

### 2. 恢复「已下载」状态

```sh
# 用旧库生成清单：只保留「标记为已下载、而且文件确实还在」的条目
sh scripts/build-restore-list.sh /mnt/us/ccdb-repair/backup-XXXX/cc.db

# 后台批量调用官方的「下载」动作（断开 SSH 也会继续跑）
setsid sh scripts/restore-downloads.sh </dev/null >/dev/null 2>&1 &
tail -f /mnt/us/ccdb-repair/restore.log
```

脚本调用的是系统自带的下载动作，等于替你在书库里逐本点「下载」：

```sh
echo '{ kppItems = "CDEKEY,PDOC;..." }' | lipc-hash-prop com.lab126.readnow kppDownloadAction
```

本地文件还在的书，内容请求会返回 **HTTP 304**，几乎不消耗流量。阅读位置和笔记（`.sdr` 目录）原样保留。两个数据库都由亚马逊自己的代码写入，所以排序规则和触发器都是对的。实测速度大约每分钟 15–20 本。

运行期间请注意：
- 停在**原生主页**，插着电，保持 Wi-Fi 连接
- **不要打开 KOReader**：它会停掉原生框架，下载队列会丢失
- 脚本会临时禁用屏保，并在日志过大时自动清空 `/var/log/messages`，防止撑满 64 MB 的 `/var`

### 3. 核对和补漏

```sh
sh scripts/verify.sh          # 生成 retry.list，内容是还没登记上的、卡在「下载中」的
rm /mnt/us/ccdb-repair/restore.offset
setsid sh scripts/restore-downloads.sh /mnt/us/ccdb-repair/retry.list </dev/null >/dev/null 2>&1 &
```

## ⚠️ `stale.list` 不要恢复

旧库坏掉期间删过的书，文件已经删了，但数据库里还记着「已下载」。`build-restore-list.sh` 会把这类条目单独放进 `stale.list`，**不会恢复它们**。

我第一次没区分这一点，结果把以前删掉的约 11 GB 漫画又下了回来，存储直接被撑满。

## 不建议的做法

- **用 `sqlite3` 命令行直接改 `cc.db`**。表上的索引用了 `COLLATE icu`，触发器依赖 ccat 内部的 Lua 函数，命令行工具都没有。排序规则稍有不一致，就会写出一个看起来正常、但索引已经错乱的库。详见 [docs/how-it-works.md](docs/how-it-works.md)。
- **恢复出厂设置**。下载状态一样会丢，而且所有文件都要重新下载，越狱也没了。

## 原理

两个数据库怎么同步、日志怎么看、各种接口的参数格式，以及踩过的坑，都在 [docs/how-it-works.md](docs/how-it-works.md)。

## 没有越狱怎么办

这个仓库帮不上忙：`/var/local/` 需要 root 权限才能访问。我没有验证过不越狱的修复方法。

## License

MIT

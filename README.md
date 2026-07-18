# Borgcow

Incremental, deduplicating, off-site backups for [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized) using [BorgBackup](https://www.borgbackup.org/).

No downtime. After the first run, a nightly backup uploads a few megabytes instead of the whole mail store.

---

## Status

Running in production on one mailcow instance (~600 MB of mail) since July 2026.

**The restore path has been exercised in `--extract-only` mode — archive contents verified — but a full end-to-end restore onto a clean host has not yet been performed.** Treat the restore script as reviewed-but-unproven and test it on a throwaway VM before you need it. If you do run a full restore, opening an issue with the result would help everyone.

---

## What problem this solves

I wanted mailcow backed up to off-site storage, nightly, without re-uploading everything each time.

mailcow's own `helper-scripts/backup_and_restore.sh` produces `.tar.gz` archives. That is a reasonable design for what it's built for: a self-contained snapshot you can carry anywhere and unpack with standard tools, with no dependency on any particular backup system. But it composes badly with Borg. Gzip compresses the whole stream *before* Borg ever sees the bytes, so one new email shifts everything downstream and deduplication drops to near zero. Every night, the full mail store goes over the wire again.

The alternative is to point Borg at the live volume directories. `vmail` is a Maildir: one file per message, written atomically (`tmp/` → `rename()` into `new/`), never modified afterwards. Borg's files cache lets it skip unchanged files without reading them, so only genuinely new data is uploaded.

Two consecutive runs on my instance:

```
                       Original size      Compressed size    Deduplicated size
This archive:              613.84 MB            609.94 MB              2.49 MB
```

613 MB of content, 2.49 MB uploaded, 0.85 seconds.

Getting there took some trial and error. What follows is what I ended up with and why.

---

## What gets backed up

| Component | Included | Why |
|---|:--:|---|
| `vmail-vol-1` | ✅ | The mail itself |
| `crypt-vol-1` | ✅ | Mailbox encryption key — **without it the mail is unreadable** |
| `rspamd-vol-1` | ✅ | Maps and state (caches excluded, see below) |
| `postfix-vol-1` | ✅ | Queue and generated maps |
| `redis-vol-1` | ✅ | Rspamd bayes/neural data, snapshotted via `BGSAVE` |
| SQL dump | ✅ | Domains, mailboxes, aliases, ACLs, DKIM keys, SOGo data |
| `mailcow.conf`, `.env`, `data/conf` | ✅ | Configuration and credentials |

### What I left out, and why

Working through `docker volume ls` one entry at a time turned out to matter more than anything else. Sizes are from my instance.

| Component | Size seen | Why excluded |
|---|---|---|
| `clamd-db-vol-1` | 323 MB | ClamAV signatures. Fully replaced on every `freshclam` update. This one alone would have destroyed deduplication — it was 55% of the size of my actual mail. Re-downloaded automatically. |
| `mysql-vol-1` | 221 MB | Raw InnoDB files. The plain-SQL dump of the same data came out at **284 KB**. Almost all of that 221 MB is engine overhead, not data. |
| rspamd hyperscan caches | ~100 MB | `*.hs*`, `*.unser`, `rspamd.rrd`. Compiled from config and CPU-architecture specific, so restoring them onto different hardware is undesirable anyway. Two files accounted for 90 of the volume's 103 MB. |
| `vmail-index-vol-1` | 3.8 MB | Dovecot indexes and FTS. Rebuilt on demand. |
| `sogo-web-vol-1` | 73 MB | Static assets shipped inside the image. |
| `postfix-tlspol-vol-1` | 8 KB | MTA-STS/DANE policy cache. Self-healing. |
| `mysql-socket-vol-1` | 8 KB | A unix socket. |

Roughly half the raw disk footprint never reaches the repository — specifically the half that churns daily.

If you back up "all the volumes" without looking at them, `clamd-db-vol-1` will quietly undo the entire point of the exercise.

---

## Design notes

**No downtime.** Services are never stopped. Maildir writes are atomic, so Borg cannot catch a half-written message. Dovecot's indexes would be inconsistent, which is why they're excluded rather than a reason to stop the service. Stopping Postfix during a backup makes senders defer mail; there's no need for it here.

**`mysqldump`, not `mariabackup`.** Mariabackup copies binary `.ibd` files whose pages shift with every transaction. A plain SQL dump is linear text, nearly identical between runs. `--skip-dump-date` matters too: without it, a changing timestamp header dirties the first chunk every night.

`--single-transaction` gives a consistent snapshot without locking, but that guarantee only holds for InnoDB tables. mailcow's schema is InnoDB, so this is fine in practice — worth knowing if you've added tables of your own.

**Compression does not break dedup.** Borg chunks *before* it compresses, so `--compression zstd,3` costs nothing. This is exactly the opposite of piping a tarball through gzip.

**Redis is the floor on incremental size.** `dump.rdb` is rewritten in full on every `BGSAVE`, and rspamd updates its keys constantly, so expect ~2–3 MB of new data per run even when no mail arrived. That's the price of keeping rspamd's learning data, and it's worth paying.

**Safe by construction.**
- Passphrase read via `BORG_PASSCOMMAND` from a `chmod 600` file, never embedded in the script.
- DB password passed as `MYSQL_PWD` inside the container, not on a command line where `ps` could read it.
- `flock` prevents a slow run from being lapped by the next cron tick.
- `trap ... EXIT INT TERM` guarantees the plaintext SQL dump is wiped even if the run is killed.
- `BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK` and `BORG_RELOCATED_REPO_ACCESS_IS_OK` are **not** set. Those suppress exactly the warnings you want to see during a MITM or a swapped repository.
- A `borg info` preflight fails fast on a bad URL before spending time on dumps.

---

## Requirements

- mailcow-dockerized
- `borg` ≥ 1.2, `rsync`, `flock`, `curl`
- A remote repository: [BorgBase](https://www.borgbase.com/) (10 GB free tier), rsync.net, or your own server

---

## Setup

### 1. SSH key

```bash
ssh-keygen -t ed25519 -f /root/.ssh/borg_ed25519 -N ''
cat /root/.ssh/borg_ed25519.pub
```

No passphrase on the key — it breaks unattended runs and adds little for a machine-local key.

### 2. Register the key

**BorgBase:** Account → SSH Keys → Add Key. Then open your repository → Edit → Access → select the key. *Skipping this second step is the most common setup failure — the key exists but isn't attached to anything.*

**Self-hosted:** in the backup user's `authorized_keys`:

```
command="borg serve --append-only --restrict-to-path /home/borguser/repo",restrict ssh-ed25519 AAAA...
```

### 3. Passphrase

```bash
install -d -m 700 /root/.config/borg
printf '%s' 'your-passphrase' > /root/.config/borg/passphrase
chmod 600 /root/.config/borg/passphrase
```

The SSH key and the Borg passphrase are **two different things**, and conflating them causes a lot of confusion. The key authenticates you to the server. The passphrase encrypts the data. The server never sees the passphrase.

### 4. Configure

Edit the config block at the top of `mailcow-borg-backup.sh`:

```bash
export BORG_REPO='ssh://xxxxxxxx@xxxxxxxx.repo.borgbase.com/./repo'
```

> **BorgBase:** the path is always exactly `/./repo`. Subdirectories are rejected server-side with `Repository path not allowed`. Each BorgBase repository is one Borg repository; you can't nest them. Use the dashboard's *Copy repo URL* button rather than typing it.

### 5. Initialise and export the key

Creating a repo in the BorgBase dashboard is not the same as `borg init`. The dashboard allocates space; `borg init` builds the encrypted structure inside it.

```bash
export BORG_REPO='ssh://xxxxxxxx@xxxxxxxx.repo.borgbase.com/./repo'
export BORG_PASSCOMMAND='cat /root/.config/borg/passphrase'
export BORG_RSH='ssh -i /root/.ssh/borg_ed25519'

borg info ::                              # already initialised?
borg init --encryption=repokey-blake2     # if not
borg key export :: /root/borg-key.txt
```

**Move `borg-key.txt` off the server and delete the local copy.** If the server dies and the key only ever lived on it, the repository is permanently unreadable. This is the most common way people lose backups they believed they had.

Those three `export` lines live only in the shell that ran them. For interactive use later, put them in a file and source it from `.bashrc`:

```bash
cat > /root/.config/borg/env.sh <<'EOF'
export BORG_REPO='ssh://xxxxxxxx@xxxxxxxx.repo.borgbase.com/./repo'
export BORG_PASSCOMMAND='cat /root/.config/borg/passphrase'
export BORG_RSH='ssh -i /root/.ssh/borg_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=yes'
EOF
chmod 600 /root/.config/borg/env.sh
echo '[ -f /root/.config/borg/env.sh ] && . /root/.config/borg/env.sh' >> /root/.bashrc
```

The script sets its own, so cron is unaffected either way.

### 6. Install and run

```bash
install -m 700 mailcow-borg-backup.sh /usr/local/sbin/
/usr/local/sbin/mailcow-borg-backup.sh
```

### 7. Verify deduplication — do not skip this

Run it a second time and read the `This archive` row. **Deduplicated size** should be single-digit megabytes. If it's hundreds, something churning got included:

```bash
borg diff ::ARCHIVE_1 ARCHIVE_2 | head -50
```

This is the test that tells you the whole design is working. Everything else is setup.

### 8. Schedule

```cron
17 3 * * * /usr/local/sbin/mailcow-borg-backup.sh >> /var/log/mailcow-borg.log 2>&1
```

```bash
cat > /etc/logrotate.d/mailcow-borg <<'EOF'
/var/log/mailcow-borg.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
}
EOF
```

Set `HEALTHCHECK_URL` to a [healthchecks.io](https://healthchecks.io/), Uptime Kuma, or equivalent endpoint. The script pings it on success and `/fail` on failure.

This matters more than it looks. The usual way backups fail is not with an error — it's by silently not running at all, for months. A notification that only fires when the script runs cannot tell you the script stopped running. Whatever you use, it has to live somewhere other than the mail server.

---

## Retention

With `RUN_PRUNE=0` (default), the script never deletes anything. This pairs with an append-only repository: a compromised mail server cannot destroy its own backup history, which is the standard ransomware failure mode.

Run pruning from the backup host, or from the BorgBase dashboard:

```bash
borg prune --glob-archives 'mx10-*' --keep-daily 30 --keep-weekly 12 --keep-monthly 24
borg compact
```

If you accept the weaker threat model, set `RUN_PRUNE=1` and let the script handle it.

---

## Restore

```bash
./mailcow-borg-restore.sh --list
./mailcow-borg-restore.sh --archive mx10-2026-07-18T21:23:50 --extract-only   # safe, changes nothing
./mailcow-borg-restore.sh --archive mx10-2026-07-18T21:23:50
```

`--extract-only` unpacks the archive and verifies the critical pieces are present without touching the system. Useful as a periodic check on its own.

The full restore is destructive and pauses for confirmation at each phase:

1. **Extract** — nothing on the system is touched
2. **Config** — restore `mailcow.conf`, `.env`, `data/conf`
3. **Volumes** — `docker compose up --no-start` to create them
4. **Data** — `rsync --numeric-ids` from the archive
5. **Database** — start mysql alone, import the dump
6. **Start** — bring the stack up

Ownership is handled by extracting as root, so Borg restores the original uid/gid verbatim and `rsync --numeric-ids` carries them across. No manual `chown` on vmail or redis, which is a common source of a restore that starts but doesn't work.

On a fresh host, clone mailcow first:

```bash
git clone https://github.com/mailcow/mailcow-dockerized /opt/mailcow-dockerized
```

Do not run `generate_config.sh`. The restored `mailcow.conf` has to be used, because its `DBROOT`/`DBUSER`/`DBPASS` must match the SQL dump.

---

## Verify your backups

A backup you have never restored is not a backup.

**Monthly**, from the backup host:

```bash
borg check --verify-data
```

**Quarterly**, restore to a throwaway VM and actually log in. At this data volume it costs an hour and a couple of euros. Finding out during an outage costs considerably more.

---

## Troubleshooting

Everything here is something I actually hit.

| Symptom | Cause |
|---|---|
| `Repository path not allowed` | On BorgBase the path must be exactly `/./repo`. Subdirectories are rejected. |
| `Permission denied (publickey)` | Key uploaded to the account but not assigned to the repository under Edit → Access. |
| `Failed to create/acquire the lock (timeout)` | Stale lock on the remote repo, usually left by an operation whose SSH connection died. Confirm nothing is running with `pgrep -af borg`, then `borg break-lock`. Never break a lock while a real operation is in flight — two concurrent writers can corrupt a repository. |
| `Connection refused` | Too many failed logins; the IP is throttled. Wait a few minutes. |
| `another run is in progress` | A previous run is still going, or a stale `/var/run/mailcow-borg.lock`. |
| Second archive dedups poorly | Something churning got included. Find it with `borg diff`. |
| `mysqldump looks truncated` | Container under memory pressure; check `docker logs mysql-mailcow`. |
| Repo size on the server exceeds `borg info` | Borg appends to segment files and only frees space on `borg compact`. Some overhead is normal. |

---

## Credits

The core approach — pointing Borg directly at the volume mountpoints rather than at a tarball — comes from [MatthisB/mailcow-borg-backup](https://github.com/MatthisB/mailcow-borg-backup). This is an independent rewrite for current mailcow, with different volume handling, database strategy, and failure behaviour.

## License

MIT

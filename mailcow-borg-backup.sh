#!/usr/bin/env bash
#
# mailcow -> borg incremental backup
# Design goal: real deduplication. No tarballs, no gzip before borg.
# Runs WITHOUT stopping mail services.
#
# Volume audit -- verified against `docker volume ls` on this host.
#
# INCLUDED (restore-critical):
#   vmail-vol-1        : the actual mail (Maildir, atomic writes -> safe to read live)
#   crypt-vol-1        : mailbox encryption key. WITHOUT THIS THE MAIL IS UNREADABLE.
#   rspamd-vol-1       : maps and misc state. NOTE: the hyperscan regex caches
#                        (*.hs*, *.unser) and rspamd.rrd are excluded below --
#                        they are recompiled from config, are CPU-specific, and
#                        accounted for ~100 of this volume's 103 MB.
#                        Actual bayes/neural learning lives in Redis, not here.
#   postfix-vol-1      : mail queue + generated maps
#   redis-vol-1        : rspamd metadata + some mailcow state (via BGSAVE)
#   mysqldump          : all mailcow config, domains, mailboxes, aliases, ACLs, SOGo data
#   git dir configs    : mailcow.conf, .env, compose file, data/conf/*
#
# EXCLUDED, and why:
#   clamd-db-vol-1     : ClamAV signatures. Hundreds of MB, fully replaced on every
#                        freshclam update -> would single-handedly destroy dedup.
#                        Regenerated automatically on first start.
#   mysql-vol-1        : raw InnoDB files; superseded by the plain-SQL dump.
#   mysql-socket-vol-1 : a unix socket. Nothing to back up.
#   vmail-index-vol-1  : dovecot indexes + flatcurve FTS. Rebuilt on demand.
#   postfix-tlspol-vol : MTA-STS/DANE policy cache. Binary, churns, self-healing.
#   sogo-web-vol-1     : static assets shipped inside the image.
#   sogo-userdata-backup-vol-1 : redundant with the SQL dump. Opt in below if wanted.
#
set -euo pipefail

###############################################################################
# CONFIG
###############################################################################
WORKDIR='/opt/mailcow-dockerized'
STAGING='/var/lib/mailcow-borg-staging'      # dumps land here; must NOT be world-readable
LOCKFILE='/var/run/mailcow-borg.lock'
BORG_PREFIX='mx10'

# Repo should be APPEND-ONLY (BorgBase: toggle it per-repo in the dashboard).
#
# BorgBase: the path is ALWAYS exactly /./repo -- no subdirectories are allowed.
# `borg serve` is restricted server-side and will reject anything deeper with
# "Repository path not allowed". Use the dashboard's "Copy repo URL" button.
#   ssh://xxxxxxxx@xxxxxxxx.repo.borgbase.com/./repo
# Self-hosted: any path the restricted key permits.
export BORG_REPO='ssh://CHANGEME@CHANGEME.repo.borgbase.com/./repo'

# Passphrase must NOT live in this file. chmod 600, root:root.
export BORG_PASSCOMMAND='cat /root/.config/borg/passphrase'

# Harden SSH: pin the host key, disable agent/X11 forwarding.
export BORG_RSH='ssh -i /root/.ssh/borg_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=yes'

# If the remote repo is append-only, leave this as 0 and run prune server-side.
RUN_PRUNE=0
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12

# Optional dead-man's-switch. Leave empty to disable.
HEALTHCHECK_URL=''

# SOGo's own periodic dumps. Redundant with mysqldump, but small. 1 = include.
INCLUDE_SOGO_BACKUP=0

###############################################################################
# helpers
###############################################################################
log()  { printf '%s  %s\n' "$(date +'%F %T')" "$*"; }
die()  { log "FATAL: $*"; exit 1; }

EXIT_CODE=0

cleanup() {
    local rc=$?
    # Staging dumps contain plaintext DB contents -> never leave them behind.
    if [[ -d "$STAGING" ]]; then
        find "$STAGING" -mindepth 1 -delete 2>/dev/null || true
        log "staging cleaned"
    fi
    if [[ -n "$HEALTHCHECK_URL" ]]; then
        if [[ $rc -eq 0 && $EXIT_CODE -eq 0 ]]; then
            curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
        else
            curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}/fail" >/dev/null 2>&1 || true
        fi
    fi
    log "exit rc=$rc"
}
trap cleanup EXIT INT TERM

###############################################################################
# preflight
###############################################################################
[[ "$(id -u)" == "0" ]] || die "must run as root"
[[ -f "${WORKDIR}/mailcow.conf" ]] || die "mailcow.conf not found in ${WORKDIR}"
command -v borg >/dev/null || die "borg not installed"

# Single instance only. A long-running borg must never be lapped by cron.
exec 9>"$LOCKFILE"
flock -n 9 || die "another run is in progress"

# shellcheck disable=SC1091
source "${WORKDIR}/mailcow.conf"
CMPS_PRJ=$(echo "${COMPOSE_PROJECT_NAME:-}" | tr -cd '[:alnum:]-_')
[[ -n "$CMPS_PRJ" ]] || die "empty COMPOSE_PROJECT_NAME"

vol() {
    docker volume inspect -f '{{ .Mountpoint }}' "${CMPS_PRJ}_$1" 2>/dev/null \
        || die "volume ${CMPS_PRJ}_$1 not found -- check 'docker volume ls'"
}

VOL_VMAIL=$(vol vmail-vol-1)
VOL_CRYPT=$(vol crypt-vol-1)
VOL_RSPAMD=$(vol rspamd-vol-1)
VOL_POSTFIX=$(vol postfix-vol-1)
VOL_REDIS=$(vol redis-vol-1)

# Built as an array so the borg invocation stays clean when it is disabled.
EXTRA_PATHS=()
if [[ "$INCLUDE_SOGO_BACKUP" == "1" ]]; then
    EXTRA_PATHS+=( "$(vol sogo-userdata-backup-vol-1)" )
fi

COMPOSE_FILES=( "${WORKDIR}/docker-compose.yml" )
[[ -f "${WORKDIR}/docker-compose.override.yml" ]] && \
    COMPOSE_FILES+=( "${WORKDIR}/docker-compose.override.yml" )

cid() {
    local id
    id=$(docker ps -q --filter "name=$1" | head -n1)
    [[ -n "$id" ]] || die "container $1 is not running"
    echo "$id"
}

# Fail fast on a bad URL / missing key / uninitialized repo, BEFORE dumping
# anything. Cheaper than discovering it after a 10-minute mysqldump.
#
# --lock-wait matters here: `borg info` takes a repository lock too, and the
# server-side `borg serve` process can take a moment to tear down. Borg's
# default lock-wait is 1 second, which is not enough -- the create below would
# then fail with "Failed to create/acquire the lock (timeout)".
borg --lock-wait 120 info :: >/dev/null 2>&1 || die "cannot reach repo ${BORG_REPO} -- check the URL (BorgBase path must end in /./repo), the SSH key assignment, and whether 'borg init' has been run"

install -d -m 0700 -o root -g root "$STAGING"

START=$(date +%s)
log "=== backup start ==="

###############################################################################
# 1. database dump  (plain SQL text -> dedups ~95% between runs)
###############################################################################
log "dumping mariadb"
MYSQL_CID=$(cid mysql-mailcow)

# Password via env inside the container, never on the command line (ps leak).
docker exec -e MYSQL_PWD="${DBROOT}" "$MYSQL_CID" \
    mysqldump \
        --user=root \
        --single-transaction \
        --quick \
        --routines \
        --events \
        --triggers \
        --default-character-set=utf8mb4 \
        --skip-dump-date \
        --databases "${DBNAME}" \
    > "${STAGING}/mailcow.sql"
# --skip-dump-date matters: a changing timestamp header would dirty the chunk.

[[ -s "${STAGING}/mailcow.sql" ]] || die "mysqldump produced an empty file"
grep -q 'Dump completed' "${STAGING}/mailcow.sql" \
    || tail -n1 "${STAGING}/mailcow.sql" | grep -q ';' \
    || die "mysqldump looks truncated"
log "sql dump: $(du -h "${STAGING}/mailcow.sql" | cut -f1)"

###############################################################################
# 2. redis snapshot
###############################################################################
log "triggering redis BGSAVE"
REDIS_CID=$(cid redis-mailcow)
REDIS_CLI=(docker exec "$REDIS_CID" redis-cli)
[[ -n "${REDISPASS:-}" ]] && REDIS_CLI=(docker exec "$REDIS_CID" redis-cli -a "${REDISPASS}" --no-auth-warning)

LAST_SAVE=$("${REDIS_CLI[@]}" LASTSAVE | tr -d '\r')
"${REDIS_CLI[@]}" BGSAVE >/dev/null

for _ in {1..60}; do
    sleep 2
    NOW_SAVE=$("${REDIS_CLI[@]}" LASTSAVE | tr -d '\r')
    [[ "$NOW_SAVE" != "$LAST_SAVE" ]] && break
done
[[ "${NOW_SAVE:-}" != "$LAST_SAVE" ]] || die "redis BGSAVE did not complete in 120s"
log "redis snapshot ok"

###############################################################################
# 3. borg create
###############################################################################
log "starting borg create"
set +e
borg --lock-wait 300 create                                     \
    --verbose --stats --show-rc                                 \
    --compression zstd,3                                        \
    --exclude-caches                                            \
    --one-file-system                                           \
    --exclude '*/dovecot.index.cache'                           \
    --exclude '*/dovecot.index.thaw'                            \
    --exclude "${VOL_RSPAMD}/*.hs*"                             \
    --exclude "${VOL_RSPAMD}/*.unser"                           \
    --exclude "${VOL_RSPAMD}/rspamd.rrd"                        \
    --exclude "${WORKDIR}/data/conf/rspamd/local.d/*.inc.bak"   \
    ::"${BORG_PREFIX}-{now:%Y-%m-%dT%H:%M:%S}"                  \
    "${WORKDIR}/mailcow.conf"                                   \
    "${WORKDIR}/.env"                                           \
    "${COMPOSE_FILES[@]}"                                       \
    "${WORKDIR}/data/conf"                                      \
    "${WORKDIR}/data/assets"                                    \
    "${VOL_VMAIL}"                                              \
    "${VOL_CRYPT}"                                              \
    "${VOL_RSPAMD}"                                             \
    "${VOL_POSTFIX}"                                            \
    "${VOL_REDIS}"                                              \
    "${STAGING}"                                                \
    "$(readlink -f "${BASH_SOURCE[0]}")"                        \
    ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}
CREATE_RC=$?
set -e

if   [[ $CREATE_RC -eq 0 ]]; then log "borg create: OK"
elif [[ $CREATE_RC -eq 1 ]]; then log "borg create: WARNING (rc=1), archive exists"
else
    EXIT_CODE=$CREATE_RC
    # The most common rc=2 in practice is a stale remote lock left behind by an
    # operation whose SSH connection died. Deliberately NOT auto-broken: two
    # concurrent writers can corrupt a repository.
    log "HINT: if the error mentions 'Failed to create/acquire the lock', verify"
    log "      nothing is running (pgrep -af borg), then run: borg break-lock"
    die "borg create FAILED rc=${CREATE_RC}"
fi

###############################################################################
# 4. prune  (skip entirely when the remote repo is append-only)
###############################################################################
if [[ "$RUN_PRUNE" == "1" ]]; then
    log "pruning"
    borg --lock-wait 300 prune --list --show-rc \
        --glob-archives "${BORG_PREFIX}-*"      \
        --keep-daily   "$KEEP_DAILY"            \
        --keep-weekly  "$KEEP_WEEKLY"           \
        --keep-monthly "$KEEP_MONTHLY"
    borg compact
else
    log "prune skipped (append-only mode)"
fi

DUR=$(( $(date +%s) - START ))
log "=== done in $(printf '%02dh %02dm %02ds' $((DUR/3600)) $((DUR%3600/60)) $((DUR%60))) ==="
exit "$CREATE_RC"

###############################################################################
# REMOTE SETUP (on the backup host, in borguser's ~/.ssh/authorized_keys):
#
#   command="borg serve --append-only --restrict-to-path /home/borguser/repo",\
#   restrict ssh-ed25519 AAAA...
#
# Append-only means a compromised mail server cannot delete history.
# Run prune/compact from the backup host itself, on a schedule.
#
# INIT:
#   borg init --encryption=repokey-blake2
#   borg key export ::  -> store this OFFLINE. Losing it loses everything.
#
# VERIFY (monthly, from the backup host):
#   borg check --verify-data
#   borg extract --dry-run ::latest-archive
#
# A backup you have never restored is not a backup.
###############################################################################
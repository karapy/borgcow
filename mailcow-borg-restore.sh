#!/usr/bin/env bash
#
# mailcow <- borg restore
#
# Companion to mailcow-borg-backup.sh. Restores a mailcow instance from a
# Borg archive onto a clean host.
#
# This script is DESTRUCTIVE and interactive by design. It stops at each phase
# and asks. Read what it says before typing yes.
#
# Usage:
#   ./mailcow-borg-restore.sh --list
#   ./mailcow-borg-restore.sh --archive mx10-2026-07-18T21:23:50
#   ./mailcow-borg-restore.sh --archive latest --extract-only
#
set -euo pipefail

###############################################################################
# CONFIG -- must match the backup script
###############################################################################
WORKDIR='/opt/mailcow-dockerized'
RESTORE_DIR='/var/tmp/mailcow-restore'
STAGING_NAME='mailcow-borg-staging'    # basename of the staging dir in the archive

export BORG_REPO='ssh://CHANGEME@CHANGEME.repo.borgbase.com/./repo'
export BORG_PASSCOMMAND='cat /root/.config/borg/passphrase'
export BORG_RSH='ssh -i /root/.ssh/borg_ed25519 -o BatchMode=yes'

###############################################################################
# helpers
###############################################################################
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

confirm() {
    local reply
    printf '\n\033[1;33m?? %s\033[0m [type yes to continue] ' "$1"
    read -r reply
    [[ "$reply" == "yes" ]] || die "aborted by user"
}

ARCHIVE=''
EXTRACT_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)         borg list; exit 0 ;;
        --archive)      ARCHIVE="${2:-}"; shift 2 ;;
        --extract-only) EXTRACT_ONLY=1; shift ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        *)              die "unknown option: $1" ;;
    esac
done

[[ "$(id -u)" == "0" ]] || die "must run as root"
[[ -n "$ARCHIVE" ]] || die "no archive given. Run with --list to see options."
command -v borg   >/dev/null || die "borg not installed"
command -v rsync  >/dev/null || die "rsync not installed"
command -v docker >/dev/null || die "docker not installed"

###############################################################################
# PHASE 1 -- extract
###############################################################################
log "PHASE 1: extract archive '${ARCHIVE}' to ${RESTORE_DIR}"
info "Nothing on this system is modified during this phase."

if [[ -d "$RESTORE_DIR" ]]; then
    confirm "${RESTORE_DIR} already exists and will be DELETED. Continue?"
    rm -rf "$RESTORE_DIR"
fi
mkdir -p "$RESTORE_DIR"

cd "$RESTORE_DIR"
# Run as root so borg restores original uid/gid/permissions verbatim.
# This is what makes the ownership work out without any manual chown.
borg extract --list "::${ARCHIVE}"

log "extraction complete"
du -sh "$RESTORE_DIR"

# Locate the pieces inside the extracted tree.
EX_WORKDIR="${RESTORE_DIR}${WORKDIR}"
EX_SQL=$(find "$RESTORE_DIR" -name 'mailcow.sql' -path "*${STAGING_NAME}*" | head -n1)
EX_VMAIL=$(find "$RESTORE_DIR/var/lib/docker/volumes" -maxdepth 1 -name '*_vmail-vol-1' 2>/dev/null | head -n1)
EX_CRYPT=$(find "$RESTORE_DIR/var/lib/docker/volumes" -maxdepth 1 -name '*_crypt-vol-1' 2>/dev/null | head -n1)
EX_RSPAMD=$(find "$RESTORE_DIR/var/lib/docker/volumes" -maxdepth 1 -name '*_rspamd-vol-1' 2>/dev/null | head -n1)
EX_POSTFIX=$(find "$RESTORE_DIR/var/lib/docker/volumes" -maxdepth 1 -name '*_postfix-vol-1' 2>/dev/null | head -n1)
EX_REDIS=$(find "$RESTORE_DIR/var/lib/docker/volumes" -maxdepth 1 -name '*_redis-vol-1' 2>/dev/null | head -n1)

info "mailcow dir : ${EX_WORKDIR}"
info "sql dump    : ${EX_SQL:-NOT FOUND}"
info "vmail       : ${EX_VMAIL:-NOT FOUND}"
info "crypt key   : ${EX_CRYPT:-NOT FOUND}"

[[ -f "${EX_WORKDIR}/mailcow.conf" ]] || die "mailcow.conf not found in archive"
[[ -n "$EX_SQL" && -s "$EX_SQL" ]]    || die "mailcow.sql not found in archive"
[[ -n "$EX_VMAIL" ]]                  || die "vmail volume not found in archive"
[[ -n "$EX_CRYPT" ]]                  || die "crypt volume not found -- mail would be unreadable"

if [[ "$EXTRACT_ONLY" == "1" ]]; then
    log "extract-only mode: stopping here"
    info "Files are in ${RESTORE_DIR}. Nothing was changed on this system."
    exit 0
fi

###############################################################################
# PHASE 2 -- mailcow source tree + config
###############################################################################
log "PHASE 2: restore mailcow config into ${WORKDIR}"

if [[ ! -d "$WORKDIR" ]]; then
    info "${WORKDIR} does not exist. Clone mailcow first:"
    info "  git clone https://github.com/mailcow/mailcow-dockerized ${WORKDIR}"
    die "mailcow source tree missing"
fi

confirm "Overwrite mailcow.conf, .env and data/conf in ${WORKDIR} with the backup?"

# mailcow.conf carries DBROOT/DBUSER/DBPASS. These MUST match the SQL dump,
# so the backed-up file wins over any freshly generated one.
cp -av "${EX_WORKDIR}/mailcow.conf" "${WORKDIR}/mailcow.conf"
[[ -f "${EX_WORKDIR}/.env" ]] && cp -av "${EX_WORKDIR}/.env" "${WORKDIR}/.env"
rsync -aHAX --delete "${EX_WORKDIR}/data/conf/"   "${WORKDIR}/data/conf/"
[[ -d "${EX_WORKDIR}/data/assets" ]] && \
    rsync -aHAX "${EX_WORKDIR}/data/assets/" "${WORKDIR}/data/assets/"

log "config restored"

###############################################################################
# PHASE 3 -- create the volumes (containers created, not started)
###############################################################################
log "PHASE 3: create docker volumes"
cd "$WORKDIR"

# shellcheck disable=SC1091
source "${WORKDIR}/mailcow.conf"
CMPS_PRJ=$(echo "${COMPOSE_PROJECT_NAME:-}" | tr -cd '[:alnum:]-_')
[[ -n "$CMPS_PRJ" ]] || die "empty COMPOSE_PROJECT_NAME in restored mailcow.conf"
info "compose project: ${CMPS_PRJ}"

docker compose pull
docker compose up --no-start        # creates named volumes without running anything

vol() {
    docker volume inspect -f '{{ .Mountpoint }}' "${CMPS_PRJ}_$1" \
        || die "volume ${CMPS_PRJ}_$1 was not created"
}
V_VMAIL=$(vol vmail-vol-1)
V_CRYPT=$(vol crypt-vol-1)
V_RSPAMD=$(vol rspamd-vol-1)
V_POSTFIX=$(vol postfix-vol-1)
V_REDIS=$(vol redis-vol-1)

###############################################################################
# PHASE 4 -- volume data
###############################################################################
log "PHASE 4: copy volume data"
confirm "This OVERWRITES the contents of the mailcow docker volumes. Continue?"

# -H hardlinks, -A ACLs, -X xattrs, -a preserves uid/gid.
# Numeric ownership from the archive is what the containers expect.
copy_vol() {
    local src="$1" dst="$2" label="$3"
    if [[ -z "$src" || ! -d "${src}/_data" ]]; then
        info "SKIP ${label} (not in archive)"
        return
    fi
    info "restoring ${label} -> ${dst}"
    rsync -aHAX --numeric-ids --delete "${src}/_data/" "${dst}/"
}

copy_vol "$EX_CRYPT"   "$V_CRYPT"   "crypt (mail encryption key)"
copy_vol "$EX_VMAIL"   "$V_VMAIL"   "vmail (the mail itself)"
copy_vol "$EX_RSPAMD"  "$V_RSPAMD"  "rspamd"
copy_vol "$EX_POSTFIX" "$V_POSTFIX" "postfix"
copy_vol "$EX_REDIS"   "$V_REDIS"   "redis"

log "volume data restored"

###############################################################################
# PHASE 5 -- database
###############################################################################
log "PHASE 5: import the database"
info "Starting mysql alone so it can initialise, then importing the dump over it."

docker compose up -d mysql-mailcow

info "waiting for mysql to accept connections..."
for i in {1..60}; do
    if docker compose exec -T -e MYSQL_PWD="${DBROOT}" mysql-mailcow \
         mysqladmin --user=root ping >/dev/null 2>&1; then
        info "mysql is up"
        break
    fi
    sleep 3
    [[ $i -eq 60 ]] && die "mysql did not come up within 180s"
done

confirm "Import ${EX_SQL} into database '${DBNAME}'? Existing tables will be dropped."

# The dump was made with --databases, so it carries CREATE DATABASE + USE,
# and mysqldump's default --add-drop-table replaces the tables mailcow's
# first-run init just created.
docker compose exec -T -e MYSQL_PWD="${DBROOT}" mysql-mailcow \
    mysql --user=root --default-character-set=utf8mb4 < "$EX_SQL"

log "database imported"

###############################################################################
# PHASE 6 -- start everything
###############################################################################
log "PHASE 6: start mailcow"
confirm "Bring the full stack up?"

docker compose up -d

log "restore complete"
cat <<'EOF'

    Post-restore checklist
    ----------------------
    1. docker compose ps          -- every container should be healthy
    2. Log into the web UI with your old admin credentials.
    3. Dovecot rebuilds its indexes on first access. The first IMAP login
       per mailbox may be slow. This is expected, not an error.
    4. ClamAV signatures were deliberately not backed up. freshclam will
       download them; clamd stays unhealthy until it finishes.
    5. Rspamd recompiles its hyperscan caches on first start.
    6. DNS: point MX, SPF, DKIM and the PTR record at the new IP.
       DKIM keys came from the database, so the existing public DNS
       records remain valid.
    7. Send a test mail in both directions before decommissioning anything.
    8. Delete the extracted copy once you are satisfied:
         rm -rf /var/tmp/mailcow-restore

EOF
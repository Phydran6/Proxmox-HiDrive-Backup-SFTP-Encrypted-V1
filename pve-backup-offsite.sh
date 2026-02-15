#!/bin/bash
#===============================================================================
# PVE Backup to Cloud (SFTP) with GFS Retention
# Encrypted offsite backups for Proxmox VE via rclone
#
# Features:
#   - vzdump all VMs/CTs with ZSTD compression
#   - AES-256-CBC encryption before upload
#   - rclone upload with parallel streams (SFTP/WebDAV/S3/etc.)
#   - GFS retention policy (Grandfather-Father-Son)
#   - Email notification on failure (via PVE sendmail)
#   - Log rotation
#
# Requirements:
#   - Proxmox VE 7.x / 8.x
#   - rclone (apt install rclone) with configured remote
#   - openssl
#   - NAS or local storage as intermediate backup target
#   - sendmail (optional, for error notifications)
#
# Setup:
#   1. Configure rclone remote: rclone config
#   2. Edit the CONFIGURATION section below
#   3. Create encryption key:
#      echo "YOUR_SECURE_PASSWORD" > /root/.backup-encryption-key
#      chmod 600 /root/.backup-encryption-key
#   4. Copy script: cp pve-backup-offsite.sh /usr/local/bin/ && chmod +x /usr/local/bin/pve-backup-offsite.sh
#   5. Test: /usr/local/bin/pve-backup-offsite.sh
#   6. Automate: crontab -e → 0 1 * * * /usr/local/bin/pve-backup-offsite.sh >> /var/log/pve-backup-offsite.log 2>&1
#
# Restore:
#   openssl enc -aes-256-cbc -d -pbkdf2 -in backup.vma.zst.enc -out backup.vma.zst -pass file:/root/.backup-encryption-key
#   qmrestore backup.vma.zst VMID
#
# IMPORTANT: Store your encryption key safely! Without it, backups cannot be restored!
#
# License: MIT
#===============================================================================

set -euo pipefail

#=== CONFIGURATION - EDIT THESE VALUES ========================================

# Local/NAS backup directory (intermediate storage before upload)
BACKUP_DIR="/mnt/pve/YOUR-NAS-BACKUP/vzdump-offsite"

# rclone remote path (configure with 'rclone config' first)
# Examples:
#   SFTP:   "myremote:/path/to/backup"
#   S3:     "s3remote:mybucket/backups"
#   WebDAV: "webdav:/backup/pve"
RCLONE_REMOTE="your-remote:/path/to/backup"

# Encryption keyfile path
ENCRYPTION_KEYFILE="/root/.backup-encryption-key"

# Logfile
LOGFILE="/var/log/pve-backup-offsite.log"

# Number of parallel rclone transfers
RCLONE_TRANSFERS=4

# NAS mount check path (set to "" to skip mount check)
NAS_MOUNTPOINT="/mnt/pve/YOUR-NAS-BACKUP"

# GFS Retention (Grandfather-Father-Son)
GFS_DAILY=7        # Son: keep last N daily backups
GFS_WEEKLY=4       # Father: keep last N weekly backups
GFS_MONTHLY=12     # Grandfather: keep last N monthly backups
GFS_WEEKLY_DOW=0   # Day of week for Father (0=Sunday, 1=Monday, ..., 6=Saturday)
GFS_MONTHLY_DOM=1  # Day of month for Grandfather (1=1st, 15=15th, etc.)

#=== END CONFIGURATION ========================================================

HOSTNAME=$(hostname)
SCRIPT_START=$(date +%s)

#--- Functions ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

send_error_mail() {
    local subject="[BACKUP ERROR] ${HOSTNAME} - Offsite backup failed"
    local body="$1"
    local log_tail=""

    if [[ -f "$LOGFILE" ]]; then
        log_tail=$(tail -50 "$LOGFILE")
    fi

    {
        echo "From: PVE Backup <root@${HOSTNAME}>"
        echo "To: root"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        echo "=== PVE Offsite Backup Error Report ==="
        echo ""
        echo "Host:      ${HOSTNAME}"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Error:     ${body}"
        echo ""
        echo "=== Last Log Entries ==="
        echo ""
        echo "${log_tail}"
    } | sendmail root 2>/dev/null || true
}

error_exit() {
    log "ERROR: $1"
    send_error_mail "$1"
    cleanup_on_error
    exit 1
}

cleanup_on_error() {
    if [[ -d "$BACKUP_DIR" ]]; then
        rm -rf "${BACKUP_DIR:?}/"* 2>/dev/null || true
    fi
}

trap 'error_exit "Script terminated unexpectedly (signal/error)"' ERR

show_progress() {
    local current=$1
    local total=$2
    local label=$3
    local pct=0
    if [[ $total -gt 0 ]]; then
        pct=$(( current * 100 / total ))
    fi
    log "${label}: ${pct}% (${current}/${total})"
}

#===============================================================================
# MAIN
#===============================================================================

# Log rotation (>10MB)
if [[ -f "$LOGFILE" ]] && [[ $(stat --format="%s" "$LOGFILE" 2>/dev/null || echo 0) -gt 10485760 ]]; then
    mv "$LOGFILE" "${LOGFILE}.old"
fi

log "╔══════════════════════════════════════════════════════════════╗"
log "║          PVE Offsite Backup started                        ║"
log "║          Host: ${HOSTNAME}"
log "╚══════════════════════════════════════════════════════════════╝"

#--- Preflight checks ---
log "▶ Preflight checks..."

[[ -f "$ENCRYPTION_KEYFILE" ]] || error_exit "Encryption keyfile not found: $ENCRYPTION_KEYFILE
Create it with: echo 'YOUR_PASSWORD' > $ENCRYPTION_KEYFILE && chmod 600 $ENCRYPTION_KEYFILE"

command -v rclone &>/dev/null || error_exit "rclone not installed (apt install rclone)"
command -v openssl &>/dev/null || error_exit "openssl not installed"
command -v sendmail &>/dev/null || log "  WARNING: sendmail not found, error notifications disabled"

if [[ -n "$NAS_MOUNTPOINT" ]]; then
    mountpoint -q "$NAS_MOUNTPOINT" || error_exit "NAS not mounted: ${NAS_MOUNTPOINT}"
fi

log "  Testing rclone connection..."
RCLONE_REMOTE_BASE=$(echo "$RCLONE_REMOTE" | cut -d: -f1)
rclone lsd "${RCLONE_REMOTE_BASE}:/" &>/dev/null || error_exit "rclone connection failed for remote: ${RCLONE_REMOTE_BASE}"
log "  ✓ All checks passed"

mkdir -p "$BACKUP_DIR"

#--- Step 1: vzdump all VMs/CTs ---
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "▶ Step 1/4: vzdump - Backup all VMs/CTs"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

VMIDS=$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tr '\n' ' ')
CTIDS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tr '\n' ' ')
ALLIDS=$(echo "${VMIDS}${CTIDS}" | xargs)

[[ -n "$ALLIDS" ]] || error_exit "No VMs or containers found!"

VM_COUNT=$(echo "$ALLIDS" | wc -w)
log "  Found: ${VM_COUNT} VMs/CTs (IDs: ${ALLIDS})"

CURRENT_VM=0
VZDUMP_ERRORS=0

for VMID in $ALLIDS; do
    CURRENT_VM=$((CURRENT_VM + 1))

    VM_NAME=$(qm config "$VMID" 2>/dev/null | grep '^name:' | awk '{print $2}' || \
              pct config "$VMID" 2>/dev/null | grep '^hostname:' | awk '{print $2}' || \
              echo "unknown")

    show_progress $CURRENT_VM $VM_COUNT "  vzdump"
    log "  → Backing up VM ${VMID} (${VM_NAME})..."

    DUMP_START=$(date +%s)

    if vzdump "$VMID" \
        --dumpdir "$BACKUP_DIR" \
        --compress zstd \
        --mode snapshot \
        --quiet 1 \
        2>&1 | tee -a "$LOGFILE"; then
        DUMP_END=$(date +%s)
        DUMP_SECS=$(( DUMP_END - DUMP_START ))
        log "  ✓ VM ${VMID} (${VM_NAME}) done (${DUMP_SECS}s)"
    else
        log "  ✗ VM ${VMID} (${VM_NAME}) FAILED"
        VZDUMP_ERRORS=$((VZDUMP_ERRORS + 1))
    fi
done

if [[ $VZDUMP_ERRORS -gt 0 ]]; then
    error_exit "vzdump failed for ${VZDUMP_ERRORS} of ${VM_COUNT} VM(s)"
fi

log "  ✓ All ${VM_COUNT} VMs backed up successfully"

#--- Step 2: Encryption ---
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "▶ Step 2/4: AES-256 Encryption"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BACKUP_FILES=()
for f in "$BACKUP_DIR"/vzdump-*; do
    [[ -f "$f" ]] && [[ ! "$f" == *.enc ]] && [[ ! "$f" == *.log ]] && BACKUP_FILES+=("$f")
done

TOTAL_FILES=${#BACKUP_FILES[@]}
CURRENT_FILE=0
TOTAL_SIZE_BEFORE=0

for BACKUP_FILE in "${BACKUP_FILES[@]}"; do
    CURRENT_FILE=$((CURRENT_FILE + 1))
    FILENAME=$(basename "$BACKUP_FILE")
    FILESIZE=$(du -h "$BACKUP_FILE" | awk '{print $1}')
    FILESIZE_BYTES=$(stat --format="%s" "$BACKUP_FILE")
    TOTAL_SIZE_BEFORE=$((TOTAL_SIZE_BEFORE + FILESIZE_BYTES))

    show_progress $CURRENT_FILE $TOTAL_FILES "  Encryption"
    log "  → ${FILENAME} (${FILESIZE})..."

    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -in "$BACKUP_FILE" \
        -out "${BACKUP_FILE}.enc" \
        -pass "file:${ENCRYPTION_KEYFILE}" || error_exit "Encryption failed: ${FILENAME}"

    rm -f "$BACKUP_FILE"
    log "  ✓ Encrypted"
done

TOTAL_SIZE_GB=$(echo "scale=2; $TOTAL_SIZE_BEFORE / 1073741824" | bc 2>/dev/null || echo "?")
log "  ✓ ${TOTAL_FILES} files encrypted (${TOTAL_SIZE_GB} GiB)"

#--- Step 3: Upload ---
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "▶ Step 3/4: Upload via rclone (${RCLONE_TRANSFERS} streams)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M')
RCLONE_TARGET="${RCLONE_REMOTE}/${TIMESTAMP}"

log "  Target: ${RCLONE_TARGET}"
log "  Uploading... (progress every 60s in log)"

UPLOAD_START=$(date +%s)

rclone copy "$BACKUP_DIR/" "$RCLONE_TARGET/" \
    --transfers=$RCLONE_TRANSFERS \
    --stats=60s \
    --stats-log-level=NOTICE \
    --stats-one-line \
    --log-file="$LOGFILE" \
    --log-level=NOTICE \
    --exclude="*.log"

RCLONE_EXIT=$?

UPLOAD_END=$(date +%s)
UPLOAD_DURATION=$(( UPLOAD_END - UPLOAD_START ))
UPLOAD_HOURS=$(( UPLOAD_DURATION / 3600 ))
UPLOAD_MINUTES=$(( (UPLOAD_DURATION % 3600) / 60 ))
UPLOAD_SECONDS=$(( UPLOAD_DURATION % 60 ))

if [[ $RCLONE_EXIT -ne 0 ]]; then
    error_exit "rclone upload failed (exit: $RCLONE_EXIT) after ${UPLOAD_HOURS}h ${UPLOAD_MINUTES}m"
fi

log "  ✓ Upload completed in ${UPLOAD_HOURS}h ${UPLOAD_MINUTES}m ${UPLOAD_SECONDS}s"

#--- Step 4: GFS Retention ---
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "▶ Step 4/4: GFS Retention (${GFS_DAILY}D / ${GFS_WEEKLY}W / ${GFS_MONTHLY}M)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DELETED_COUNT=0
KEPT_COUNT=0

BACKUP_DIRS=()
while IFS= read -r DIR; do
    DIR_DATE=$(echo "$DIR" | grep -oP '^\d{4}-\d{2}-\d{2}' || true)
    [[ -n "$DIR_DATE" ]] && BACKUP_DIRS+=("$DIR")
done < <(rclone lsd "$RCLONE_REMOTE/" 2>/dev/null | awk '{print $NF}' | sort -r)

TOTAL_BACKUPS=${#BACKUP_DIRS[@]}
log "  Found: ${TOTAL_BACKUPS} backups on remote"

DAILY_KEPT=0
WEEKLY_KEPT=0
MONTHLY_KEPT=0

DAILY_CUTOFF=$(date -d "-${GFS_DAILY} days" '+%Y-%m-%d')
WEEKLY_CUTOFF=$(date -d "-$((GFS_WEEKLY * 7)) days" '+%Y-%m-%d')
MONTHLY_CUTOFF=$(date -d "-${GFS_MONTHLY} months" '+%Y-%m-%d')

declare -A KEEP_DIRS

for DIR in "${BACKUP_DIRS[@]}"; do
    DIR_DATE=$(echo "$DIR" | grep -oP '^\d{4}-\d{2}-\d{2}')
    DIR_DOW=$(date -d "$DIR_DATE" '+%w' 2>/dev/null || echo "-1")
    DIR_DOM=$(date -d "$DIR_DATE" '+%d' 2>/dev/null | sed 's/^0//' || echo "0")

    KEEP=false
    REASON=""

    # Son: daily backups
    if [[ "$DIR_DATE" > "$DAILY_CUTOFF" || "$DIR_DATE" == "$DAILY_CUTOFF" ]] && [[ $DAILY_KEPT -lt $GFS_DAILY ]]; then
        KEEP=true
        REASON="Son (daily)"
        DAILY_KEPT=$((DAILY_KEPT + 1))
    fi

    # Father: weekly backups
    if [[ "$DIR_DOW" == "$GFS_WEEKLY_DOW" ]] && \
       [[ "$DIR_DATE" > "$WEEKLY_CUTOFF" || "$DIR_DATE" == "$WEEKLY_CUTOFF" ]] && \
       [[ $WEEKLY_KEPT -lt $GFS_WEEKLY ]]; then
        KEEP=true
        REASON="Father (weekly)"
        WEEKLY_KEPT=$((WEEKLY_KEPT + 1))
    fi

    # Grandfather: monthly backups
    if [[ "$DIR_DOM" == "$GFS_MONTHLY_DOM" ]] && \
       [[ "$DIR_DATE" > "$MONTHLY_CUTOFF" || "$DIR_DATE" == "$MONTHLY_CUTOFF" ]] && \
       [[ $MONTHLY_KEPT -lt $GFS_MONTHLY ]]; then
        KEEP=true
        REASON="Grandfather (monthly)"
        MONTHLY_KEPT=$((MONTHLY_KEPT + 1))
    fi

    if $KEEP; then
        KEEP_DIRS["$DIR"]=1
        KEPT_COUNT=$((KEPT_COUNT + 1))
        log "  ✓ Keep: ${DIR} [${REASON}]"
    fi
done

for DIR in "${BACKUP_DIRS[@]}"; do
    if [[ -z "${KEEP_DIRS[$DIR]+x}" ]]; then
        log "  → Delete: ${DIR}"
        if rclone purge "${RCLONE_REMOTE}/${DIR}/" 2>&1 | tee -a "$LOGFILE"; then
            DELETED_COUNT=$((DELETED_COUNT + 1))
        fi
    fi
done

log "  ✓ GFS Retention: ${KEPT_COUNT} kept, ${DELETED_COUNT} deleted"
log "    Son: ${DAILY_KEPT}/${GFS_DAILY} | Father: ${WEEKLY_KEPT}/${GFS_WEEKLY} | Grandfather: ${MONTHLY_KEPT}/${GFS_MONTHLY}"

# Cleanup intermediate storage
log "  Cleaning up intermediate storage..."
rm -rf "${BACKUP_DIR:?}/"* 2>/dev/null || true
log "  ✓ Cleaned up"

#--- Summary ---
SCRIPT_END=$(date +%s)
TOTAL_DURATION=$(( SCRIPT_END - SCRIPT_START ))
TOTAL_HOURS=$(( TOTAL_DURATION / 3600 ))
TOTAL_MINUTES=$(( (TOTAL_DURATION % 3600) / 60 ))

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║          ✓ BACKUP SUCCESSFUL                               ║"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  VMs/CTs:    ${VM_COUNT} backed up"
log "║  Size:       ${TOTAL_SIZE_GB} GiB"
log "║  Target:     ${TIMESTAMP}"
log "║  Upload:     ${UPLOAD_HOURS}h ${UPLOAD_MINUTES}m ${UPLOAD_SECONDS}s"
log "║  Total:      ${TOTAL_HOURS}h ${TOTAL_MINUTES}m"
log "╚══════════════════════════════════════════════════════════════╝"

exit 0

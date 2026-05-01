#!/bin/bash
set -euo pipefail

# =========================
# CONFIG
# =========================

LAB_HOST="labpull@proxmox.home.arpa"

REMOTE_EXPORT="/mnt/vm-share/export"
REMOTE_MANIFESTS="$REMOTE_EXPORT/manifests"

LOCAL_MEDIA="$HOME/media"
LOCAL_MOVIES="$LOCAL_MEDIA/movies"
LOCAL_SHOWS="$LOCAL_MEDIA/shows"

LOCAL_STATE="$HOME/.lab-pull-state"
DONE_FILE="$LOCAL_STATE/done.log"

SSH_KEY="$HOME/.ssh/labpull_id"
SSH_OPTS="-i $SSH_KEY -o Compression=no -o StrictHostKeyChecking=accept-new"

mkdir -p "$LOCAL_MOVIES" "$LOCAL_SHOWS" "$LOCAL_STATE"

# =========================
# LOCK
# =========================

#implement full queue/worker later if throughput increases

LOCKFILE="/var/lock/lab-pull.lock"

exec 9>>"$LOCKFILE"

echo "[$$] waiting for lock on $LOCKFILE..."
flock 9
echo "[$$] acquired lock"

# =========================
# HELPERS
# =========================

has_run() {
    grep -q "$1" "$DONE_FILE" 2>/dev/null
}

mark_done() {
    echo "$1" >> "$DONE_FILE"
}

log() {
    echo "[$(date -Iseconds)] $*"
}

# =========================
# VERIFY FUNCTION (lightweight)
# =========================

verify_files() {
    local dir="$1"

    find "$dir" -type f -print0 | while IFS= read -r -d '' f; do
        sha256sum "$f" >/dev/null 2>&1
    done
}

# =========================
# PROCESS JOB
# =========================

process_job() {
    local job_id="$1"
    local type="$2"

    if has_run "$job_id"; then
        log "Skipping $job_id (already processed)"
        return
    fi

    if [[ "$type" == "movies" ]]; then
        LOCAL_DIR="$LOCAL_MOVIES/$job_id"
    else
        LOCAL_DIR="$LOCAL_SHOWS/$job_id"
    fi

    if [[ ! -d "$LOCAL_DIR" ]]; then
        log "Missing local directory for $job_id"
        return
    fi

    log "Processing job $job_id ($type)"

    # lightweight integrity pass
    verify_files "$LOCAL_DIR"

    mark_done "$job_id"

    log "Completed job $job_id"
}

# =========================
# FETCH MANIFESTS
# =========================

log "Fetching manifests..."

MANIFESTS=$(ssh $SSH_OPTS "$LAB_HOST" "ls -1 $REMOTE_MANIFESTS 2>/dev/null || true")

for m in $MANIFESTS; do
    job_id=$(ssh $SSH_OPTS "$LAB_HOST" "jq -r '.job_id' $REMOTE_MANIFESTS/$m")
    type=$(ssh $SSH_OPTS "$LAB_HOST" "jq -r '.type' $REMOTE_MANIFESTS/$m")

    if [[ -z "$job_id" || "$job_id" == "null" ]]; then
        log "Skipping invalid manifest $m"
        continue
    fi

    process_job "$job_id" "$type"
done

log "Lab pull complete"
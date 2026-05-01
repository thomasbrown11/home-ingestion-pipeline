#SAVE THIS TO /usr/local/bin/ingestion-host.sh

# #!/bin/bash
#!/usr/bin/env bash

# error logs in early stages before transID is defined will make new log files in same log directory for easy debug

# exit on error
# undefined variables = error
# properly fail on early pipe process failure
set -euo pipefail

# =========================
# INPUT (BOUNDARY)
# =========================

# grab $1 or set to ""
BUNDLE_PATH="${1:-}"

# if no argument provided > invalid invocation 
[[ -n "$BUNDLE_PATH" ]] || { echo "usage: $0 <bundle_path>"; exit 1; }

# not a directory > not a valid bundle event, ignore
[[ -d "$BUNDLE_PATH" ]] || { echo "not a directory: $BUNDLE_PATH"; exit 0; }

# =========================
# DEPENDENCIES
# =========================

for cmd in jq sha256sum find flock; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "FATAL: missing $cmd" >&2
        exit 1
    }
done

# =========================
# LOCK (one bundle at a time)
# =========================

LOCKFILE="${LOCKFILE:-/var/lock/ingestion-host.lock}"
exec 9>>"$LOCKFILE"
echo "[$$] waiting for lock on $LOCKFILE..."
flock 9
echo "[$$] acquired lock"

# =========================
# CONFIG
# =========================

# short hostname for logging
MACHINE="$(hostname -s)"

# vm side manifest location for hash correlation/ transID retrieval 
INCOMING="${INCOMING:-/mnt/vm-share/incoming/ready}"
REGISTRY_DIR="${REGISTRY_DIR:-$INCOMING/registry}"

# export directory for NAS consumption 
EXPORT_DIR="${EXPORT_DIR:-/mnt/vm-share/export}"
EXPORT_MOVIES="$EXPORT_DIR/movies"
EXPORT_SHOWS="$EXPORT_DIR/shows"
EXPORT_MANIFESTS="$EXPORT_DIR/manifests"

# consumed manifests on completed jobs
PROCESSED_DIR="${PROCESSED_DIR:-$REGISTRY_DIR/processed}"

# host side pipe log 
LOG_FILE="${LOG_FILE:-/var/log/promotion.log}"

mkdir -p "$EXPORT_MOVIES" "$EXPORT_SHOWS" "$EXPORT_MANIFESTS" "$PROCESSED_DIR"

# =========================
# LOGGING DEFAULT STATE
# =========================

TRANS_ID="pending"
BUNDLE_NAME="unknown"
SRC="$BUNDLE_PATH"
DEST=""
STAGE="promote"
ACTION="init"
STATUS="running"

# =========================
# LOG
# =========================

# correct logger from vm
log() {
    local msg
    msg=$(jq -Rs . <<< "${1:-}")

    printf '{"ts":"%s","tx":"%s","name":"%s","machine":"%s","action":"%s","status":"%s","stage":"%s","src":"%s","dest":"%s","msg":%s}\n' \
        "$(date -Iseconds)" \
        "${TRANS_ID:-none}" \
        "${BUNDLE_NAME:-none}" \
        "$MACHINE" \
        "${ACTION:-none}" \
        "${STATUS:-none}" \
        "${STAGE:-none}" \
        "${SRC:-}" \
        "${DEST:-}" \
        "$msg" >> "$LOG_FILE"
}

fail() {
    ACTION="${ACTION:-fatal}"
    STATUS="error"
    log "$1"
    echo "FATAL: $1" >&2
    exit 1
}

# =========================
# CLASSIFY BUNDLE TYPE
# =========================

STAGE="promote"
ACTION="identify"
STATUS="running"

case "$BUNDLE_PATH" in
    "$INCOMING/movies/"*)
        TYPE="movies"
        DEST_ROOT="$EXPORT_MOVIES"
        ;;
    "$INCOMING/shows/"*)
        TYPE="shows"
        DEST_ROOT="$EXPORT_SHOWS"
        ;;
    *)
        ACTION="ignore"
        STATUS="skipped"
        STAGE="promote"
        log "non-media path ignored"
        exit 0
        ;;
esac

# =========================
# BUILD HASH SET FROM BUNDLE
# =========================

# create empty associative array (hash map)
declare -A BUNDLE_HASHES

# safely loop over find $BUNDLE_PATH output using null delimiting (vs newline)
# hash files only. ignore directory structure 
# -print0 will output like file1\0file2\0file3\0
while IFS= read -r -d '' file; do

    # generate hash per file and grab only hash from sha256sum output
    # find error with journalctl -u ingestion-host-watch.service
    h=$(sha256sum "$file" | awk '{print $1}') || {
        ACTION="hash"
        STATUS="error"
        log "hash failure"
        exit 1
    }

    # literally append something like BUNDLE_HASHES["a1b2c3"]=1.. every value is 1, but each hash exists for 
    BUNDLE_HASHES["$h"]=1

done < <(find "$BUNDLE_PATH" -type f -print0)

#exit without an error (just nothing to process) if empty bundle
[[ "${#BUNDLE_HASHES[@]}" -gt 0 ]] || {
    
    STATUS="error"
    STAGE="promote"
    ACTION="hash"

    log "empty bundle"
    exit 0
}

# =========================
# MATCH MANIFEST (HASH ONLY CORRELATION)
# =========================

# manifest with matching hashes to current bundle hashes
MATCHED_MANIFEST=""

# loop all manifests in vm/host shared registry 
# check if all hashes in current manifest are in the current bundle's hostside hashmap 
for manifest in "$REGISTRY_DIR"/*.json; do

    # if file doesn't exist then skip (glob edge case handler where "$REGISTRY_DIR"/*.json is parsed if no manifest files present)
    [[ -e "$manifest" ]] || continue

    # skip if files isn't valid JSON
    jq empty "$manifest" >/dev/null 2>&1 || continue

    # create HASHES array, strip new lines and extract all hashes from manifest
    mapfile -t HASHES < <(jq -r '.files[].hash' "$manifest") || continue

    #assume file matches until disproven 
    match=1

    # loop each hash in manifest
    for h in "${HASHES[@]}"; do
        # if hash is NOT in the current bundle's hashmap fail and break outer loop iteration
        [[ -n "${BUNDLE_HASHES[$h]:-}" ]] || { match=0; break; }
    done

    # if preceeding loop never broke test save manifest to MATCHED_MANIFEST and break
    if [[ "$match" -eq 1 ]]; then
        MATCHED_MANIFEST="$manifest"
        break
    fi
done

# if no matches log and exit
[[ -n "$MATCHED_MANIFEST" ]] || {
    ACTION="match"
    STATUS="unmatched"
    log "no matching manifest"
    exit 0
}

# =========================
# RESOLVE IDENTITY
# =========================

# pull manifest .job_id for host side logging
JOB_ID=$(jq -r '.job_id' "$MATCHED_MANIFEST") || fail "invalid manifest json"

# pull original bundle_name from vm manifest for host side logging
BUNDLE_NAME=$(jq -r '.name // empty' "$MATCHED_MANIFEST")

# fail if missing job_id
[[ -n "$JOB_ID" && "$JOB_ID" != "null" ]] || fail "invalid job_id"

TRANS_ID="$JOB_ID"
SRC="$BUNDLE_PATH"
DEST="$DEST_ROOT/$JOB_ID"

# authoritative idempotency check 
if [[ -f "$PROCESSED_DIR/${JOB_ID}.done" ]]; then
    ACTION="promote"
    STATUS="skipped"
    log "job already processed"
    exit 0
fi

if [[ -d "$DEST" ]]; then
    ACTION="promote"
    STATUS="exists"
    log "already exported"
    exit 0
fi

STAGE="promote"
ACTION="resolve"
STATUS="success"
log "manifest matched; job resolved"

# =========================
# EXPORT
# =========================

STAGE="export"
ACTION="move"
STATUS="running"

log "export started"

mkdir -p "$DEST" || fail "mkdir failed"

# move to export/movies|shows/[transId]/bundle 
mv "$BUNDLE_PATH" "$DEST/" || fail "move failed"

# COPY the manifest to export for similar nas-side consumption 
cp "$MATCHED_MANIFEST" "$EXPORT_MANIFESTS/$JOB_ID.json" \
    || fail "manifest export failed"

# move current manifest to the processed directory to prevent rerunning. 
mv "$MATCHED_MANIFEST" "$PROCESSED_DIR/${JOB_ID}.done" \
    || fail "manifest finalize failed"

STATUS="success"
log "export complete"

exit 0

### HERE IS SYSTEMD HANDLING OUTSIDE OF THE SCRIPT: ###

#mini watcher script (because ingestion-host.sh expects a filepath as an arg):
#SAVE THIS TO /usr/local/bin/ingestion-watch.sh

#!/bin/bash

# INCOMING="/mnt/vm-share/incoming/ready"

# inotifywait -m -e moved_to --format '%w%f' \
#     "$INCOMING/movies" \
#     "$INCOMING/shows" |
# while read -r path; do
#     # only process directories
#     [[ -d "$path" ]] || continue

#     /usr/local/bin/ingestion-host.sh "$path"
# done

# exit 0

#now add a systemd service
#save to: /etc/systemd/system/ingestion-host-watch.service

# [Unit]
# Description=Media ingestion watcher
# After=network.target

# [Service]
# ExecStart=/usr/local/bin/ingestion-host-watch.sh
# Restart=always
# RestartSec=2

# # Explicitly run as root (optional, but clear)
# User=root

# # Optional but recommended
# WorkingDirectory=/

# # Better logging behavior
# StandardOutput=journal
# StandardError=journal

# [Install]
# WantedBy=multi-user.target

# #################
# #run:
# sudo chmod +x /usr/local/bin/ingestion-host-watch.sh
# sudo systemctl daemon-reexec
# sudo systemctl daemon-reload
# sudo systemctl enable ingestion-host-watch.service
# sudo systemctl start ingestion-host-watch.service
# #check status:
# sudo systemctl status ingestion-host-watch.service #must say active
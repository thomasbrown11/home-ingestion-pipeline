# #!/bin/bash
# set -euo pipefail

# # =========================
# # DEPENDENCIES
# # =========================

# for cmd in jq flock sha256sum find rsync; do
#     command -v "$cmd" >/dev/null 2>&1 || {
#         echo "FATAL: missing $cmd" >&2
#         exit 1
#     }
# done

# # =========================
# # SINGLE INSTANCE LOCK
# # =========================

# #implement full queue/worker later if throughput increases

# LOCKFILE="/var/lock/ingestion-host.lock"

# exec 9>>"$LOCKFILE"

# echo "[$$] waiting for lock on $LOCKFILE..."
# flock 9
# echo "[$$] acquired lock"

# # =========================
# # CONFIG (ONLY VIEWABLE AREA)
# # =========================

# INCOMING="/mnt/vm-share/incoming/ready"

# MOVIES_DIR="$INCOMING/movies"
# SHOWS_DIR="$INCOMING/shows"
# REGISTRY_DIR="$INCOMING/registry"

# EXPORT_DIR="/mnt/vm-share/export"
# EXPORT_MOVIES="$EXPORT_DIR/movies"
# EXPORT_SHOWS="$EXPORT_DIR/shows"
# EXPORT_MANIFESTS="$EXPORT_DIR/manifests"

# PROCESSED_DIR="$REGISTRY_DIR/processed"
# LOG_FILE="/var/log/promotion.log"

# mkdir -p "$EXPORT_MOVIES" "$EXPORT_SHOWS" "$EXPORT_MANIFESTS" "$PROCESSED_DIR"

# # =========================
# # LOG
# # =========================

# log() {
#     local msg
#     msg=$(jq -Rs . <<< "${1:-}")

#     printf '{"ts":"%s","job":"%s","action":"%s","status":"%s","type":"%s","msg":%s}\n' \
#         "$(date -Iseconds)" \
#         "${JOB_ID:-none}" \
#         "${ACTION:-none}" \
#         "${STATUS:-none}" \
#         "${TYPE:-none}" \
#         "$msg" >> "$LOG_FILE"
# }

# # =========================
# # BUILD HASH INDEX (CRITICAL STEP)
# # =========================

# build_hash_index() {
#     local base_dir="$1"

#     declare -A HASH_MAP

#     while IFS= read -r -d '' file; do
#         hash=$(sha256sum "$file" | awk '{print $1}')
#         HASH_MAP["$hash"]="$file"
#     done < <(find "$base_dir" -type f -print0)

#     echo "$(declare -p HASH_MAP)"
# }

# # =========================
# # PROCESS MANIFEST
# # =========================

# process_manifest() {
#     local manifest="$1"

#     [[ -f "$manifest" ]] || return 0

#     if ! jq empty "$manifest" >/dev/null 2>&1; then
#         ACTION="parse"
#         STATUS="error"
#         log "invalid JSON"
#         mv "$manifest" "$PROCESSED_DIR/bad_$(basename "$manifest")"
#         return 0
#     fi

#     JOB_ID=$(jq -r '.job_id' "$manifest")
#     TYPE=$(jq -r '.type' "$manifest")

#     if [[ -z "$JOB_ID" || "$JOB_ID" == "null" ]]; then
#         ACTION="parse"
#         STATUS="error"
#         log "invalid manifest"
#         mv "$manifest" "$PROCESSED_DIR/bad_$(basename "$manifest")"
#         return 0
#     fi

#     log "processing manifest"

#     # pick source directory
#     if [[ "$TYPE" == "movies" ]]; then
#         SEARCH_DIR="$MOVIES_DIR"
#         DEST="$EXPORT_MOVIES/$JOB_ID"
#     else
#         SEARCH_DIR="$SHOWS_DIR"
#         DEST="$EXPORT_SHOWS/$JOB_ID"
#     fi

#     # =========================
#     # LOAD MANIFEST HASHES
#     # =========================

#     mapfile -t EXPECTED_HASHES < <(jq -r '.files[].hash' "$manifest")

#     if [[ "${#EXPECTED_HASHES[@]}" -eq 0 ]]; then
#         ACTION="validate"
#         STATUS="error"
#         log "manifest has no hashes"
#         mv "$manifest" "$PROCESSED_DIR/empty_${JOB_ID}.json"
#         return 0
#     fi

#     # =========================
#     # BUILD CURRENT HASH INDEX
#     # =========================

#     declare -A FOUND_MAP

#     while IFS= read -r -d '' file; do
#         h=$(sha256sum "$file" | awk '{print $1}')
#         FOUND_MAP["$h"]="$file"
#     done < <(find "$SEARCH_DIR" -type f -print0)

#     # =========================
#     # MATCH FILES
#     # =========================

#     MATCHED_DIR="/tmp/match_$JOB_ID"
#     rm -rf "$MATCHED_DIR"
#     mkdir -p "$MATCHED_DIR"

#     missing=0

#     for h in "${EXPECTED_HASHES[@]}"; do
#         if [[ -n "${FOUND_MAP[$h]:-}" ]]; then
#             cp --parents "${FOUND_MAP[$h]}" "$MATCHED_DIR"
#         else
#             log "missing hash: $h"
#             missing=1
#         fi
#     done

#     if [[ "$missing" -eq 1 ]]; then
#         ACTION="validate"
#         STATUS="incomplete"
#         log "partial match - skipping promotion"
#         return 0
#     fi

#     # =========================
#     # PROMOTE
#     # =========================

#     ACTION="move"
#     STATUS="running"

#     mkdir -p "$DEST"

#     mv "$MATCHED_DIR"/* "$DEST/"

#     cp "$manifest" "$EXPORT_MANIFESTS/$JOB_ID.json"
#     mv "$manifest" "$PROCESSED_DIR/${JOB_ID}.done"

#     STATUS="success"
#     log "promotion complete"
# }

# # =========================
# # STARTUP
# # =========================

# ACTION="startup"
# STATUS="running"
# log "host promotion service starting"

# # =========================
# # BACKLOG
# # =========================

# for m in "$REGISTRY_DIR"/*.json; do
#     [[ -e "$m" ]] || continue
#     process_manifest "$m"
# done

# # =========================
# # WATCH
# # =========================

# inotifywait -m -e moved_to --format '%w%f' "$REGISTRY_DIR" | while read -r manifest; do
#     process_manifest "$manifest"
# done

#################EDITED FOR BETTER FAILURE HANDLING#################EDITED FOR BETTER FAILURE HANDLING#################EDITED FOR BETTER FAILURE HANDLING#################EDITED FOR BETTER FAILURE HANDLING
#SAVE THIS TO /usr/local/bin/ingestion-host.sh

#!/bin/bash
set -euo pipefail

# =========================
# INPUT (BOUNDARY)
# =========================

BUNDLE_PATH="${1:-}"
[[ -n "$BUNDLE_PATH" ]] || { echo "usage: $0 <bundle_path>"; exit 1; }
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

LOCKFILE="/var/lock/ingestion-host.lock"
exec 9>>"$LOCKFILE"
flock 9

# =========================
# CONFIG
# =========================

INCOMING="/mnt/vm-share/incoming/ready"
REGISTRY_DIR="$INCOMING/registry"

EXPORT_DIR="/mnt/vm-share/export"
EXPORT_MOVIES="$EXPORT_DIR/movies"
EXPORT_SHOWS="$EXPORT_DIR/shows"
EXPORT_MANIFESTS="$EXPORT_DIR/manifests"

PROCESSED_DIR="$REGISTRY_DIR/processed"
LOG_FILE="/var/log/promotion.log"

mkdir -p "$EXPORT_MOVIES" "$EXPORT_SHOWS" "$EXPORT_MANIFESTS" "$PROCESSED_DIR"

# =========================
# LOG
# =========================

log() {
    local msg
    msg=$(jq -Rs . <<< "${1:-}")

    printf '{"ts":"%s","job":"%s","action":"%s","status":"%s","msg":%s}\n' \
        "$(date -Iseconds)" \
        "${JOB_ID:-none}" \
        "${ACTION:-none}" \
        "${STATUS:-none}" \
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
# DETERMINE TYPE
# =========================

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
        log "ignoring non-media path: $BUNDLE_PATH"
        exit 0
        ;;
esac

ACTION="identify"
STATUS="running"
log "processing bundle"

# =========================
# HASH BUNDLE
# =========================

declare -A BUNDLE_HASHES

while IFS= read -r -d '' file; do
    h=$(sha256sum "$file" | awk '{print $1}') || fail "hash failed"
    BUNDLE_HASHES["$h"]=1
done < <(find "$BUNDLE_PATH" -type f -print0)

[[ "${#BUNDLE_HASHES[@]}" -gt 0 ]] || {
    STATUS="error"
    log "empty bundle"
    exit 0
}

# =========================
# FIND MATCHING MANIFEST
# =========================

ACTION="match"
STATUS="running"

MATCHED_MANIFEST=""

for manifest in "$REGISTRY_DIR"/*.json; do
    [[ -e "$manifest" ]] || continue

    if ! jq empty "$manifest" >/dev/null 2>&1; then
        log "skipping invalid JSON: $manifest"
        continue
    fi

    mapfile -t HASHES < <(jq -r '.files[].hash' "$manifest") || continue

    match=1
    for h in "${HASHES[@]}"; do
        [[ -n "${BUNDLE_HASHES[$h]:-}" ]] || {
            match=0
            break
        }
    done

    if [[ "$match" -eq 1 ]]; then
        MATCHED_MANIFEST="$manifest"
        break
    fi
done

[[ -n "$MATCHED_MANIFEST" ]] || {
    STATUS="unmatched"
    log "no matching manifest"
    exit 0
}

# =========================
# EXTRACT JOB ID
# =========================

JOB_ID=$(jq -r '.job_id' "$MATCHED_MANIFEST") || fail "jq failed"

[[ -n "$JOB_ID" && "$JOB_ID" != "null" ]] || fail "invalid job_id"

# idempotency check
DEST="$DEST_ROOT/$JOB_ID"
if [[ -d "$DEST" ]]; then
    STATUS="exists"
    log "already promoted, skipping"
    exit 0
fi

# =========================
# PROMOTE
# =========================

ACTION="move"
STATUS="running"

mkdir -p "$DEST" || fail "mkdir failed"

mv "$BUNDLE_PATH"/* "$DEST/" || fail "move failed"

cp "$MATCHED_MANIFEST" "$EXPORT_MANIFESTS/$JOB_ID.json" \
    || fail "manifest export failed"

mv "$MATCHED_MANIFEST" "$PROCESSED_DIR/${JOB_ID}.done" \
    || fail "manifest finalize failed"

STATUS="success"
log "promotion complete"

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
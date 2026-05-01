#!/bin/bash
set -euo pipefail

# =========================
# SINGLE INSTANCE LOCK
# =========================

#implement full queue/worker later if throughput increases

LOCKFILE="/var/lock/ingestion-vm.lock"

exec 9>>"$LOCKFILE"

echo "[$$] waiting for lock on $LOCKFILE..."
flock 9
echo "[$$] acquired lock"

# =========================
# CONFIG
# =========================

# set static environment variables (infra layer)

MACHINE="$(hostname)"

LOG_DIR="/home/tom/logs"
LOG_FILE="$LOG_DIR/ingestion-vm.log"

#re-run logic/idempotency 
STATE_FILE=""

DOWNLOAD_DIR="/home/tom/downloads/complete"
PROCESSING_DIR="/home/tom/processing"
STAGING_DIR="/mnt/host/staging"
QUARANTINE_DIR="/home/tom/quarantine"
REGISTRY_DIR="/mnt/host/ready/registry"

#exclude staging direcotry.. this is an infra contract boundary (staging is virtiofs managed by the host)
mkdir -p "$LOG_DIR" "$PROCESSING_DIR" "$QUARANTINE_DIR" "$REGISTRY_DIR" 

# =========================
# STATE HELPERS 
# =========================

set_state() {
    echo "$1" > "$STATE_FILE"
}

get_state() {
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "none"
}

current_stage() {
    [[ "$(get_state)" == "$1" ]]
}

# =========================
# LOGGING
# =========================

# standardized structured logging: output as JSONL for tool leverage. read current state of shell vars or input default values
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

# handle fatal errors gracefully
fail() {
    log "$1"
    echo "FATAL: $1" >&2
    exit 1
}

#catch unexpected errors
trap '
ACTION=${ACTION:-fatal}
STATUS="error"
SRC=${SRC:-${FILE_PATH:-unknown}}
DEST=${DEST:-unknown}
log "unexpected failure"
exit 1
' ERR

# =========================
# INFRA CONTRACT
# =========================

[[ -d "$DOWNLOAD_DIR" ]] || fail "download mount missing"
[[ -d "$STAGING_DIR" ]]  || fail "staging mount missing"

# =========================
# DEPENDENCIES
# =========================

# search $PATH for required commands, throw away output. fail gracefully if missing
for cmd in clamdscan ffprobe ffmpeg sha256sum jq uuidgen find; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not installed"
done

# check if clamd daemon is running. Fail if not. Strict mode policy (non root context)
pgrep -x clamd >/dev/null 2>&1 || fail "clamd daemon not running"

# =========================
# STRICT MEDIA FILTER
# =========================

# file ends in one of the core media extensions
is_core_media_file() {
    case "$1" in
        *.mkv|*.mp4|*.avi|*.mov|*.m4v|*.ts|*.webm) return 0 ;;
        *) return 1 ;;
    esac
}

# file ends in one of the auxiliary media extensions
is_aux_file() {
    case "$1" in
        *.srt|*.ass|*.vtt) return 0 ;;
        *) return 1 ;;
    esac
}

# =========================
# SAFE MOVE HELPER
# =========================

# fail if destination exits, otherwise move the file. Prevent overwriting existing files.
safe_move() {
    local src="$1"
    local dest="$2"
    [[ -e "$dest" ]] && fail "destination exists: $dest"
    mv "$src" "$dest"
}

# =========================
# ENTRY CONTRACT (CLI BOUNDARY)
# =========================

# validate 3 arguments are provided, $0 = script name
#run on completion like: /path/to/ingestion-vm.sh "%N" "%F" "%I" (literally place this in the run on completion field)
# N ($1) = name, F ($2) = content path, I ($3) = infohash 
[[ $# -eq 3 ]] || fail "usage: $0 <name> <path> <infohash>"

# =========================
# JOB IDENTITY (IMMUTABLE)
# =========================

#use upstream-provided infohash passed to script call as transaction ID
TRANS_ID="$3"

#name for logging 
BUNDLE_NAME="$1"

#strict filepath sourch of truth
ORIG_SRC="$2"
BASENAME=$(basename "$ORIG_SRC")

# =========================
# EXECUTION CONTEXT (MUTABLE)
# =========================

#dynamic, per-job state variables (execution layer)

# working pointer (mutable)
SRC="$ORIG_SRC"

PROC_PATH="$PROCESSING_DIR/$BASENAME"
STAGE_PATH="$STAGING_DIR/$BASENAME"
QUAR_PATH="$QUARANTINE_DIR/$BASENAME"

MANIFEST_PATH="$REGISTRY_DIR/${TRANS_ID}.json"
STATE_FILE="$REGISTRY_DIR/${TRANS_ID}.state"

# =========================
# INPUT VALIDATION
# =========================

[[ -e "$SRC" ]] || fail "input does not exist"
[[ -f "$SRC" || -d "$SRC" ]] || fail "must be file or directory"

# safety check/ preserve data integrity
[[ "$ORIG_SRC" == "$DOWNLOAD_DIR"* ]] || fail "must originate from download directory"

# =========================
# TYPE RESOLUTION (for future iteration)
# =========================

# TYPE RESOLUTION (disabled at ingestion stage)
# Path-based classification is not valid here since all files originate
# from /downloads/complete. This should be revisited at a later stage
# after files are organized into media-specific directories.

# if [[ "$ORIG_SRC" == *"/movies/"* ]]; then
#     TYPE="movies"
# elif [[ "$ORIG_SRC" == *"/shows/"* ]]; then
#     TYPE="shows"
# else
#     TYPE="unknown"
# fi

# =========================
# INGESTION
# =========================

if [[ "$(get_state)" == "ingest" || "$(get_state)" == "none" ]]; then

    set_state "ingest"

    ACTION="ingest"
    STATUS="running"
    STAGE="ingest"
    SRC="$ORIG_SRC"
    DEST="$PROC_PATH"

    log "starting ingestion"

    safe_move "$ORIG_SRC" "$PROC_PATH"

    # normalize file → directory
    #all files should be placed in a directory for consistent processing
    # produces something like /home/tom/processing/filename.mkv.dir/filename.mkv) (ensure deterministic directory naming/ structure)
    if [[ -f "$PROC_PATH" ]]; then
        TMP_DIR="${PROC_PATH}.dir"
        mkdir -p "$TMP_DIR"
        mv "$PROC_PATH" "$TMP_DIR/"
        PROC_PATH="$TMP_DIR"
    fi

    #ingestion output contract (readability/semantic checkpoint)
    #may be able to remove in favor of simply SRC="$PROC_PATH" at next stage 
    FILE_PATH="$PROC_PATH"

    STATUS="success"
    log "ingestion complete"

    set_state "scan"
fi 

# =========================
# SECURITY SCAN
# =========================

if [[ "$(get_state)" == "scan" ]]; then

    ACTION="scan"
    STATUS="running"
    STAGE="security"
    SRC="$FILE_PATH"
    DEST=""

    log "clamav scan started"

    # parallel process clamdscan, quarantine on fail (malware detection/failed scan status)
    if ! clamdscan --multiscan --recursive --fdpass "$FILE_PATH"; then
        STATUS="failed"
        DEST="$QUAR_PATH"

        safe_move "$FILE_PATH" "$QUAR_PATH"
        log "malware detected. Moving to quarantine"
        exit 1
    fi

    STATUS="passed"
    log "clamav scan passed"

    set_state "validate"
fi 

# =========================
# VALIDATION
# =========================

if [[ "$(get_state)" == "validate" ]]; then

    ACTION="validate"
    STATUS="running"
    STAGE="validation"

    log "validation started"

    # map proc directory to FILES array with null delimiter to avoid filename issues with spaces or special characters
    mapfile -d '' -t FILES < <(find "$FILE_PATH" -type f -print0)

    #thoroughly validate media streams on core media files, fail closed ingenestion 
    for f in "${FILES[@]}"; do
        if is_core_media_file "$f"; then

            SRC="$f"
            DEST=""

            log "validating file"

            # silence output/errors. test exit status only
            if ! ffprobe -v error "$f" >/dev/null 2>&1; then
                STATUS="failed"
                DEST="$QUAR_PATH"
                safe_move "$FILE_PATH" "$QUAR_PATH"
                log "ffprobe failed. Moving to quarantine"
                exit 1
            fi

            # silence output/errors. test exit status only
            if ! ffmpeg -v error -i "$f" -f null - >/dev/null 2>&1; then
                STATUS="failed"
                DEST="$QUAR_PATH"
                safe_move "$FILE_PATH" "$QUAR_PATH"
                log "ffmpeg decode failed. Moving to quarantine"
                exit 1
            fi

            continue
        fi

        #keep auxiliary files (subtitles, etc.), don't test
        if is_aux_file "$f"; then
            log "aux file detected (keeping): $f"
            continue
        fi

        # quarantine any non-media files
        STATUS="ignored"
        DEST="$QUAR_PATH"
        log "junk file detected. quarantining: $f"
        safe_move "$f" "$QUAR_PATH"

    done

    DEST=""
    STATUS="passed"
    SRC="$FILE_PATH"
    log "validation passed"

    set_state "manifest"

fi

# =========================
# MANIFEST GENERATION
# =========================

if [[ "$(get_state)" == "manifest" ]]; then

    ACTION="manifest"
    STATUS="running"
    STAGE="metadata"

    log "generating manifest"

    #state rehydrate. repopulate FILES array with junk files removed
    mapfile -d '' -t FILES < <(find "$FILE_PATH" -type f -print0)

    FILES_JSON="[]"

    for f in "${FILES[@]}"; do
        if is_core_media_file "$f"; then
            HASH=$(sha256sum "$f" | awk '{print $1}') #expect output [HASH] [FILENAME].. strip filename
            REL_PATH="${f#$FILE_PATH/}" #/home/tom/processing/filename.mkv.dir/filename.mkv -> filename.mkv. strip bundle root prefix only

            # add file entry to JSON array with format {"name": "<relative path>", "hash": "<sha256 hash>"}
            FILES_JSON=$(jq \
                --arg name "$REL_PATH" \
                --arg hash "$HASH" \
                '. += [{"name":$name,"hash":$hash}]' \
                <<< "$FILES_JSON")
        fi
    done

    #atomic file creation to avoid partial writes
    TMP_MANIFEST="${MANIFEST_PATH}.tmp" 

    #full JSON manifest to temp file
    #type is placeholder for downstream processing on host uptake
    jq -n \
    --arg job "$TRANS_ID" \
    --arg src "$ORIG_SRC" \
    --argjson files "$FILES_JSON" \
    '{
        job_id: $job,
        source: $src,
        type: null,
        files: $files
    }' > "$TMP_MANIFEST"


    if [[ -e "$MANIFEST_PATH" ]]; then
        fail "manifest already exists: $MANIFEST_PATH"
    fi

    mv "$TMP_MANIFEST" "$MANIFEST_PATH"

    STATUS="success"
    log "manifest created"

    set_state "stage"

fi

# =========================
# FINAL HANDOFF
# =========================

if [[ "$(get_state)" == "stage" ]]; then

    ACTION="stage"
    STATUS="running"
    STAGE="export"

    SRC="$FILE_PATH"
    DEST="$STAGE_PATH"

    log "export intent: moving to staging"

    # hard boundary check: ensure mount / destination exists
    if [[ ! -d "$STAGE_PATH" ]]; then
        STATUS="failed"
        log "staging destination unavailable (mount missing or not mounted): $STAGE_PATH"
        exit 1
    fi

    # attempt atomic transfer
    if safe_move "$FILE_PATH" "$STAGE_PATH"; then
        STATUS="success"
        log "handoff complete"
    else
        STATUS="failed"
        log "handoff failed during file transfer"
        exit 1
    fi

fi

exit 0
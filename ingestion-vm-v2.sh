#!/bin/bash
set -euo pipefail

# =========================
# SINGLE INSTANCE LOCK
# =========================

# implement full queue/worker later if throughput increases

# serialized execution lock for os-level queueing. Ensures only one instance of the script runs at a time.
# next job will wait until the current script instance finishes
# single worker low throughput

LOCKFILE="/var/lock/ingestion-vm.lock"

exec 9>"$LOCKFILE"
echo "[$$] waiting for lock on $LOCKFILE..."
flock 9
echo "[$$] acquired lock"

# =========================
# CONFIG
# =========================

# set static environment variables (infra layer)

#short hostname for logging
MACHINE="$(hostname -s)"

# LOG_DIR="/home/tom/logs"
LOG_DIR="/mnt/host/ready/logs"

mkdir -p "$LOG_DIR"

#bootstrap to prevent early failed reading of LOG_FILE
LOG_FILE="/tmp/ingestion-bootstrap.log"

DOWNLOAD_DIR="/home/tom/Downloads/complete"
PROCESSING_DIR="/home/tom/processing"
STAGING_DIR="/mnt/host/staging"
QUARANTINE_DIR="/home/tom/quarantine"
REGISTRY_DIR="/mnt/host/ready/registry"

# exclude staging direcotry.. this is an infra contract boundary (staging is virtiofs managed by the host)
mkdir -p "$LOG_DIR" "$PROCESSING_DIR" "$QUARANTINE_DIR" "$REGISTRY_DIR" 

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

# catch unexpected errors
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
# for cmd in clamdscan ffprobe ffmpeg sha256sum jq uuidgen find; do
#     command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not installed"
# done

for cmd in clamdscan ffprobe ffmpeg sha256sum jq uuidgen find flock pgrep awk; do
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

# fail if destination exists, otherwise move the file. Prevent overwriting existing files.
safe_move() {
    local src="$1"
    local dest="$2"
    [[ -e "$dest" ]] && fail "destination exists: $dest"
    mv "$src" "$dest"
}

# =========================
# RETRY HELPER (retry 3 times with exponential backoff)
# =========================

# for future iteration

# retry() {
#     local n=0
#     local max=3
#     local delay=2

#     until "$@"; do
#         ((n++))
#         if (( n >= max )); then
#             return 1
#         fi
#         sleep $((delay * n))
#     done
# }

# =========================
# ENTRY CONTRACT (CLI BOUNDARY)
# =========================

# validate 3 arguments are provided, $0 = script name
# run on completion like: /path/to/ingestion-vm.sh "%N" "%F" "%I" (literally place this in the run on completion field)
# N ($1) = name, F ($2) = content path, I ($3) = infohash 
[[ $# -eq 3 ]] || fail "usage: $0 <name> <path> <infohash>"

# =========================
# JOB IDENTITY (IMMUTABLE)
# =========================

# use upstream-provided infohash passed to script call as transaction ID
TRANS_ID="$3"

#name for logging 
BUNDLE_NAME="$1"

# strict filepath sourch of truth
ORIG_SRC="$2"
BASENAME=$(basename "$ORIG_SRC")

# per-job logging
LOG_FILE="$LOG_DIR/${TRANS_ID}.log"

# =========================
# STAGE MARKERS (completion validation)
# =========================

INGEST_DONE="$REGISTRY_DIR/${TRANS_ID}.ingest.done"
SCAN_DONE="$REGISTRY_DIR/${TRANS_ID}.scan.done"
VALIDATE_DONE="$REGISTRY_DIR/${TRANS_ID}.validate.done"
MANIFEST_DONE="$REGISTRY_DIR/${TRANS_ID}.manifest.done"
EXPORT_DONE="$REGISTRY_DIR/${TRANS_ID}.export.done"

# =========================
# EXECUTION CONTEXT (MUTABLE)
# =========================

# dynamic, per-job state variables (execution layer)

# working pointer (mutable)
SRC="$ORIG_SRC"

PROC_PATH="$PROCESSING_DIR/$BASENAME"
STAGE_PATH="$STAGING_DIR/$BASENAME"
QUAR_PATH="$QUARANTINE_DIR/$BASENAME"

# for handoff to next computer node 
MANIFEST_PATH="$REGISTRY_DIR/${TRANS_ID}.json"
# for resume state tracking on retries 
STATE_FILE="$REGISTRY_DIR/${TRANS_ID}.state"

# =========================
# STATE HELPERS 
# =========================

set_state() {
    echo "$1" > "$STATE_FILE"
}

get_state() {
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "none"
}

# =========================
# retry filepath rehydration
# =========================
resolve_file_path() {
    if [[ -n "${FILE_PATH:-}" ]]; then
        return 0
    fi

    if [[ -e "$PROC_PATH" ]]; then
        FILE_PATH="$PROC_PATH"
        return 0
    fi

    fail "FILE_PATH is not set and cannot be resolved from PROC_PATH"
}

# =========================
# INPUT VALIDATION
# =========================

# validate input is present
[[ -n "${ORIG_SRC:-}" ]] || fail "missing source path"

# enforce existence only on first run
case "$(get_state)" in
    none|"")
        [[ -e "$ORIG_SRC" ]] || fail "input does not exist"
        ;;
esac

# always enforce safety boundary (critical invariant)
case "$ORIG_SRC" in
    "$DOWNLOAD_DIR"/*) ;;
    *) fail "must originate from download directory" ;;
esac

# =========================
# STAGE FUNCTIONS (Dispatch methods)
# =========================

run_ingest() {

    ACTION="ingest"
    STATUS="running"
    STAGE="ingest"

    SRC="$ORIG_SRC"
    DEST="$PROC_PATH"

    log "starting ingestion"

     # If already done, rehydrate state safely and exit cleanly
    if [[ -f "$INGEST_DONE" ]]; then

        # must exist or pipeline state is corrupted
        [[ -e "$PROC_PATH" ]] || fail "ingest marked done but PROC_PATH missing: $PROC_PATH"

       # normalize pointer deterministically (single invariant)
        if [[ -d "$PROC_PATH" || -f "$PROC_PATH" ]]; then
            FILE_PATH="$PROC_PATH"
        else
            fail "invalid ingestion state: PROC_PATH is neither file nor directory"
        fi

        log "ingestion already complete, skipping"
        return
    fi

    #avoid double move
    if [[ -e "$PROC_PATH" ]]; then
        log "processing path already exists, assuming ingestion previously completed"
    else
        [[ -e "$ORIG_SRC" ]] || fail "source missing and processing path not present"
        safe_move "$ORIG_SRC" "$PROC_PATH"
    fi

    # normalize file → directory
    # all files should be placed in a directory for consistent processing
    # produces something like /home/tom/processing/filename.mkv.dir/filename.mkv) (ensure deterministic directory naming/structure)
    if [[ -f "$PROC_PATH" ]]; then
        TMP_DIR="${PROC_PATH}.dir"
        mkdir -p "$TMP_DIR"
        mv "$PROC_PATH" "$TMP_DIR/" || fail "failed to normalize to directory"
        PROC_PATH="$TMP_DIR"
    fi

    [[ -e "$PROC_PATH" ]] || fail "invalid ingestion state: PROC_PATH is missing"

    # ingestion output contract (readability/semantic checkpoint)
    FILE_PATH="$PROC_PATH"

    STATUS="success"
    log "ingestion complete"

    # mark complete for ingestion stage  
    touch "$INGEST_DONE"
}

run_scan() {
    ACTION="scan"
    STATUS="running"
    STAGE="security"
    SRC="$FILE_PATH"
    DEST=""

    # skip if done
    if [[ -f "$SCAN_DONE" ]]; then
        [[ -e "$FILE_PATH" ]] || fail "scan marked done but file missing"
        log "scan already complete, skipping"
        return
    fi

    log "clamav scan started"

    # parallel process clamdscan, quarantine on fail (malware detection/failed scan status)
    if ! clamdscan --multiscan --recursive --fdpass "$FILE_PATH"; then
        STATUS="failed"
        DEST="$QUAR_PATH"

        safe_move "$FILE_PATH" "$QUAR_PATH" || fail "quarantine move failed"
        log "malware detected. moving to quarantine"
        exit 1
    fi

    STATUS="passed"
    log "clamav scan passed"
    
    #mark complete for scan stage
    touch "$SCAN_DONE"
}

run_validate() {
    ACTION="validate"
    STATUS="running"
    STAGE="validation"

    # skip if done
    if [[ -f "$VALIDATE_DONE" ]]; then
        [[ -e "$FILE_PATH" ]] || fail "validate marked done but file missing"
        log "validation already complete, skipping"
        return
    fi

    log "validation started"

    # map proc directory to FILES array with null delimiter to avoid filename issues with spaces or special characters
    mapfile -d '' -t FILES < <(find "$FILE_PATH" -type f -print0)

    # init junk files array
    JUNK_FILES=()

    # thoroughly validate media streams on core media files, fail closed ingestion
    for f in "${FILES[@]}"; do
        if is_core_media_file "$f"; then

            SRC="$f"
            DEST=""

            log "validating file"

            # silence output/errors. test exit status only
            if ! ffprobe -v error "$f" >/dev/null 2>&1; then
                STATUS="failed"
                DEST="$QUAR_PATH"
                safe_move "$FILE_PATH" "$QUAR_PATH" || fail "quarantine move failed"
                log "ffprobe failed. Moving to quarantine"
                exit 1
            fi

            # silence output/errors. test exit status only
            if ! ffmpeg -v error -i "$f" -f null - >/dev/null 2>&1; then
                STATUS="failed"
                DEST="$QUAR_PATH"
                safe_move "$FILE_PATH" "$QUAR_PATH" || fail "quarantine move failed"
                log "ffmpeg decode failed. Moving to quarantine"
                exit 1
            fi

            continue
        fi

        #keep auxiliary files (subtitles, etc.), don't test
        if is_aux_file "$f"; then
            log "aux file kept: $f"
            continue
        fi

        # none core media files or auxiliary files added to junk array
        JUNK_FILES+=("$f")
    done

    # loop through junk files and move them to quarantine
    if (( ${#JUNK_FILES[@]} > 0 )); then
        DEST="$QUAR_PATH"
        for f in "${JUNK_FILES[@]}"; do
            SRC="$f"
            STATUS="ignored"
            log "junk file detected. quarantining: $f"
            safe_move "$f" "$QUAR_PATH" || fail "quarantine move failed"
        done
    fi

    DEST=""
    STATUS="passed"
    SRC="$FILE_PATH"
    log "validation passed"

    # mark complete for validation stage
    touch "$VALIDATE_DONE"
}

run_manifest() {

    #filepath rehydration for retries
    resolve_file_path

    ACTION="manifest"
    STATUS="running"
    STAGE="metadata"

    #skip if done
    if [[ -f "$MANIFEST_DONE" ]]; then
        [[ -e "$FILE_PATH" ]] || fail "manifest marked done but file missing"
        log "manifest already complete, skipping"
        return
    fi

    log "generating manifest"

    #state rehydrate. repopulate FILES array with junk files removed
    mapfile -d '' -t FILES < <(find "$FILE_PATH" -type f -print0)

    FILES_JSON="[]"

    for f in "${FILES[@]}"; do
        if is_core_media_file "$f"; then
            HASH=$(sha256sum "$f" | awk '{print $1}') || fail "hash failed for $f" #expect output [HASH] [FILENAME].. strip filename
            REL_PATH="${f#$FILE_PATH/}" #/home/tom/processing/filename.mkv.dir/filename.mkv -> filename.mkv. strip bundle root prefix only

            # add file entry to JSON array with format {"name": "<relative path>", "hash": "<sha256 hash>"}
            FILES_JSON=$(jq \
                --arg name "$REL_PATH" \
                --arg hash "$HASH" \
                '. += [{"name":$name,"hash":$hash}]' \
                <<< "$FILES_JSON")
        fi
    done

    # atomic file creation to avoid partial writes
    TMP_MANIFEST="${MANIFEST_PATH}.tmp"


    # ensure bundle name is never empty/null
    SAFE_BUNDLE_NAME="${BUNDLE_NAME:-unknown}"

    # full JSON manifest to temp file
    # type is placeholder for downstream processing on host uptake
    jq -n \
        --arg job "$TRANS_ID" \
        --arg name "$SAFE_BUNDLE_NAME" \
        --arg src "$ORIG_SRC" \
        --argjson files "$FILES_JSON" \
        '{
            job_id: $job,
            name: $name,
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

    # mark complete for manifest stage
    touch "$MANIFEST_DONE"
}

run_export() {

    #filepath rehydration for retries
    resolve_file_path

    ACTION="stage"
    STATUS="running"
    STAGE="export"
    SRC="$FILE_PATH"
    DEST="$STAGE_PATH"

    #skip if done
    if [[ -f "$EXPORT_DONE" ]]; then
        [[ -e "$FILE_PATH" ]] || fail "export marked done but file missing"
        log "export already complete, skipping"
        return
    fi

    log "export intent: moving to staging"

    # hard boundary check: ensure mount / destination exists
    if [[ ! -d "$STAGE_DIR" ]]; then
        STATUS="failed"
        log "staging destination unavailable (mount missing or not mounted): $STAGE_DIR"
        exit 1
    fi

    # attempt atomic transfer
    safe_move "$FILE_PATH" "$STAGE_PATH"
    STATUS="success"
    log "handoff complete"

    # mark complete for export stage
    touch "$EXPORT_DONE"
}

# =========================
# DISPATCH RUNNER
# =========================

STATE="$(get_state)"

while true; do
    case "$STATE" in

        none|ingest)
            set_state "ingest"
            run_ingest
            STATE="scan"
            set_state "$STATE"
            ;;

        scan)
            set_state "scan"
            run_scan
            STATE="validate"
            set_state "$STATE"
            ;;

        validate)
            set_state "validate"
            run_validate
            STATE="manifest"
            set_state "$STATE"
            ;;

        manifest)
            set_state "manifest"
            run_manifest
            STATE="stage"
            set_state "$STATE"
            ;;

        stage)
            set_state "stage"
            run_export
            STATE="done"
            set_state "$STATE"
            ;;

        done)
            log "pipeline complete"
            exit 0
            ;;

        *)
            fail "unknown state: $STATE"
            ;;
    esac
done

exit 0

###### SUPPOSEDLY FIxED

#!/bin/bash
set -euo pipefail

# =========================
# SINGLE INSTANCE LOCK
# =========================

LOCKFILE="/var/lock/ingestion-vm.lock"

exec 9>"$LOCKFILE"
echo "[$$] waiting for lock on $LOCKFILE..."
flock 9
echo "[$$] acquired lock"

# =========================
# CONFIG
# =========================

MACHINE="$(hostname -s)"

LOG_DIR="/mnt/host/ready/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="/tmp/ingestion-bootstrap.log"

DOWNLOAD_DIR="/home/tom/Downloads/complete"
PROCESSING_DIR="/home/tom/processing"
STAGING_DIR="/mnt/host/staging"
QUARANTINE_DIR="/home/tom/quarantine"
REGISTRY_DIR="/mnt/host/ready/registry"

mkdir -p "$LOG_DIR" "$PROCESSING_DIR" "$QUARANTINE_DIR" "$REGISTRY_DIR"

# =========================
# LOGGING
# =========================

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
    log "$1"
    echo "FATAL: $1" >&2
    exit 1
}

trap '
ACTION=${ACTION:-fatal}
STATUS="error"
SRC=${SRC:-${FILE_PATH:-unknown}}
DEST=${DEST:-unknown}
log "unexpected failure"
exit 1
' ERR

# =========================
# DEPENDENCIES
# =========================

for cmd in clamdscan ffprobe ffmpeg sha256sum jq uuidgen find flock pgrep awk; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not installed"
done

pgrep -x clamd >/dev/null 2>&1 || fail "clamd daemon not running"

# =========================
# MEDIA FILTERS
# =========================

is_core_media_file() {
    case "$1" in
        *.mkv|*.mp4|*.avi|*.mov|*.m4v|*.ts|*.webm) return 0 ;;
        *) return 1 ;;
    esac
}

is_aux_file() {
    case "$1" in
        *.srt|*.ass|*.vtt) return 0 ;;
        *) return 1 ;;
    esac
}

# =========================
# SAFE MOVE
# =========================

safe_move() {
    local src="$1"
    local dest="$2"
    [[ -e "$dest" ]] && fail "destination exists: $dest"
    mv "$src" "$dest"
}

# =========================
# CONTEXT HYDRATION (FIXED CORE)
# =========================

hydrate_context() {

    # already valid
    if [[ -n "${FILE_PATH:-}" && -e "${FILE_PATH}" ]]; then
        return 0
    fi

    # primary recovery: processing
    if [[ -d "$PROC_PATH" ]]; then
        FILE_PATH="$PROC_PATH"
        return 0
    fi

    # staging recovery (retry mid-export failures)
    if [[ -e "$STAGE_PATH" ]]; then
        FILE_PATH="$STAGE_PATH"
        return 0
    fi

    # ingest reconstruction fallback
    if [[ -f "$INGEST_DONE" && -e "$PROCESSING_DIR/$BASENAME" ]]; then
        FILE_PATH="$PROCESSING_DIR/$BASENAME"
        return 0
    fi

    fail "context hydration failed: cannot resolve FILE_PATH"
}

# =========================
# ENTRY CONTRACT
# =========================

[[ $# -eq 3 ]] || fail "usage: $0 <name> <path> <infohash>"

TRANS_ID="$3"
BUNDLE_NAME="$1"
ORIG_SRC="$2"
BASENAME=$(basename "$ORIG_SRC")

LOG_FILE="$LOG_DIR/${TRANS_ID}.log"

# =========================
# STATE
# =========================

INGEST_DONE="$REGISTRY_DIR/${TRANS_ID}.ingest.done"
SCAN_DONE="$REGISTRY_DIR/${TRANS_ID}.scan.done"
VALIDATE_DONE="$REGISTRY_DIR/${TRANS_ID}.validate.done"
MANIFEST_DONE="$REGISTRY_DIR/${TRANS_ID}.manifest.done"
EXPORT_DONE="$REGISTRY_DIR/${TRANS_ID}.export.done"

STATE_FILE="$REGISTRY_DIR/${TRANS_ID}.state"

set_state() { echo "$1" > "$STATE_FILE"; }
get_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "none"; }

# =========================
# INPUT VALIDATION
# =========================

[[ -n "${ORIG_SRC:-}" ]] || fail "missing source path"

case "$(get_state)" in
    none|"")
        [[ -e "$ORIG_SRC" ]] || fail "input does not exist"
        ;;
esac

case "$ORIG_SRC" in
    "$DOWNLOAD_DIR"/*) ;;
    *) fail "must originate from download directory" ;;
esac

# =========================
# STATE VARIABLES
# =========================

SRC="$ORIG_SRC"
PROC_PATH="$PROCESSING_DIR/$BASENAME"
STAGE_PATH="$STAGING_DIR/$BASENAME"
QUAR_PATH="$QUARANTINE_DIR/$BASENAME"
MANIFEST_PATH="$REGISTRY_DIR/${TRANS_ID}.json"

# =========================
# INGEST
# =========================

run_ingest() {

    ACTION="ingest"
    STATUS="running"
    STAGE="ingest"

    log "starting ingestion"

    if [[ -f "$INGEST_DONE" ]]; then
        FILE_PATH="$PROC_PATH"
        log "ingestion already complete"
        return
    fi

    safe_move "$ORIG_SRC" "$PROC_PATH"

    if [[ -f "$PROC_PATH" ]]; then
        TMP_DIR="${PROC_PATH}.dir"
        mkdir -p "$TMP_DIR"
        mv "$PROC_PATH" "$TMP_DIR/"
        PROC_PATH="$TMP_DIR"
    fi

    FILE_PATH="$PROC_PATH"

    touch "$INGEST_DONE"
    STATUS="success"
    log "ingestion complete"
}

# =========================
# SCAN
# =========================

run_scan() {
    hydrate_context

    ACTION="scan"
    STATUS="running"
    STAGE="security"

    [[ -f "$SCAN_DONE" ]] && return

    if ! clamdscan --multiscan --recursive --fdpass "$FILE_PATH"; then
        safe_move "$FILE_PATH" "$QUAR_PATH"
        fail "malware detected"
    fi

    touch "$SCAN_DONE"
    STATUS="passed"
    log "scan complete"
}

# =========================
# VALIDATE
# =========================

run_validate() {
    hydrate_context

    ACTION="validate"
    STATUS="running"
    STAGE="validation"

    [[ -f "$VALIDATE_DONE" ]] && return

    mapfile -d '' -t FILES < <(find "$FILE_PATH" -type f -print0)

    for f in "${FILES[@]}"; do
        if is_core_media_file "$f"; then
            ffprobe -v error "$f" >/dev/null
            ffmpeg -v error -i "$f" -f null - >/dev/null
        fi
    done

    touch "$VALIDATE_DONE"
    STATUS="passed"
    log "validation complete"
}

# =========================
# MANIFEST
# =========================

run_manifest() {
    hydrate_context

    ACTION="manifest"
    STATUS="running"
    STAGE="metadata"

    [[ -f "$MANIFEST_DONE" ]] && return

    mapfile -d '' -t FILES < <(find "$FILE_PATH" -type f -print0)

    FILES_JSON="[]"

    for f in "${FILES[@]}"; do
        if is_core_media_file "$f"; then
            HASH=$(sha256sum "$f" | awk '{print $1}')
            REL_PATH="${f#$FILE_PATH/}"

            FILES_JSON=$(jq \
                --arg name "$REL_PATH" \
                --arg hash "$HASH" \
                '. += [{"name":$name,"hash":$hash}]' <<< "$FILES_JSON")
        fi
    done

    TMP="${MANIFEST_PATH}.tmp"

    jq -n \
        --arg job "$TRANS_ID" \
        --arg name "${BUNDLE_NAME:-unknown}" \
        --arg src "$ORIG_SRC" \
        --argjson files "$FILES_JSON" \
        '{job_id:$job,name:$name,source:$src,type:null,files:$files}' > "$TMP"

    mv "$TMP" "$MANIFEST_PATH"

    touch "$MANIFEST_DONE"
    STATUS="success"
    log "manifest complete"
}

# =========================
# EXPORT
# =========================

run_export() {
    hydrate_context

    ACTION="stage"
    STATUS="running"
    STAGE="export"

    [[ -f "$EXPORT_DONE" ]] && return

    [[ -d "$STAGING_DIR" ]] || fail "staging mount missing"

    safe_move "$FILE_PATH" "$STAGE_PATH"

    touch "$EXPORT_DONE"
    STATUS="success"
    log "export complete"
}

# =========================
# DISPATCH
# =========================

STATE="$(get_state)"

while true; do
    case "$STATE" in

        none|ingest)
            set_state "ingest"
            run_ingest
            STATE="scan"
            set_state "$STATE"
            ;;

        scan)
            set_state "scan"
            run_scan
            STATE="validate"
            set_state "$STATE"
            ;;

        validate)
            set_state "validate"
            run_validate
            STATE="manifest"
            set_state "$STATE"
            ;;

        manifest)
            set_state "manifest"
            run_manifest
            STATE="stage"
            set_state "$STATE"
            ;;

        stage)
            set_state "stage"
            run_export
            STATE="done"
            set_state "$STATE"
            ;;

        done)
            log "pipeline complete"
            exit 0
            ;;

        *)
            fail "unknown state: $STATE"
            ;;
    esac
done
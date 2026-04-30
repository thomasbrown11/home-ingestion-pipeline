#sudo apt install inotify-tools 

#!/usr/bin/env bash

# ==========================================
# VM-Drop Watcher
# Watches /home/tom/vm-drop/{movies,shows} for new files/directories,
# waits until they are stable, and moves them to /home/tom/labpull/{movies,shows}.
# Tracks processed items to prevent duplicates.
# Designed for production / systemd usage.
# ==========================================

set -euo pipefail

# ---------------------------
# System binaries (absolute paths for systemd)
# ---------------------------
MV_BIN=/usr/bin/mv
DU_BIN=/usr/bin/du
SLEEP_BIN=/usr/bin/sleep
MKDIR_BIN=/usr/bin/mkdir
INOTIFYWAIT_BIN=/usr/bin/inotifywait

# ---------------------------
# Script configuration
# ---------------------------
WATCH_BASE="/home/tom/vm-drop"
DEST_BASE="/home/tom/labpull"
STATE_DIR="/home/tom/.vm-drop-state"
SUBFOLDERS=("movies" "shows")
STABILITY_INTERVAL=3       # seconds between size checks
MIN_STABLE_ROUNDS=3        # consecutive stable checks
MAX_WORKERS=4              # parallel move jobs
MAX_STABLE_WAIT=300        # seconds to max wait for stabilization

# ---------------------------
# Initialize directories
# ---------------------------
"$MKDIR_BIN" -p "$STATE_DIR"
for f in "${SUBFOLDERS[@]}"; do
    "$MKDIR_BIN" -p "$WATCH_BASE/$f" "$DEST_BASE/$f"
done

# ---------------------------
# Logging function
# ---------------------------
log() {
    local level="${1:-INFO}"
    shift || true
    local msg="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg"
    logger -t vm-drop-watcher "[$level] $msg"
}

# ---------------------------
# Wait for available worker slot
# ---------------------------
wait_for_worker_slot() {
    while (( $(jobs -rp | wc -l) >= MAX_WORKERS )); do
        "$SLEEP_BIN" 1
    done
}

# ---------------------------
# Wait until a file/directory stops changing size
# ---------------------------
wait_for_stable() {
    local target="$1"
    local max_wait="${2:-$MAX_STABLE_WAIT}"
    local stable_count=0
    local prev_size=-1
    local waited=0

    while true; do
        [[ ! -e "$target" ]] && return  # skip if removed

        local size
        size=$($DU_BIN -sb "$target" 2>/dev/null | cut -f1 || echo 0)

        if [[ "$size" == "$prev_size" ]]; then
            ((stable_count++))
        else
            stable_count=0
        fi

        if (( stable_count >= MIN_STABLE_ROUNDS )); then
            return
        fi

        prev_size="$size"
        "$SLEEP_BIN" "$STABILITY_INTERVAL"
        ((waited+=STABILITY_INTERVAL))

        if (( max_wait > 0 && waited >= max_wait )); then
            log "WARNING" "$target did not stabilize within $max_wait seconds"
            return
        fi
    done
}

# ---------------------------
# Check if an item was already processed
# ---------------------------
already_processed() {
    local folder="$1"
    local name="$2"
    [[ -f "$STATE_DIR/$folder-$name.done" ]]
}

# ---------------------------
# Mark an item as processed
# ---------------------------
mark_processed() {
    local folder="$1"
    local name="$2"
    touch "$STATE_DIR/$folder-$name.done"
}

# ---------------------------
# Move a file/directory safely
# ---------------------------
process_item() {
    local folder="$1"
    local rel_path="$2"

    local src="$WATCH_BASE/$folder/$rel_path"
    local dest="$DEST_BASE/$folder/$rel_path"

    [[ "$rel_path" == .* ]] && return
    [[ "$rel_path" == *.part ]] && return
    [[ "$rel_path" == *.tmp ]] && return
    [[ ! -e "$src" ]] && return

    if already_processed "$folder" "$rel_path"; then
        log "INFO" "Skipping $folder/$rel_path (already processed)"
        return
    fi

    if [[ -d "$src" ]]; then
        log "INFO" "Detected directory: $folder/$rel_path"
    else
        log "INFO" "Detected file: $folder/$rel_path"
    fi

    wait_for_stable "$src" "$MAX_STABLE_WAIT"

    [[ ! -e "$src" ]] && {
        log "WARNING" "Skipping $folder/$rel_path (removed during stability wait)"
        return
    }

    if [[ -e "$dest" ]]; then
        log "WARNING" "Skipping $folder/$rel_path (already exists in destination)"
        mark_processed "$folder" "$rel_path"
        return
    fi

    # Ensure parent directories exist
    "$MKDIR_BIN" -p "$(dirname "$dest")"

    log "INFO" "Moving $folder/$rel_path -> $DEST_BASE/$folder"
    "$MV_BIN" -- "$src" "$dest"
    mark_processed "$folder" "$rel_path"
    log "INFO" "Completed move: $folder/$rel_path"
}

# ---------------------------
# Cleanup on exit
# ---------------------------
trap 'log "INFO" "Shutting down watcher"; pkill -P $$; exit 0' SIGINT SIGTERM

export WATCH_BASE DEST_BASE STATE_DIR SUBFOLDERS
export STABILITY_INTERVAL MIN_STABLE_ROUNDS MAX_WORKERS MAX_STABLE_WAIT
export -f log wait_for_stable already_processed mark_processed process_item wait_for_worker_slot

# ---------------------------
# Main watcher loop
# ---------------------------
log "INFO" "VM-drop watcher started"
log "INFO" "Watching: $WATCH_BASE"

for folder in "${SUBFOLDERS[@]}"; do
    "$INOTIFYWAIT_BIN" -m -r -e close_write -e moved_to --format '%w%f' "$WATCH_BASE/$folder" |
    while read -r fullpath; do
        wait_for_worker_slot

        # Compute top-level folder and relative path
        rel_path="${fullpath#$WATCH_BASE/}"           # remove base
        top_folder="${rel_path%%/*}"                 # movies/shows
        relative_name="${rel_path#$top_folder/}"     # nested path

        # Run the move in background
        bash -c "process_item \"$top_folder\" \"$relative_name\"" &
    done &
done

# Wait for all background workers
wait

#================

#make systemd service to run on startup
#move watcher script to /usr/local/bin and make executable
# sudo mv /home/tom/vm-drop-watcher.sh /usr/local/bin/vm-drop-watcher
# sudo chmod +x /usr/local/bin/vm-drop-watcher

#create service file:
#sudo nano /etc/systemd/system/vm-drop-watcher.service

#paste following: 
# [Unit]
# Description=VM Drop Folder Watcher
# After=network.target

# [Service]
# Type=simple
# ExecStart=/usr/local/bin/vm-drop-watcher
# Restart=always
# RestartSec=3
# User=tom
# StandardOutput=syslog
# StandardError=syslog
# SyslogIdentifier=vm-drop-watcher

# [Install]
# WantedBy=multi-user.target

#reload systemd to tell it about new service
# sudo systemctl daemon-reload

#start service:
#sudo systemctl start vm-drop-watcher

#Enable at boot:
#sudo systemctl enable vm-drop-watcher

#Check status:
#sudo systemctl status vm-drop-watcher

#===Log viewing=====
# View logs:

# journalctl -u vm-drop-watcher

# Follow live logs:

# journalctl -u vm-drop-watcher -f

#Notes ========
#If your pipline guarantees that files are only moved into the drop folder once they are fully written, you can simplify the script by removing the stability check and just reacting to moved_to events. This is a common pattern for atomic file delivery.

#!/usr/bin/env bash
# set -euo pipefail

# WATCH_DIR="/home/tom/vm-drop"
# DEST_DIR="/home/tom/labpull"

# mkdir -p "$DEST_DIR"

# echo "vm-drop watcher started"

# inotifywait -m -e moved_to --format '%f' "$WATCH_DIR" | while read -r FILE
# do
#     [[ "$FILE" == .* ]] && continue
#     [[ "$FILE" == *.part ]] && continue
#     [[ "$FILE" == *.tmp ]] && continue

#     SRC="$WATCH_DIR/$FILE"

#     [[ ! -e "$SRC" ]] && continue

#     echo "$(date) moving $FILE"

#     mv -- "$SRC" "$DEST_DIR/"

#     echo "$(date) completed $FILE"
# done
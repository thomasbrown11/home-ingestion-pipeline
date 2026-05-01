# #!/bin/bash
#!/usr/bin/env bash

export PATH="/users/brownt/homebrew/bin:$PATH"

# =========================
# PROJECT ROOT RESOLUTION
# =========================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BASE="/tmp/pipeline-test"
FIXTURES="$ROOT/tests/fixtures"

# test-controlled override environment
export LOCKFILE="$BASE/test.lock"
export LOG_DIR="$BASE/logs"
export DOWNLOAD_DIR="$BASE/downloads"
export PROCESSING_DIR="$BASE/processing"
export STAGING_DIR="$BASE/staging"
export QUARANTINE_DIR="$BASE/quarantine"
export REGISTRY_DIR="$BASE/registry"

# host test-controlled override environment
export INCOMING="$BASE/incoming"
export EXPORT_DIR="$BASE/export"
export LOG_FILE="$BASE/logs/host.log"

#test toggle for heavy dependencies and clamav
export TEST_MODE=1

# =========================
# RESET TEST STATE
# =========================

setup_env() {

    #reset test environment
    rm -rf "$BASE"

    # create directories for test environment
    mkdir -p \
        "$DOWNLOAD_DIR" \
        "$PROCESSING_DIR" \
        "$STAGING_DIR" \
        "$REGISTRY_DIR" \
        "$QUARANTINE_DIR" \
        "$LOG_DIR" \
        "$INCOMING" \
        "$INCOMING/movies" \
        "$INCOMING/shows" \
        "$EXPORT_DIR" 

    # create files for test environment
    touch "$LOG_FILE" 
    touch "$LOCKFILE"
}

# =========================
# VM RUNNER
# =========================

run_vm_script() {
    local name="$1"
    local path="$2"
    local id="$3"

    "$ROOT/ingestion-vm-v3.sh" "$name" "$path" "$id"
}

# =========================
# HOST RUNNER (optional future use)
# =========================

run_host_script() {
    local path="$1"

    [[ -d "$path" ]] || {
        echo "TEST ERROR: not a bundle directory: $path"
        return 1
    }

    "$ROOT/ingestion-host.sh" "$path"
}

# =========================
# ASSERT HELPERS
# =========================

assert_exists() {
    if [[ ! -e "$1" ]]; then
        echo "FAIL: expected file missing: $1"
        exit 1
    fi
}

# simple test pass wrapper for readability
pass() {
    echo "PASS: $1"
}
#!/bin/bash

BASE="/tmp/pipeline-test"
FIXTURES="$(dirname "$0")/fixtures"

DOWNLOAD_DIR="$BASE/downloads"
PROCESSING_DIR="$BASE/processing"
STAGING_DIR="$BASE/staging"
REGISTRY_DIR="$BASE/registry"

setup_env() {
    rm -rf "$BASE"
    mkdir -p "$DOWNLOAD_DIR" "$PROCESSING_DIR" "$STAGING_DIR" "$REGISTRY_DIR"
}

run_vm() {
    local name="$1"
    local path="$2"
    local id="$3"

    ./ingestion-vm.sh "$name" "$path" "$id"
}

assert_exists() {
    [[ -e "$1" ]] || {
        echo "ASSERT FAIL: $1 does not exist"
        exit 1
    }
}

pass() {
    echo "PASS: $1"
}
#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/../lib.sh"

TEST_NAME="happy_path"

setup_env

cp "$FIXTURES/good.mkv" "$DOWNLOAD_DIR/test.mkv"

run_vm "test" "$DOWNLOAD_DIR/test.mkv" "test123"

assert_exists "$STAGING_DIR/test.mkv"
assert_exists "$REGISTRY_DIR/test123.manifest"

pass "$TEST_NAME"
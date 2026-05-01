# #!/bin/bash
#!/usr/bin/env bash
set -euo pipefail

# source test helpers
source "$(dirname "$0")/../lib.sh"

TEST_NAME="happy_path"

# reset test environment
setup_env

# poopulate download dir with test file and run vm to create bundle
cp "$FIXTURES/good.mkv" "$DOWNLOAD_DIR/test.mkv"

# run vm to create bundle in staging and manifest in registry
run_vm_script "test" "$DOWNLOAD_DIR/test.mkv" "test123"

# expected output of vm is bundle in staging and manifest in registry
assert_exists "$STAGING_DIR/test.mkv.dir"
assert_exists "$REGISTRY_DIR/test123.json"

# will only reach pass if assert_exists doesn't fail out
pass "$TEST_NAME"
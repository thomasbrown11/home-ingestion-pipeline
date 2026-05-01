# #!/bin/bash
#!/usr/bin/env bash
set -euo pipefail

for test in tests/cases/*.sh; do
    echo "Running $test"
    bash "$test"
done

echo "All tests passed"
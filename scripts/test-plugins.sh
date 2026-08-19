#!/usr/bin/env bash
# Run all *_spec.lua files in plugins/ and modules/ subdirectories.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

FAILED=0
PASSED=0
ERRORS=()

while IFS= read -r spec; do
    if lua5.4 "$spec"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        ERRORS+=("$spec")
    fi
done < <(find "$ROOT/plugins" "$ROOT/modules" -name '*_spec.lua' | sort)

echo ""
echo "Plugin/module tests: $PASSED passed, $FAILED failed"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "Failed specs:"
    for e in "${ERRORS[@]}"; do
        echo "  $e"
    done
    exit 1
fi

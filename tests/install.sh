#!/bin/bash
set -eu

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

OUTPUT="$({
    cd "$TEST_DIRECTORY"
    BASH_ENV="$REPOSITORY_ROOT/tests/install_command_stubs.sh" \
        DEFAULT_IDENTITY_PATTERN="Test Identity" \
        bash "$REPOSITORY_ROOT/install.sh" \
            --ignore-lint \
            --ignore-test \
            --dry-run \
            --codesign-sha1 TEST_SHA1
} 2>&1)"

if [[ $'\n'"$OUTPUT"$'\n' != *$'\nResolving package dependencies...\n'* ]]; then
    echo "Expected xcodebuild output to remain visible when xcpretty is installed."
    echo "$OUTPUT"
    exit 1
fi

echo "install.sh tests passed."

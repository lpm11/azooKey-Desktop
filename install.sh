#!/bin/bash
set -xe -o pipefail

IGNORE_LINT=false
IGNORE_TEST=false
DRY_RUN=false
IDENTITY_SHA1=""
IDENTITY_NAME=""

# Parse command-line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ignore-lint) IGNORE_LINT=true ;;
        --ignore-test|--ignore-tests) IGNORE_TEST=true ;;
        --dry-run) DRY_RUN=true ;;
        --codesign-sha1) IDENTITY_SHA1="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$IDENTITY_SHA1" ] && [ -z "$DEFAULT_IDENTITY_PATTERN" ]; then
    echo "Environment variable DEFAULT_IDENTITY_PATTERN is not set."
    exit 1
fi

select_codesign_identity() {
    local identity_lines

    identity_lines="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if [ -z "$identity_lines" ]; then
        echo "Failed to list code signing identities. Please check your keychain setup."
        exit 1
    fi

    if [ -n "$IDENTITY_SHA1" ]; then
        IDENTITY_NAME="$(
            echo "$identity_lines" \
                | awk -v target="$IDENTITY_SHA1" '
                    $2 == target && $0 !~ /CSSMERR_TP_CERT_REVOKED/ {
                        match($0, /"[^"]+"/)
                        if (RSTART > 0) {
                            print substr($0, RSTART + 1, RLENGTH - 2)
                        }
                    }
                ' \
                | head -n 1
        )"
        if [ -z "$IDENTITY_NAME" ]; then
            echo "Specified identity (--codesign-sha1=$IDENTITY_SHA1) is not available or revoked."
            echo "Use 'security find-identity -v -p codesigning' to choose a non-revoked identity."
            exit 1
        fi
        return
    fi

    IDENTITY_SHA1="$(
        echo "$identity_lines" \
            | awk '
                /Apple Development:/ && $0 !~ /CSSMERR_TP_CERT_REVOKED/ {
                    print $2
                }
            ' \
            | head -n 1
    )"

    # Prefer the maintainer's default identity when available and not revoked.
    local default_identity_sha1
    default_identity_sha1="$(
        echo "$identity_lines" \
            | awk -v pattern="$DEFAULT_IDENTITY_PATTERN" '
                index($0, pattern) && $0 !~ /CSSMERR_TP_CERT_REVOKED/ {
                    print $2
                }
            ' \
            | head -n 1
    )"
    if [ -n "$default_identity_sha1" ]; then
        IDENTITY_SHA1="$default_identity_sha1"
    fi

    if [ -z "$IDENTITY_SHA1" ]; then
        echo "No non-revoked Apple Development identity found."
        echo "Issue a new certificate, then pass it explicitly:"
        echo "  ./install.sh --codesign-sha1 <SHA1>"
        exit 1
    fi

    IDENTITY_NAME="$(
        echo "$identity_lines" \
            | awk -v target="$IDENTITY_SHA1" '
                $2 == target {
                    match($0, /"[^"]+"/)
                    if (RSTART > 0) {
                        print substr($0, RSTART + 1, RLENGTH - 2)
                    }
                }
            ' \
            | head -n 1
    )"
}

if [ "$IGNORE_LINT" = false ]; then
    if command -v swiftlint &> /dev/null
    then
        # Fix auto-fixable errors
        swiftlint --fix --format
        # Check other errors
        swiftlint --quiet --strict
    else
        echo "swiftlint could not be found. Please rerun the script as \`./install.sh --ignore-lint\`."
        echo "For contributing azooKey on macOS, we strongly recommend you to install swiftlint"
        echo "To install swiftlint, run \`brew install swiftlint\`"
        exit 1
    fi
else
    echo "Skipping swiftlint checks due to --ignore-lint option."
fi

echo "Resolving Xcode package dependencies..."
xcodebuild \
    -resolvePackageDependencies \
    -project azooKeyMac.xcodeproj \
    -scheme azooKeyMac

run_xcodebuild() {
    if command -v xcpretty &> /dev/null; then
        xcodebuild "$@" | xcpretty
    else
        echo "xcpretty could not be found. Proceeding without xcpretty."
        xcodebuild "$@"
    fi
}

if [ "$IGNORE_TEST" = false ]; then
    swift test --package-path Core

    run_xcodebuild \
        test \
        -project azooKeyMac.xcodeproj \
        -scheme azooKeyMac \
        -destination 'platform=macOS'
else
    echo "Skipping test checks due to --ignore-test option."
fi

run_xcodebuild \
    -project azooKeyMac.xcodeproj \
    -scheme azooKeyMac \
    clean archive \
    -archivePath build/archive.xcarchive \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates

select_codesign_identity
echo "Using code signing identity: $IDENTITY_NAME ($IDENTITY_SHA1)"

APP_PATH="build/archive.xcarchive/Products/Applications/azooKeyMac.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build output not found: $APP_PATH"
    exit 1
fi

echo "Re-signing archive product with selected identity..."
codesign --force --deep --sign "$IDENTITY_SHA1" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would execute the following commands:"
    echo "  sudo rm -rf /Library/Input\ Methods/azooKeyMac.app"
    echo "  sudo cp -r build/archive.xcarchive/Products/Applications/azooKeyMac.app /Library/Input\ Methods/"
    echo "  pkill azooKeyMac"
    echo "Build completed successfully. Use without --dry-run to actually install."
else
    sudo rm -rf /Library/Input\ Methods/azooKeyMac.app
    sudo cp -r build/archive.xcarchive/Products/Applications/azooKeyMac.app /Library/Input\ Methods/
    pkill azooKeyMac || true
fi

#!/bin/bash

xcodebuild() {
    if [[ " $* " == *" -resolvePackageDependencies "* ]]; then
        echo "Resolving package dependencies..."
    fi
    if [[ " $* " == *" archive "* ]]; then
        mkdir -p build/archive.xcarchive/Products/Applications/azooKeyMac.app
    fi
}

xcpretty() {
    cat > /dev/null
}

security() {
    echo '  1) TEST_SHA1 "Apple Development: Test Identity"'
}

codesign() {
    return 0
}

#!/bin/zsh
set -u

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

echo "Building and notarizing NLVC VPN from $PROJECT_DIR"
echo

if "$PROJECT_DIR/scripts/build_developer_id_pkg.command"; then
    echo
    if "$PROJECT_DIR/scripts/notarize_pkg.command"; then
        echo
        echo "NLVC_RELEASE_RESULT=SUCCESS"
    else
        result=$?
        echo
        echo "NLVC_RELEASE_RESULT=NOTARIZATION_FAILED:$result"
    fi
else
    result=$?
    echo
    echo "NLVC_RELEASE_RESULT=BUILD_FAILED:$result"
fi

echo
read "REPLY?Press Return to close this window..."

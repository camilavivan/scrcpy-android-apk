#!/bin/sh
# In-container orchestrator. Called by ./test from outside.
#   /work/test-rig/run.sh unit|server|e2e|all|screenshots|apk
#
# Expects to run inside the scrcpy-android-test docker image with
# /work mounted at the project root.

set -eu

cmd="${1:-unit}"

mkdir -p /work/.tools/gradle-home /work/.tools/avd /work/.tools/home/.android
export HOME="/work/.tools/home"
export ANDROID_USER_HOME="/work/.tools/home/.android"
export ANDROID_SDK_HOME="/work/.tools/home"
export GRADLE_USER_HOME="/work/.tools/gradle-home"
export ANDROID_AVD_HOME="/work/.tools/avd"

unit() {
    echo "test: gradle :app:test :adb:test :app:lint"
    /work/gradlew --no-daemon -q :app:test :adb:test :app:lint
}

e2e() {
    /work/test-rig/e2e.sh
}

server() {
    /work/scripts/check-server-source
}

case "$cmd" in
    unit)        unit ;;
    server)      server ;;
    e2e)         e2e ;;
    all)         unit && server && e2e ;;
    screenshots) /work/test-rig/screenshots.sh ;;
    apk)         /work/test-rig/build-apk.sh ;;
    *)           echo "run.sh: bad cmd $cmd" >&2; exit 2 ;;
esac

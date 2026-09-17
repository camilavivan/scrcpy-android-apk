#!/bin/sh
# Smoke test: build a signed release APK from inside the rig using a
# throwaway keystore. Validates that scripts/build-apk + the gradle
# signingConfigs wiring still produces a valid signed apk.
#
# Output: /work/app/build/outputs/apk/release/app-release.apk
#         (and the keystore in /work/.tools/release-smoke.p12)

set -eu

KS="/work/.tools/release-smoke.p12"
KS_PASS="changeit"
KEY_ALIAS="scrcpy-android-smoke"

mkdir -p /work/.tools

if [ ! -f "$KS" ]; then
    echo "build-apk.sh: generating throwaway keystore at $KS"
    keytool -genkey -noprompt \
        -keystore "$KS" -storetype PKCS12 \
        -storepass "$KS_PASS" -keypass "$KS_PASS" \
        -alias "$KEY_ALIAS" -keyalg RSA -keysize 2048 -validity 36500 \
        -dname "CN=scrcpy-android smoke, OU=test, O=local, C=US" \
        >/dev/null
fi

export KEYSTORE_PATH="$KS"
export KEYSTORE_PASS="$KS_PASS"
export KEY_ALIAS="$KEY_ALIAS"
export KEY_PASS="$KS_PASS"

exec /work/scripts/build-apk

#!/bin/sh
# Regenerate the F-Droid listing screenshots.
#
# Boots a pixel_6 AVD on the same AOSP API-36 image the e2e tier uses -
# natively 1080x2400, the geometry the tracked PNGs already have - and
# screencaps Main and Settings into
# fastlane/metadata/android/en-US/images/phoneScreenshots/.
#
# The AVD is its own (scrcpy-shots, not scrcpy-test) so a screenshot run
# never perturbs the device state ./test e2e asserts against. Panel size
# comes from the device profile rather than `wm size`: overriding
# geometry on a booted software-GPU emulator ANRs SystemUI, and the ANR
# dialog lands in the capture.
#
# Runs inside the test image; orchestrated by ../test.

set -eu

ROOT=/work
# Debug applicationId (note the .debug suffix). Activity classes live in
# the invalid.lena.scrcpy namespace, which carries no suffix.
PKG=invalid.lena.scrcpy.debug
AVD=scrcpy-shots
SERIAL=emulator-5554
APK=$ROOT/app/build/outputs/apk/debug/app-debug.apk
SHOTS=$ROOT/fastlane/metadata/android/en-US/images/phoneScreenshots
TMPDIR=$ROOT/.tools/shots
STAGE=$TMPDIR/output
WIDTH=1080
HEIGHT=2400
SYSTEM_IMAGE=system-images/android-36/default/x86_64/
# Isolate emulator authorization from any ADB server running on the host.
export ADB_SERVER_SOCKET=tcp:localhost:5039
export ANDROID_ADB_SERVER_ADDRESS=localhost
export ANDROID_ADB_SERVER_PORT=5039
mkdir -p "$TMPDIR" "$STAGE" "$SHOTS"

log() { printf 'screenshots: %s\n' "$*" >&2; }

cleanup() {
    adb -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    adb kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_boot() {
    # A clean API-36 emulator commonly needs more than two minutes on a
    # loaded software-rendering host. Match the proven e2e boot margin.
    wb_deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$wb_deadline" ]; do
        if [ "$(adb -s "$SERIAL" get-state 2>/dev/null || true)" = device ]; then
            wb_done=$(adb -s "$SERIAL" shell getprop sys.boot_completed \
                    2>/dev/null | tr -d '\r' || true)
            [ "$wb_done" = 1 ] && return
        fi
        sleep 2
    done
    log "$SERIAL did not finish booting"
    exit 1
}

dump_ui() {
    du_file=$1
    du_tmp=$du_file.tmp
    du_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$du_deadline" ]; do
        if adb -s "$SERIAL" shell uiautomator dump /sdcard/scrcpy-shots-ui.xml \
                >/dev/null 2>&1 \
                && adb -s "$SERIAL" exec-out cat /sdcard/scrcpy-shots-ui.xml \
                > "$du_tmp" 2>/dev/null \
                && grep -q '<hierarchy' "$du_tmp"; then
            mv "$du_tmp" "$du_file"
            return
        fi
        sleep 1
    done
    rm -f "$du_tmp"
    log 'could not capture UI hierarchy'
    exit 1
}

dismiss_systemui_anr() {
    da_ui=$TMPDIR/systemui-anr.xml
    dump_ui "$da_ui"
    da_node=$(tr '>' '\n' < "$da_ui" | awk \
        'index($0, "resource-id=\"android:id/aerr_wait\"") { print; exit }')
    [ -n "$da_node" ] || return 0
    da_bounds=$(printf '%s\n' "$da_node" \
        | sed -n 's/.* bounds="\([^\"]*\)".*/\1/p')
    da_coords=$(printf '%s\n' "$da_bounds" | sed -n \
        's/^\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]$/\1 \2 \3 \4/p')
    [ -n "$da_coords" ] || return 0
    # Split the validated numeric tuple into four shell arguments.
    # shellcheck disable=SC2086
    set -- $da_coords
    log 'waiting for first-boot System UI ANR to recover'
    adb -s "$SERIAL" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
    sleep 5
}

# ---- 0. server jar ----
[ -f "$ROOT/app/src/main/assets/scrcpy-server.jar" ] || "$ROOT/scripts/update-server"

# ---- 1. build APK ----
log 'gradle :app:assembleDebug'
"$ROOT/gradlew" --no-daemon -q :app:assembleDebug

# ---- 2. AVD + boot ----
AVD_DIR="$ANDROID_AVD_HOME/$AVD.avd"
if avdmanager list avd | grep -q "Name: $AVD$"; then
    if [ ! -f "$AVD_DIR/config.ini" ] \
            || ! grep -Eq "^image\.sysdir\.[0-9]+ *= *$SYSTEM_IMAGE$" \
                    "$AVD_DIR/config.ini"; then
        log "recreating stale avd $AVD"
        avdmanager delete avd -n "$AVD" >/dev/null
    fi
fi
if ! avdmanager list avd | grep -q "Name: $AVD$"; then
    log "creating avd $AVD (pixel_6, ${WIDTH}x${HEIGHT})"
    echo no | avdmanager create avd -n "$AVD" -k 'system-images;android-36;default;x86_64' -d pixel_6 >/dev/null
fi

# Clean stale lock files from a previously aborted run; snapshot.lock.lock
# and read-snapshot.txt in particular make the next boot die with
# "a snapshot operation is pending and timeout has expired".
rm -f "$AVD_DIR"/multiinstance.lock "$AVD_DIR"/hardware-qemu.ini.lock \
      "$AVD_DIR"/snapshot.lock.lock "$AVD_DIR"/read-snapshot.txt 2>/dev/null || true
rm -rf "$ANDROID_USER_HOME/avd/running" 2>/dev/null || true

adb start-server >/dev/null
if ! pgrep -f "emulator.*-avd $AVD" >/dev/null; then
    log 'booting emulator (no window, no snapshot)'
    emulator -avd "$AVD" -no-window -no-audio -no-snapshot -gpu swiftshader \
             -no-boot-anim -accel on >"$TMPDIR/emulator.log" 2>&1 &
fi
wait_boot

# ---- 3. install ----
log "install $APK"
adb -s "$SERIAL" install -r "$APK" >/dev/null
# Screenshot 1 is the empty-list state; a re-run must not inherit the
# devices.json a previous run left behind.
adb -s "$SERIAL" shell pm clear "$PKG" >/dev/null

# ---- 4. capture ----
# Start from the exported launcher activity. Settings is deliberately not
# exported, so open it through the same button a user taps.

open_settings() {
    os_ui=$TMPDIR/settings-button.xml
    dump_ui "$os_ui"
    os_node=$(tr '>' '\n' < "$os_ui" | awk -v id="$PKG:id/settings" \
        'index($0, "resource-id=\"" id "\"") { print; exit }')
    [ -n "$os_node" ] || {
        log 'settings button was not visible'
        cat "$os_ui" >&2
        exit 1
    }
    os_bounds=$(printf '%s\n' "$os_node" \
        | sed -n 's/.* bounds="\([^\"]*\)".*/\1/p')
    os_coords=$(printf '%s\n' "$os_bounds" | sed -n \
        's/^\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]$/\1 \2 \3 \4/p')
    [ -n "$os_coords" ] || {
        log "could not parse settings-button bounds: $os_bounds"
        exit 1
    }
    # Split the validated numeric tuple into four shell arguments.
    # shellcheck disable=SC2086
    set -- $os_coords
    os_x=$(( ($1 + $3) / 2 ))
    os_y=$(( ($2 + $4) / 2 ))
    os_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$os_deadline" ]; do
        if adb -s "$SERIAL" shell input tap "$os_x" "$os_y" 2>/dev/null; then
            return
        fi
        sleep 1
    done
    log 'could not tap the settings button'
    exit 1
}

shot() {
    activity=$1
    out=$2
    log "capture $activity -> $out"
    case "$activity" in
        Main)
            adb -s "$SERIAL" shell am force-stop "$PKG"
            if ! start_output=$(adb -s "$SERIAL" shell am start -W -n \
                    "$PKG/invalid.lena.scrcpy.Main" 2>&1); then
                log 'launcher activity failed to start'
                printf '%s\n' "$start_output" >&2
                exit 1
            fi ;;
        SettingsActivity)
            open_settings ;;
        *)
            log "unsupported screenshot activity: $activity"
            exit 1 ;;
    esac
    sleep 4
    dismiss_systemui_anr
    # Anything else on top - a system dialog, an ANR, a failed launch -
    # means the shot is not the screen we asked for. Fail, do not ship it.
    focus_line=$(adb -s "$SERIAL" shell dumpsys window \
            | sed -n '/mCurrentFocus=/ { p; q; }')
    focus=$(printf '%s\n' "$focus_line" \
            | sed -n 's/.* \([^ ]*\/[^ }]*\).*/\1/p')
    case "$focus" in
        "$PKG/invalid.lena.scrcpy.$activity") ;;
        *)
            log "focused window is '$focus', want $PKG/invalid.lena.scrcpy.$activity"
            log "$focus_line"
            adb -s "$SERIAL" logcat -d -b crash 2>/dev/null | tail -80 >&2 || true
            exit 1 ;;
    esac
    staged=$STAGE/$out
    adb -s "$SERIAL" exec-out screencap -p > "$staged"
    [ -s "$staged" ] || { log "$out is empty"; exit 1; }
    # Reject anything that is not the panel we expect: a wrong-sized PNG
    # means the device profile changed and the shot is unusable.
    got=$(ffprobe -v error -select_streams v:0 \
                  -show_entries stream=width,height -of csv=p=0:s=x "$staged")
    [ "$got" = "${WIDTH}x${HEIGHT}" ] || { log "$out is $got, want ${WIDTH}x${HEIGHT}"; exit 1; }
}

shot Main             1.png
shot SettingsActivity 2.png

install -m 0644 "$STAGE/1.png" "$SHOTS/1.png"
install -m 0644 "$STAGE/2.png" "$SHOTS/2.png"

log "wrote $SHOTS/1.png $SHOTS/2.png"
log 'done'

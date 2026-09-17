#!/bin/sh
# Two-emulator release E2E.
#
# The target exposes Android's real Wireless debugging pairing dialog. The
# source release APK reads that six-digit code through its ordinary UI, pairs
# through Conscrypt/SPAKE2, mirrors a deterministic moving pattern through the
# production SurfaceView, reconnects after scrcpy is killed, and reconnects
# again after adbd rotates its process-scoped TLS certificate.
#
# Timings are overridable for slower or faster hosts:
# E2E_BOOT_DEADLINE, E2E_SETTLE_DEADLINE, E2E_UI_DEADLINE,
# E2E_ROTATE_DEADLINE, E2E_RESIZE_DEADLINE.

set -eu

ROOT=/work
SOURCE_AVD=scrcpy-source
TARGET_AVD=scrcpy-target
SOURCE_SERIAL=emulator-5554
TARGET_SERIAL=emulator-5556
SOURCE_PKG=invalid.lena.scrcpy
TARGET_PKG=invalid.lena.scrcpy.debug
SOURCE_APK=$ROOT/app/build/outputs/apk/release/app-release.apk
TARGET_APK=$ROOT/app/build/outputs/apk/debug/app-debug.apk
TMPDIR=$ROOT/.tools/e2e
CONNECT_FORWARD=37000
PAIR_FORWARD=37001
SYSTEM_IMAGE=system-images/android-36/default/x86_64/
# Do not reuse or kill a developer's host ADB server. A reused server may
# have a different key and leave a headless emulator unauthorized.
export ADB_SERVER_SOCKET=tcp:localhost:5038
export ANDROID_ADB_SERVER_ADDRESS=localhost
export ANDROID_ADB_SERVER_PORT=5038

mkdir -p "$TMPDIR"

log() { printf 'e2e: %s\n' "$*" >&2; }

deadline() {
    dl_name=$1
    dl_value=$2
    case "$dl_value" in
        ''|0|*[!0-9]*)
            log "$dl_name must be a positive integer"
            exit 2
            ;;
    esac
    printf '%s\n' "$dl_value"
}

E2E_BOOT_DEADLINE=$(deadline E2E_BOOT_DEADLINE "${E2E_BOOT_DEADLINE:-300}")
E2E_SETTLE_DEADLINE=$(deadline E2E_SETTLE_DEADLINE "${E2E_SETTLE_DEADLINE:-240}")
E2E_UI_DEADLINE=$(deadline E2E_UI_DEADLINE "${E2E_UI_DEADLINE:-120}")
E2E_ROTATE_DEADLINE=$(deadline E2E_ROTATE_DEADLINE "${E2E_ROTATE_DEADLINE:-45}")
E2E_RESIZE_DEADLINE=$(deadline E2E_RESIZE_DEADLINE "${E2E_RESIZE_DEADLINE:-60}")

free_kb=$(df -Pk "$ROOT/.tools" | awk 'NR == 2 { print $4 }')
case "$free_kb" in
    ''|*[!0-9]*) log "cannot determine free space under $ROOT/.tools"; exit 1 ;;
esac
if [ "$free_kb" -lt 1048576 ]; then
    log "need at least 1 GiB free under $ROOT/.tools; have $(( free_kb / 1024 )) MiB"
    exit 1
fi

stop_emulator() {
    adb -s "$1" emu kill >/dev/null 2>&1 || true
}

cleanup() {
    stop_emulator "$SOURCE_SERIAL"
    stop_emulator "$TARGET_SERIAL"
    adb kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_boot() {
    wb_serial=$1
    wb_pid=${2:-}
    wb_log=${3:-}
    # A single API-36 emulator takes about 90 s to boot on an idle
    # 12-core host, and this tier boots two at once. 120 s left no margin:
    # on a loaded machine the second one misses it, and even a successful
    # run was observed finishing at 112 s. Overridable so a fast CI can
    # tighten it back up.
    wb_deadline=$(( $(date +%s) + E2E_BOOT_DEADLINE ))
    while [ "$(date +%s)" -lt "$wb_deadline" ]; do
        if [ -n "$wb_pid" ] && ! kill -0 "$wb_pid" 2>/dev/null; then
            if wait "$wb_pid"; then wb_rc=0; else wb_rc=$?; fi
            log "$wb_serial emulator exited during boot (rc=$wb_rc)"
            if [ -n "$wb_log" ] && [ -f "$wb_log" ]; then
                tail -40 "$wb_log" >&2
            fi
            exit 1
        fi
        if [ "$(adb -s "$wb_serial" get-state 2>/dev/null || true)" = device ]; then
            wb_done=$(adb -s "$wb_serial" shell getprop sys.boot_completed 2>/dev/null \
                    | tr -d '\r' || true)
            [ "$wb_done" = 1 ] && return
        fi
        sleep 2
    done
    log "$wb_serial did not finish booting"
    exit 1
}

# sys.boot_completed fires while the system is still finishing first-boot
# work, and this rig passes -wipe-data on every run, so every boot is a
# full first boot. uiautomator needs an idle window and will not get one
# until that settles: a dump attempted too early fails for a minute and
# then gives up. Wait for a focused window before driving any UI.
wait_ui_ready() {
    wu_serial=$1
    wu_deadline=$(( $(date +%s) + E2E_SETTLE_DEADLINE ))
    while [ "$(date +%s)" -lt "$wu_deadline" ]; do
        if adb -s "$wu_serial" shell dumpsys window 2>/dev/null \
                | grep -q 'mCurrentFocus=Window'; then
            return
        fi
        sleep 2
    done
    log "$wu_serial never reported a focused window; the system never settled"
    adb -s "$wu_serial" shell dumpsys window 2>/dev/null | head -20 >&2 || true
    exit 1
}

wait_wifi() {
    ww_deadline=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$ww_deadline" ]; do
        if adb -s "$TARGET_SERIAL" shell ip -4 addr show wlan0 2>/dev/null \
                | grep -q ' inet '; then
            return
        fi
        sleep 2
    done
    log 'target Wi-Fi never received an address'
    exit 1
}

refresh_ui() {
    ru_serial=$1
    ru_file=$2
    ru_tmp=$ru_file.tmp
    ru_error=$ru_file.error
    # uiautomator refuses to dump while the window is still animating or
    # settling, which is exactly the state a freshly booted emulator is in
    # when the first dump is taken. Animations are already off by here;
    # this is the remaining margin.
    ru_deadline=$(( $(date +%s) + E2E_UI_DEADLINE ))
    ru_n=0
    while [ "$(date +%s)" -lt "$ru_deadline" ]; do
        ru_n=$(( ru_n + 1 ))
        # --compressed drops non-interesting nodes. It succeeds on some
        # hierarchies where the full dump gives up, and everything this
        # rig looks for (resource-id, text, bounds) survives compression.
        if [ $(( ru_n % 2 )) -eq 0 ]; then
            ru_mode=--compressed
        else
            ru_mode=
        fi
        if adb -s "$ru_serial" shell uiautomator dump $ru_mode /sdcard/scrcpy-e2e-ui.xml \
                >"$ru_error" 2>&1 \
                && adb -s "$ru_serial" exec-out cat /sdcard/scrcpy-e2e-ui.xml \
                > "$ru_tmp" 2>>"$ru_error" \
                && grep -q '<hierarchy' "$ru_tmp"; then
            mv "$ru_tmp" "$ru_file"
            rm -f "$ru_error"
            return
        fi
        # uiautomator waits for an idle window and gives up if one never
        # comes. A dozing screen or a stuck animation both cause that, so
        # nudge the device awake between attempts rather than just waiting.
        if [ $(( ru_n % 5 )) -eq 0 ]; then
            adb -s "$ru_serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
            adb -s "$ru_serial" shell wm dismiss-keyguard >/dev/null 2>&1 || true
        fi
        sleep 1
    done
    log "uiautomator never produced a hierarchy for $ru_serial after $ru_n attempts"
    adb -s "$ru_serial" shell dumpsys window 2>/dev/null \
        | grep -E 'mCurrentFocus|mFocusedApp' >&2 || true
    [ ! -s "$ru_error" ] || tail -20 "$ru_error" >&2
    rm -f "$ru_tmp" "$ru_error"
    log "could not capture UI hierarchy from $ru_serial"
    exit 1
}

find_node() {
    fn_file=$1
    fn_needle=$2
    tr '>' '\n' < "$fn_file" | awk -v needle="$fn_needle" \
        'index($0, needle) { print; exit }'
}

node_attr() {
    na_node=$1
    na_attr=$2
    printf '%s\n' "$na_node" \
        | sed -n "s/.* ${na_attr}=\"\([^\"]*\)\".*/\1/p"
}

tap_node() {
    tn_serial=$1
    tn_node=$2
    tn_bounds=$(node_attr "$tn_node" bounds)
    tn_coords=$(printf '%s\n' "$tn_bounds" | sed -n \
        's/^\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]$/\1 \2 \3 \4/p')
    [ -n "$tn_coords" ] || {
        log "could not parse UI bounds: $tn_bounds"
        exit 1
    }
    # Split the validated numeric tuple into four shell arguments.
    # shellcheck disable=SC2086
    set -- $tn_coords
    adb -s "$tn_serial" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}

tap_resource() {
    tr_serial=$1
    tr_file=$2
    tr_id=$3
    tr_node=$(find_node "$tr_file" "resource-id=\"$tr_id\"")
    [ -n "$tr_node" ] || {
        log "resource $tr_id is not visible"
        exit 1
    }
    tap_node "$tr_serial" "$tr_node"
}

input_resource() {
    ir_serial=$1
    ir_file=$2
    ir_id=$3
    ir_text=$4
    tap_resource "$ir_serial" "$ir_file" "$ir_id"
    adb -s "$ir_serial" shell input text "$ir_text"
    sleep 1
    refresh_ui "$ir_serial" "$ir_file"
}

dismiss_fullscreen_prompt() {
    df_serial=$1
    df_file=$2
    sleep 1
    refresh_ui "$df_serial" "$df_file"
    df_button=$(find_node "$df_file" 'text="Got it"')
    if [ -n "$df_button" ]; then
        log "dismissing first-use full-screen prompt on $df_serial"
        tap_node "$df_serial" "$df_button"
        sleep 1
    fi
}

start_pattern() {
    sp_file=$1
    adb -s "$TARGET_SERIAL" shell am force-stop "$TARGET_PKG"
    if ! sp_start=$(adb -s "$TARGET_SERIAL" shell am start -W -n \
            "$TARGET_PKG/invalid.lena.scrcpy.Pattern" 2>&1); then
        log 'target Pattern activity failed to start'
        printf '%s\n' "$sp_start" >&2
        exit 1
    fi
    sp_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$sp_deadline" ]; do
        if adb -s "$TARGET_SERIAL" shell dumpsys activity activities 2>/dev/null \
                | grep -q 'ResumedActivity.*invalid.lena.scrcpy.Pattern'; then
            dismiss_fullscreen_prompt "$TARGET_SERIAL" "$sp_file"
            return
        fi
        sleep 1
    done
    log 'target Pattern activity did not become resumed'
    printf '%s\n' "$sp_start" >&2
    adb -s "$TARGET_SERIAL" shell dumpsys activity activities 2>/dev/null \
        | grep -E 'ResumedActivity|invalid\.lena\.scrcpy\.Pattern' >&2 || true
    adb -s "$TARGET_SERIAL" logcat -d -b crash 2>/dev/null | tail -80 >&2 || true
    exit 1
}

reopen_source_from_notification() {
    rn_file=$1
    rn_node=
    rn_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$rn_deadline" ]; do
        adb -s "$SOURCE_SERIAL" shell cmd statusbar expand-notifications
        sleep 1
        refresh_ui "$SOURCE_SERIAL" "$rn_file"
        rn_node=$(find_node "$rn_file" 'text="Mirroring active"')
        [ -n "$rn_node" ] && break
    done
    [ -n "$rn_node" ] || {
        log 'foreground-session notification was not visible'
        cat "$rn_file" >&2
        exit 1
    }
    tap_node "$SOURCE_SERIAL" "$rn_node"
}

open_wireless_page() {
    ow_file=$1
    ow_started=
    ow_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$ow_deadline" ]; do
        if adb -s "$TARGET_SERIAL" shell am start -W -a \
                android.settings.APPLICATION_DEVELOPMENT_SETTINGS >/dev/null 2>&1; then
            ow_started=1
            break
        fi
        sleep 1
    done
    [ -n "$ow_started" ] || {
        log 'Developer options did not open'
        exit 1
    }
    ow_search=
    ow_deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$ow_deadline" ]; do
        refresh_ui "$TARGET_SERIAL" "$ow_file"
        [ -n "$(find_node "$ow_file" 'text="Use wireless debugging"')" ] && return
        ow_search=$(find_node "$ow_file" 'content-desc="Search settings"')
        [ -n "$ow_search" ] && break
        sleep 1
    done
    [ -n "$ow_search" ] || {
        log 'Settings search button did not appear'
        cat "$ow_file" >&2
        exit 1
    }
    tap_node "$TARGET_SERIAL" "$ow_search"
    sleep 1
    adb -s "$TARGET_SERIAL" shell input text 'Wireless%sdebugging'

    ow_result=
    ow_deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$ow_deadline" ]; do
        refresh_ui "$TARGET_SERIAL" "$ow_file"
        # Search returns more than one exact title. Either result opens a
        # containing Settings page with the matching preference visible.
        ow_result=$(tr '>' '\n' < "$ow_file" | awk \
            'index($0, "text=\"Wireless debugging\"") \
                && index($0, "resource-id=\"android:id/title\"") { print; exit }')
        [ -n "$ow_result" ] && break
        sleep 1
    done
    [ -n "$ow_result" ] || {
        log 'Wireless debugging did not appear in Settings search'
        cat "$ow_file" >&2
        exit 1
    }
    tap_node "$TARGET_SERIAL" "$ow_result"

    ow_deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$ow_deadline" ]; do
        refresh_ui "$TARGET_SERIAL" "$ow_file"
        [ -n "$(find_node "$ow_file" 'text="Use wireless debugging"')" ] && return
        ow_pref=$(tr '>' '\n' < "$ow_file" | awk \
            'index($0, "text=\"Wireless debugging\"") \
                && index($0, "resource-id=\"android:id/title\"") { print; exit }')
        [ -z "$ow_pref" ] || tap_node "$TARGET_SERIAL" "$ow_pref"
        sleep 1
    done
    log 'Wireless debugging page did not open from Settings search'
    cat "$ow_file" >&2
    exit 1
}

enable_wireless() {
    ew_file=$1
    refresh_ui "$TARGET_SERIAL" "$ew_file"
    ew_switch=$(find_node "$ew_file" 'text="Use wireless debugging"')
    [ -n "$ew_switch" ] || {
        log 'Wireless debugging switch was not visible on target'
        cat "$ew_file" >&2
        exit 1
    }

    ew_toggle=$(find_node "$ew_file" 'resource-id="android:id/switch_widget"')
    if [ "$(node_attr "$ew_toggle" checked)" != true ]; then
        tap_node "$TARGET_SERIAL" "$ew_switch"
        sleep 1
        refresh_ui "$TARGET_SERIAL" "$ew_file"
        ew_allow=$(find_node "$ew_file" 'resource-id="android:id/button1"')
        if [ -n "$ew_allow" ]; then
            tap_node "$TARGET_SERIAL" "$ew_allow"
        fi
    fi

    ew_enabled=
    ew_deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -lt "$ew_deadline" ]; do
        ew_enabled=$(adb -s "$TARGET_SERIAL" shell settings get global adb_wifi_enabled \
                2>/dev/null | tr -d '\r' || true)
        [ "$ew_enabled" = 1 ] && return
        sleep 1
    done
    log "Wireless debugging confirmation did not enable it (state=$ew_enabled)"
    refresh_ui "$TARGET_SERIAL" "$ew_file"
    cat "$ew_file" >&2
    exit 1
}

source_log() {
    adb -s "$SOURCE_SERIAL" logcat -d -s scrcpy-android 2>/dev/null || true
}

target_log() {
    adb -s "$TARGET_SERIAL" logcat -d -s scrcpy-android 2>/dev/null || true
}

fail_on_runtime_error() {
    fo_log=$(source_log)
    if printf '%s\n' "$fo_log" | grep -q 'session: gave up'; then
        log 'session gave up:'
        printf '%s\n' "$fo_log" | tail -80 >&2
        exit 1
    fi
    if adb -s "$SOURCE_SERIAL" logcat -d -b crash 2>/dev/null \
            | grep -q "$SOURCE_PKG"; then
        log 'release app crashed:'
        adb -s "$SOURCE_SERIAL" logcat -d -b crash 2>/dev/null | tail -80 >&2
        exit 1
    fi
    if adb -s "$SOURCE_SERIAL" logcat -d 2>/dev/null \
            | grep -q "ANR in $SOURCE_PKG"; then
        log 'release app ANR detected'
        exit 1
    fi
}

# Rotating the target only proves something if the target's display
# actually turns. Without this the next wait cannot tell a rig that failed
# to rotate from a client that ignored the new geometry, and the failure
# reads as a client bug either way.
target_display() {
    adb -s "$TARGET_SERIAL" shell dumpsys window displays 2>/dev/null \
        | grep -o 'cur=[0-9]*x[0-9]*' | head -1 | tr -d '\r'
}

# Compare against what the display was, not against a literal geometry:
# the target's size depends on its AVD profile, and asserting a hardcoded
# 1920x1080 failed on a device that rotates to 1080x606.
wait_display_change() {
    wd_before=$1
    wd_deadline=$(( $(date +%s) + E2E_ROTATE_DEADLINE ))
    wd_cur=
    while [ "$(date +%s)" -lt "$wd_deadline" ]; do
        wd_cur=$(target_display)
        if [ -n "$wd_cur" ] && [ "$wd_cur" != "$wd_before" ]; then
            log "target display $wd_before -> $wd_cur"
            return
        fi
        sleep 1
    done
    log "target display never moved from ${wd_before:-unknown}"
    log 'the target did not rotate, so the client was never asked to resize'
    exit 1
}

wait_log() {
    wl_pattern=$1
    wl_seconds=$2
    wl_deadline=$(( $(date +%s) + wl_seconds ))
    while [ "$(date +%s)" -lt "$wl_deadline" ]; do
        fail_on_runtime_error
        source_log | grep -q "$wl_pattern" && return
        sleep 1
    done
    log "timed out waiting for log pattern: $wl_pattern"
    source_log | tail -100 >&2
    exit 1
}

wait_target_log() {
    wt_pattern=$1
    wt_seconds=$2
    wt_deadline=$(( $(date +%s) + wt_seconds ))
    while [ "$(date +%s)" -lt "$wt_deadline" ]; do
        fail_on_runtime_error
        target_log | grep -q "$wt_pattern" && return
        sleep 1
    done
    log "timed out waiting for target log pattern: $wt_pattern"
    target_log | tail -100 >&2
    log 'source log at target assertion failure:'
    source_log | tail -100 >&2
    exit 1
}

wait_connect_port() {
    wc_file=$1
    wp_deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$wp_deadline" ]; do
        refresh_ui "$TARGET_SERIAL" "$wc_file"
        wp_addr=$(tr '>' '\n' < "$wc_file" | sed -n \
            's/.* text="\([0-9][0-9.]*:[0-9][0-9]*\)".*/\1/p' | sed -n '1p')
        wp_port=${wp_addr##*:}
        case "$wp_port" in
            ''|*[!0-9]*) ;;
            *) [ "$wp_port" -gt 0 ] && [ "$wp_port" -le 65535 ] \
                && { printf '%s\n' "$wp_port"; return; } ;;
        esac
        # In landscape the IP row starts below the visible fold. These
        # coordinates are inside the Settings list in both orientations.
        adb -s "$TARGET_SERIAL" shell input swipe 900 950 900 500 250
        sleep 1
    done
    log 'target never displayed a Wireless debugging connect port'
    wc_state=$(adb -s "$TARGET_SERIAL" shell settings get global adb_wifi_enabled \
            2>/dev/null | tr -d '\r' || true)
    log "adb_wifi_enabled=$wc_state"
    cat "$wc_file" >&2
    exit 1
}

wait_tls_stopped() {
    ws_deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$ws_deadline" ]; do
        ws_port=$(adb -s "$TARGET_SERIAL" shell getprop persist.adb.tls_server.enable \
                2>/dev/null | tr -d '\r' || true)
        case "$ws_port" in
            ''|0) return ;;
        esac
        sleep 1
    done
    log 'target Wireless debugging TLS port did not stop'
    exit 1
}

# ---- build the exact artifacts under test ----

[ -f "$ROOT/app/src/main/assets/scrcpy-server.jar" ] || "$ROOT/scripts/update-server"
log 'building debug target fixture and minified release source'
"$ROOT/gradlew" --no-daemon -q :app:assembleDebug
KS=$ROOT/.tools/e2e-release.p12
if [ ! -f "$KS" ]; then
    keytool -genkey -noprompt -keystore "$KS" -storetype PKCS12 \
        -storepass changeit -keypass changeit -alias e2e \
        -keyalg RSA -keysize 2048 -validity 36500 \
        -dname 'CN=scrcpy-android e2e, O=local, C=US' >/dev/null
fi
KEYSTORE_PATH=$KS KEYSTORE_PASS=changeit KEY_ALIAS=e2e KEY_PASS=changeit \
    "$ROOT/scripts/build-apk" >/dev/null

# ---- boot two isolated devices ----

ensure_avd() {
    ea_name=$1
    ea_config=$ANDROID_AVD_HOME/$ea_name.avd/config.ini
    if avdmanager list avd | grep -q "Name: $ea_name$"; then
        if [ -f "$ea_config" ] \
                && grep -Eq "^image\.sysdir\.[0-9]+ *= *$SYSTEM_IMAGE$" "$ea_config"; then
            return
        fi
        log "recreating stale AVD $ea_name"
        avdmanager delete avd -n "$ea_name" >/dev/null
    fi
    log "creating AVD $ea_name"
    echo no | avdmanager create avd -n "$ea_name" \
        -k 'system-images;android-36;default;x86_64' -d pixel >/dev/null
}

for e2_avd in "$SOURCE_AVD" "$TARGET_AVD"; do
    ensure_avd "$e2_avd"
done

stop_emulator "$SOURCE_SERIAL"
stop_emulator "$TARGET_SERIAL"
adb start-server >/dev/null
sleep 2

for e2_avd in "$SOURCE_AVD" "$TARGET_AVD"; do
    e2_dir=$ANDROID_AVD_HOME/$e2_avd.avd
    rm -f "$e2_dir/multiinstance.lock" "$e2_dir/hardware-qemu.ini.lock" \
        "$e2_dir/snapshot.lock.lock" 2>/dev/null || true
done

log 'booting source on 5554'
emulator -avd "$SOURCE_AVD" -port 5554 -no-window -no-audio -no-snapshot \
    -wipe-data -memory 1536 -no-metrics -gpu swiftshader \
    -no-boot-anim -accel on \
    >"$TMPDIR/source-emulator.log" 2>&1 &
SOURCE_PID=$!
wait_boot "$SOURCE_SERIAL" "$SOURCE_PID" "$TMPDIR/source-emulator.log"
wait_ui_ready "$SOURCE_SERIAL"

log 'booting target on 5556'
emulator -avd "$TARGET_AVD" -port 5556 -no-window -no-audio -no-snapshot \
    -wipe-data -memory 1536 -no-metrics -gpu swiftshader \
    -no-boot-anim -accel on \
    >"$TMPDIR/target-emulator.log" 2>&1 &
TARGET_PID=$!
wait_boot "$TARGET_SERIAL" "$TARGET_PID" "$TMPDIR/target-emulator.log"
wait_ui_ready "$TARGET_SERIAL"
wait_wifi
sleep 10

# AOSP may show a one-off first-boot System UI timeout while software graphics
# settles. Waiting is safe here, before any app or product assertion exists.
for e2_serial in "$SOURCE_SERIAL" "$TARGET_SERIAL"; do
    e2_ui=$TMPDIR/boot-${e2_serial}.xml
    refresh_ui "$e2_serial" "$e2_ui"
    e2_wait=$(find_node "$e2_ui" 'resource-id="android:id/aerr_wait"')
    if [ -n "$e2_wait" ]; then
        tap_node "$e2_serial" "$e2_wait"
        sleep 5
    fi
done

for e2_serial in "$SOURCE_SERIAL" "$TARGET_SERIAL"; do
    adb -s "$e2_serial" shell settings put global window_animation_scale 0
    adb -s "$e2_serial" shell settings put global transition_animation_scale 0
    adb -s "$e2_serial" shell settings put global animator_duration_scale 0
    adb -s "$e2_serial" shell settings put secure \
        immersive_mode_confirmations confirmed
done

# ---- install clean source and target apps ----

adb -s "$SOURCE_SERIAL" uninstall "$SOURCE_PKG" >/dev/null 2>&1 || true
adb -s "$SOURCE_SERIAL" uninstall "$TARGET_PKG" >/dev/null 2>&1 || true
adb -s "$TARGET_SERIAL" uninstall "$TARGET_PKG" >/dev/null 2>&1 || true
adb -s "$SOURCE_SERIAL" install "$SOURCE_APK" >/dev/null
adb -s "$SOURCE_SERIAL" install "$TARGET_APK" >/dev/null
adb -s "$TARGET_SERIAL" install "$TARGET_APK" >/dev/null
adb -s "$SOURCE_SERIAL" shell pm grant "$SOURCE_PKG" \
    android.permission.POST_NOTIFICATIONS >/dev/null

# ---- open the target's real pairing-code dialog ----

log 'enabling Developer options and opening Wireless debugging'
adb -s "$TARGET_SERIAL" shell settings put global development_settings_enabled 1

TARGET_UI=$TMPDIR/target-ui.xml
open_wireless_page "$TARGET_UI"
enable_wireless "$TARGET_UI"
CONNECT_PORT=$(wait_connect_port "$TARGET_UI")

pair_pref=
pair_deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$pair_deadline" ]; do
    refresh_ui "$TARGET_SERIAL" "$TARGET_UI"
    pair_pref=$(find_node "$TARGET_UI" 'text="Pair device with pairing code"')
    [ -n "$pair_pref" ] && break
    sleep 1
done
[ -n "$pair_pref" ] || {
    log 'pairing-code preference was not visible on target'
    cat "$TARGET_UI" >&2
    exit 1
}
tap_node "$TARGET_SERIAL" "$pair_pref"

PAIR_CODE=
PAIR_ADDR=
code_deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$code_deadline" ]; do
    refresh_ui "$TARGET_SERIAL" "$TARGET_UI"
    code_node=$(find_node "$TARGET_UI" 'resource-id="com.android.settings:id/pairing_code"')
    addr_node=$(find_node "$TARGET_UI" 'resource-id="com.android.settings:id/ip_addr"')
    PAIR_CODE=$(node_attr "$code_node" text)
    PAIR_ADDR=$(node_attr "$addr_node" text)
    [ "${#PAIR_CODE}" -eq 6 ] && [ -n "$PAIR_ADDR" ] && break
    sleep 1
done
case "$PAIR_CODE" in
    [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) log "bad pairing code from Settings: $PAIR_CODE"; exit 1 ;;
esac
PAIR_PORT=${PAIR_ADDR##*:}
case "$PAIR_PORT" in
    ''|*[!0-9]*) log "bad pairing address from Settings: $PAIR_ADDR"; exit 1 ;;
esac
log "target connect=$CONNECT_PORT pair=$PAIR_PORT"

adb -s "$TARGET_SERIAL" emu redir del tcp:$CONNECT_FORWARD >/dev/null 2>&1 || true
adb -s "$TARGET_SERIAL" emu redir del tcp:$PAIR_FORWARD >/dev/null 2>&1 || true
adb -s "$TARGET_SERIAL" emu redir add "tcp:$CONNECT_FORWARD:$CONNECT_PORT" >/dev/null
adb -s "$TARGET_SERIAL" emu redir add "tcp:$PAIR_FORWARD:$PAIR_PORT" >/dev/null

# ---- pair through the release app's ordinary form ----

log 'entering pairing data in the source release app'
adb -s "$SOURCE_SERIAL" logcat -c
adb -s "$SOURCE_SERIAL" shell am start -W -n "$SOURCE_PKG/.Main" >/dev/null
SOURCE_UI=$TMPDIR/source-ui.xml
button_deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$button_deadline" ]; do
    refresh_ui "$SOURCE_SERIAL" "$SOURCE_UI"
    button_node=$(find_node "$SOURCE_UI" "resource-id=\"$SOURCE_PKG:id/pair\"")
    [ "$(node_attr "$button_node" enabled)" = true ] && break
    sleep 1
done
[ "$(node_attr "$button_node" enabled)" = true ] || {
    log 'source pairing button never became enabled'
    source_log | tail -80 >&2
    exit 1
}

input_resource "$SOURCE_SERIAL" "$SOURCE_UI" \
    "$SOURCE_PKG:id/device_address" "10.0.2.2:$CONNECT_FORWARD"
input_resource "$SOURCE_SERIAL" "$SOURCE_UI" \
    "$SOURCE_PKG:id/pair_port" "$PAIR_FORWARD"
input_resource "$SOURCE_SERIAL" "$SOURCE_UI" \
    "$SOURCE_PKG:id/pair_code" "$PAIR_CODE"
tap_resource "$SOURCE_SERIAL" "$SOURCE_UI" "$SOURCE_PKG:id/pair"
wait_log 'pair ok host=10.0.2.2' 45

# Put a known moving image on the target before opening the saved row.
start_pattern "$TARGET_UI"
adb -s "$SOURCE_SERIAL" shell input keyevent KEYCODE_BACK >/dev/null
sleep 1
refresh_ui "$SOURCE_SERIAL" "$SOURCE_UI"
row_node=$(find_node "$SOURCE_UI" "resource-id=\"$SOURCE_PKG:id/device_label\"")
if [ -z "$row_node" ]; then
    adb -s "$SOURCE_SERIAL" shell input swipe 500 1500 500 500 300
    refresh_ui "$SOURCE_SERIAL" "$SOURCE_UI"
    row_node=$(find_node "$SOURCE_UI" "resource-id=\"$SOURCE_PKG:id/device_label\"")
fi
[ -n "$row_node" ] || {
    log 'paired row did not appear in source UI'
    cat "$SOURCE_UI" >&2
    exit 1
}
[ "$(node_attr "$row_node" text)" = "10.0.2.2:$CONNECT_FORWARD" ] || {
    log 'saved-device row contains the wrong endpoint'
    cat "$SOURCE_UI" >&2
    exit 1
}
tap_node "$SOURCE_SERIAL" "$row_node"

# ---- require TLS, Opus playback, and actual rendered output ----

wait_log 'adb connect ok' 90
wait_log 'audio meta codec=opus' 30
wait_log 'audio sink: opus configured' 30
wait_log 'audio sink: playback started' 30
wait_log 'video sink: rendered frame n=1' 30
dismiss_fullscreen_prompt "$SOURCE_SERIAL" "$SOURCE_UI"

sleep 1
adb -s "$SOURCE_SERIAL" exec-out screencap -p > "$TMPDIR/paired.png"
java "$ROOT/test-rig/Pixhash.java" "$TMPDIR/paired.png" --pattern

log 'forwarding touch, key, and target clipboard through the control socket'
adb -s "$SOURCE_SERIAL" logcat -c
adb -s "$TARGET_SERIAL" logcat -c
adb -s "$SOURCE_SERIAL" shell input tap 500 1000
wait_target_log 'pattern: touch up' 15
wait_target_log 'pattern: clipboard set' 15
wait_log 'clipboard from target: 10 chars' 15
adb -s "$SOURCE_SERIAL" shell input keyevent KEYCODE_A
wait_target_log 'pattern: key up code=29' 15

# Copy text in another source app while Mirror is backgrounded. Android 10+
# only lets the focused app read the clipboard, so Mirror must read and send
# it explicitly after regaining focus. Backgrounding also destroys the
# SurfaceView Surface; resume must rebuild the decoder from cached codec config.
log 'forwarding source clipboard and requiring Surface recreation'
adb -s "$SOURCE_SERIAL" logcat -c
adb -s "$TARGET_SERIAL" logcat -c
if ! source_pattern_start=$(adb -s "$SOURCE_SERIAL" shell am start -W -n \
        "$TARGET_PKG/invalid.lena.scrcpy.Pattern" \
        --es clipboard_text source-e2e 2>&1); then
    log 'source clipboard fixture failed to start'
    printf '%s\n' "$source_pattern_start" >&2
    exit 1
fi
wait_log 'mirror: surface destroyed' 30
dismiss_fullscreen_prompt "$SOURCE_SERIAL" "$SOURCE_UI"
adb -s "$SOURCE_SERIAL" shell input tap 500 1000
wait_log 'pattern: clipboard set' 15
reopen_source_from_notification "$SOURCE_UI"
wait_log 'mirror: surface created' 30
wait_log 'clipboard to target: 10 chars' 30
wait_target_log 'pattern: clipboard from source' 30
wait_log 'video sink: rendered frame n=1' 45
adb -s "$SOURCE_SERIAL" exec-out screencap -p > "$TMPDIR/resumed.png"
java "$ROOT/test-rig/Pixhash.java" "$TMPDIR/resumed.png" --pattern
sleep 2
if source_log | grep -q 'session: link lost'; then
    log 'session dropped after Surface recreation'
    source_log | tail -100 >&2
    exit 1
fi

# A target resize rebuilds MediaCodec. The new decoder must receive the
# cached codec-config packet that was sent only once at stream startup.
log 'rotating target and requiring a resized rendered stream'
adb -s "$SOURCE_SERIAL" logcat -c
ROTATE_BEFORE=$(target_display)
log "target display before rotation: ${ROTATE_BEFORE:-unknown}"
adb -s "$TARGET_SERIAL" shell wm user-rotation lock 1
wait_display_change "$ROTATE_BEFORE"
wait_log 'video resize' "$E2E_RESIZE_DEADLINE"
wait_log 'video sink: rendered frame n=1' 45
adb -s "$SOURCE_SERIAL" exec-out screencap -p > "$TMPDIR/rotated.png"
java "$ROOT/test-rig/Pixhash.java" "$TMPDIR/rotated.png" --pattern
adb -s "$TARGET_SERIAL" logcat -c
adb -s "$SOURCE_SERIAL" shell input tap 500 1000
wait_target_log 'pattern: touch up' 15

# ---- kill only scrcpy and require a fresh generation ----

log 'killing target scrcpy server and requiring automatic reconnect'
adb -s "$SOURCE_SERIAL" logcat -c
adb -s "$TARGET_SERIAL" shell 'pkill -f com.genymobile.scrcpy.Server' || true
wait_log 'session: link lost' 45
wait_log 'spawn server ver=' 60
wait_log 'video sink: rendered frame n=1' 45
adb -s "$SOURCE_SERIAL" exec-out screencap -p > "$TMPDIR/reconnected.png"
java "$ROOT/test-rig/Pixhash.java" "$TMPDIR/reconnected.png" --pattern

# ---- restart adbd and require reconnect with its new ephemeral certificate ----

log 'restarting target adbd to change its process-scoped TLS identity'
adb -s "$SOURCE_SERIAL" logcat -c
adb -s "$TARGET_SERIAL" root >/dev/null 2>&1 || true
wait_boot "$TARGET_SERIAL"
adb -s "$TARGET_SERIAL" shell settings put global adb_wifi_enabled 0
wait_tls_stopped
open_wireless_page "$TARGET_UI"
enable_wireless "$TARGET_UI"
NEW_CONNECT_PORT=$(wait_connect_port "$TARGET_UI")
adb -s "$TARGET_SERIAL" emu redir del tcp:$CONNECT_FORWARD >/dev/null 2>&1 || true
adb -s "$TARGET_SERIAL" emu redir add "tcp:$CONNECT_FORWARD:$NEW_CONNECT_PORT" >/dev/null
start_pattern "$TARGET_UI"
wait_log 'session: link lost' 90
wait_log 'adb connect ok' 90
wait_log 'video sink: rendered frame n=1' 60
adb -s "$SOURCE_SERIAL" exec-out screencap -p > "$TMPDIR/adbd-restarted.png"
java "$ROOT/test-rig/Pixhash.java" "$TMPDIR/adbd-restarted.png" --pattern
source_log > "$TMPDIR/logcat.scrcpy"
log 'pairing, TLS, Opus, input, two-way clipboard, resize, render, and reconnect: pass'

# scrcpy-android (Ghostpanter) — build notes

Updated: 2026-09-18 00:30 HKT (UTC+8)

## Rebuild from a fresh clone

```sh
git clone https://github.com/Ghostpanter/scrcpy-android.git
cd scrcpy-android
# JDK 17+ and Android SDK required
export JAVA_HOME=…   # e.g. path to JDK 17
export ANDROID_HOME=…  # Android SDK root
./scripts/update-server   # fetches scrcpy-server.jar into app/src/main/assets/
./gradlew :app:assembleDebug
```

Requirements for `assembleDebug`:
- Gradle wrapper (`gradlew` + `gradle/wrapper/*`)
- App sources under `app/`
- `:adb` module at `vendor/libadb-android/libadb` (see `settings.gradle`)
- `scripts/update-server` (or a pre-placed `app/src/main/assets/scrcpy-server.jar`)

## Package / SDK

| Field | Value |
|-------|-------|
| applicationId / namespace | `com.ghostpanter.scrcpy` |
| versionName | `0.5-ghostpanter` |
| versionCode | `6` |
| minSdk | 31 |
| compileSdk / targetSdk | 37 |
| Upstream | https://gitlab.com/0xlena/scrcpy-android (v0.5) |
| License | Apache-2.0 (+ bundled notices) |

## Ghostpanter deltas vs upstream v0.5

1. Package `invalid.lena.scrcpy` → `com.ghostpanter.scrcpy`
2. compileSdk/targetSdk 36 → 37
3. Latency settings: max FPS + prefer low-latency encoder (`i-frame-interval=1`)
4. QR Wireless Debugging pairing (display QR; target scans; mDNS discovery)
5. scrcpy-server asset via `scripts/update-server` (scrcpy 4.1)

## Notes

- `app/src/main/assets/scrcpy-server.jar` is intentionally gitignored; regenerate with `./scripts/update-server`.
- Debug builds use the AGP debug keystore.
- Do not commit `local.properties`, ADB identity keys, or keystores.

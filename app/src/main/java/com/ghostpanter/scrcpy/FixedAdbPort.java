package com.ghostpanter.scrcpy;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;

// After a successful wireless ADB connect, optionally switch adbd to a
// stable tcpip port and rewrite the saved device endpoint so later
// reconnects skip re-pairing / ephemeral ports.
//
// tcpip is best-effort: only persist the fixed port after a successful
// connect to it. On failure, restore the original ephemeral endpoint and
// never leave the caller holding a dead fixed address.
public final class FixedAdbPort {

    private static final long ADBD_RESTART_MS = 600L;

    private FixedAdbPort() {}

    // Caller must already be connected to current.host:current.port.
    // Returns the endpoint to keep using (unchanged, or host:fixedPort).
    // On success leaves Adb connected to the returned endpoint.
    // Skips when disabled or already on the fixed port (no loop).
    public static Devices.Device applyIfNeeded(Context ctx, Adb adb, Devices.Device current)
            throws Exception {
        if (current == null) throw new IllegalArgumentException("device is null");
        if (!Settings.fixedAdbPortEnabled(ctx)) return current;
        int fixed = Settings.fixedAdbPort(ctx);
        if (current.port == fixed) {
            Log.i("adb: already on fixed port %d — skip tcpip", fixed);
            return current;
        }

        Devices.Device original = current;
        Log.i("adb: switching %s from port %d to fixed %d", current.host, current.port, fixed);
        Exception tcpipErr = null;
        try {
            adb.enableTcpip(fixed);
        } catch (Exception e) {
            // enableTcpip disconnects; connection drop mid-service is normal.
            tcpipErr = e;
            Log.w("adb: enableTcpip(%d) ended: %s", fixed, e);
        }
        try { adb.disconnect(); } catch (Exception ignored) {}

        try {
            Thread.sleep(ADBD_RESTART_MS);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw ie;
        }

        try {
            adb.connect(current.host, fixed);
        } catch (Exception reconnect) {
            if (tcpipErr != null) reconnect.addSuppressed(tcpipErr);
            Log.e(reconnect,
                    "adb: reconnect to fixed port %d failed — restoring original %s:%d (no upsert)",
                    fixed, original.host, original.port);
            try { adb.disconnect(); } catch (Exception ignored) {}
            try {
                adb.connect(original.host, original.port);
                Log.i("adb: restored original ephemeral endpoint %s after fixed-port failure",
                        original);
                return original;
            } catch (Exception restoreErr) {
                Log.e(restoreErr,
                        "adb: failed to restore original %s after fixed-port failure", original);
                reconnect.addSuppressed(restoreErr);
                // Do not upsert fixed port; do not return a dead fixed endpoint.
                throw reconnect;
            }
        }

        Devices.Device locked = new Devices.Device(current.host, fixed);
        // Persist only after a verified connect to the fixed port.
        try {
            Devices.upsertHost(ctx.getApplicationContext(), locked);
        } catch (Exception e) {
            Log.e(e, "adb: failed to save fixed-port device");
        }

        toastLocked(ctx, fixed);
        Log.i("adb: fixed port active at %s", locked);
        return locked;
    }

    private static void toastLocked(Context ctx, int port) {
        Context app = ctx.getApplicationContext();
        String msg = app.getString(R.string.fixed_adb_port_locked, port);
        new Handler(Looper.getMainLooper()).post(() ->
                Toast.makeText(app, msg, Toast.LENGTH_LONG).show());
    }
}

package com.ghostpanter.scrcpy;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.IOException;
import java.util.List;

// Pairing form + saved-device list.
//
// Layout: device address ("ip:port"), pair-port, pair-code + a single
// "Pair and save" button. The address is the connect endpoint printed on
// the target's Wireless debugging screen; pairing happens on a different,
// short-lived port from the pairing dialog, against the same host. After a
// successful pair() against the daemon, the row is appended to devices.json
// with the *connect* port. Tapping a saved row launches the Mirror activity.
public final class Main extends Activity {

    private volatile Adb adb;
    private LinearLayout deviceList;
    private TextView     devicesEmpty;
    private Button       pairButton;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        setContentView(R.layout.main);

        // The IME inset is in the mask too: the window is edge-to-edge, so
        // nothing resizes it when the keyboard opens. The page is one
        // ScrollView, so padding the root keeps the form reachable behind
        // the keyboard.
        Ui.padForInsets(findViewById(R.id.root),
                WindowInsets.Type.systemBars() | WindowInsets.Type.ime());

        EditText address     = findViewById(R.id.device_address);
        EditText pairPort    = findViewById(R.id.pair_port);
        EditText pairCode    = findViewById(R.id.pair_code);
        pairButton           = findViewById(R.id.pair);
        View settingsBtn     = findViewById(R.id.settings);
        deviceList  = findViewById(R.id.devices);
        devicesEmpty = findViewById(R.id.devices_empty);

        settingsBtn.setOnClickListener(v -> startActivity(
                new Intent(this, SettingsActivity.class)));
        findViewById(R.id.pair_qr).setOnClickListener(v ->
                startActivity(new Intent(this, QrPair.class)));

        try {
            showDevices(Devices.load(this));
        } catch (IOException e) {
            Log.e(e, "devices: load failed");
            showDevices(java.util.Collections.emptyList());
            Toast.makeText(this, R.string.device_list_unreadable, Toast.LENGTH_LONG).show();
        }

        // RSA keygen on first launch can take 1-3 s; never on the UI thread.
        pairButton.setEnabled(false);
        new Thread(() -> {
            try {
                Adb a = Adb.getInstance(getApplicationContext());
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed()) return;
                    adb = a;
                    pairButton.setEnabled(true);
                });
            } catch (Exception e) {
                Log.e(e, "adb init failed");
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed()) return;
                    Toast.makeText(this, getString(R.string.adb_init_failed, e.getMessage()),
                            Toast.LENGTH_LONG).show();
                    finish();
                });
            }
        }, "adb-init").start();

        pairButton.setOnClickListener(v -> {
            if (adb == null) return; // still initialising
            // The saved endpoint is the address field verbatim; pairing
            // reuses its host with the pairing port.
            Devices.Device target = Devices.parseAddress(address.getText().toString());
            if (target == null) {
                Toast.makeText(this, R.string.bad_address, Toast.LENGTH_LONG).show();
                return;
            }
            int pairP = Devices.parsePort(pairPort.getText().toString());
            if (pairP < 0) {
                Toast.makeText(this, R.string.bad_pair_port, Toast.LENGTH_LONG).show();
                return;
            }
            String pc = pairCode.getText().toString().trim();
            if (TextUtils.isEmpty(pc) || !pc.matches("[0-9]{6}")) {
                Toast.makeText(this, R.string.bad_pair_code, Toast.LENGTH_LONG).show();
                return;
            }
            pairButton.setEnabled(false);
            Toast.makeText(this, R.string.pairing, Toast.LENGTH_SHORT).show();
            new Thread(() -> pairAndSave(target, pairP, pc, pairButton), "pair").start();
        });
    }

    // Rebuild the saved-device rows. There is no adapter: the whole page
    // is one ScrollView, a ListView cannot measure itself inside one, and
    // a handful of rows does not need recycling.
    private void showDevices(List<Devices.Device> devices) {
        deviceList.removeAllViews();
        devicesEmpty.setVisibility(devices.isEmpty() ? View.VISIBLE : View.GONE);
        for (Devices.Device d : devices) {
            View row = getLayoutInflater().inflate(R.layout.device_row, deviceList, false);
            ((TextView) row.findViewById(R.id.device_label)).setText(d.toString());
            row.setOnClickListener(v -> {
                Log.i("connect tap: %s", d);
                Intent i = new Intent(this, Mirror.class);
                i.putExtra(Mirror.EXTRA_HOST, d.host);
                i.putExtra(Mirror.EXTRA_PORT, d.port);
                startActivity(i);
            });
            row.setOnLongClickListener(v -> { confirmForget(d); return true; });
            deviceList.addView(row);
        }
    }

    private void confirmForget(Devices.Device d) {
        new AlertDialog.Builder(this)
                .setTitle(R.string.forget_device)
                .setMessage(d.toString())
                .setPositiveButton(android.R.string.ok, (dlg, w) -> {
                    Log.i("forget device: %s", d);
                    try {
                        showDevices(Devices.remove(this, d));
                    } catch (Exception e) {
                        Log.e(e, "forget device: save failed");
                        Toast.makeText(this, R.string.could_not_save_device_list,
                                Toast.LENGTH_LONG).show();
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    private void pairAndSave(Devices.Device target, int pairPort, String code, Button btn) {
        try {
            Log.i("pair: %s:%d", target.host, pairPort);
            adb.pairDevice(target.host, pairPort, code);
            Log.i("pair ok host=%s pair_port=%d", target.host, pairPort);
            List<Devices.Device> updated = Devices.upsert(getApplicationContext(), target);
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) return;
                showDevices(updated);
                Toast.makeText(this, R.string.paired_and_saved, Toast.LENGTH_SHORT).show();
                btn.setEnabled(true);
            });
        } catch (Exception e) {
            Log.e(e, "pair failed");
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) return;
                Toast.makeText(this, getString(R.string.pair_failed, e.getMessage()), Toast.LENGTH_LONG).show();
                btn.setEnabled(true);
            });
        }
    }
}

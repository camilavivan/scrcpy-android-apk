package com.ghostpanter.scrcpy;

import android.app.Activity;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.WindowInsets;
import android.widget.CheckBox;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.TextView;

// Codec choice + streaming knobs. All persisted to SharedPreferences
// via Settings on click; the next session bringup reads them and
// applies to the scrcpy server cmdline.
public final class SettingsActivity extends Activity {

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        setContentView(R.layout.settings);
        Ui.padForInsets(findViewById(R.id.root), WindowInsets.Type.systemBars());
        showVersion();

        RadioGroup videoGroup   = findViewById(R.id.video_codec);
        RadioGroup audioGroup   = findViewById(R.id.audio_codec);
        RadioGroup maxSizeGroup = findViewById(R.id.max_size);
        RadioGroup bitRateGroup = findViewById(R.id.video_bit_rate);
        RadioGroup maxFpsGroup  = findViewById(R.id.max_fps);

        switch (Settings.videoCodec(this)) {
            case "h265": ((RadioButton) findViewById(R.id.video_h265)).setChecked(true); break;
            case "av1":  ((RadioButton) findViewById(R.id.video_av1)).setChecked(true);  break;
            default:     ((RadioButton) findViewById(R.id.video_h264)).setChecked(true);
        }
        switch (Settings.audioCodec(this)) {
            case "opus": ((RadioButton) findViewById(R.id.audio_opus)).setChecked(true); break;
            default:     ((RadioButton) findViewById(R.id.audio_raw)).setChecked(true);
        }
        switch (Settings.maxSize(this)) {
            case 480:  ((RadioButton) findViewById(R.id.max_size_480)).setChecked(true); break;
            case 720:  ((RadioButton) findViewById(R.id.max_size_720)).setChecked(true); break;
            case 1080: ((RadioButton) findViewById(R.id.max_size_1080)).setChecked(true); break;
            case 1440: ((RadioButton) findViewById(R.id.max_size_1440)).setChecked(true); break;
            case 2160: ((RadioButton) findViewById(R.id.max_size_2160)).setChecked(true); break;
            default:   ((RadioButton) findViewById(R.id.max_size_0)).setChecked(true);
        }
        switch (Settings.videoBitRate(this)) {
            case 1_000_000:  ((RadioButton) findViewById(R.id.bit_rate_1m)).setChecked(true);  break;
            case 2_000_000:  ((RadioButton) findViewById(R.id.bit_rate_2m)).setChecked(true);  break;
            case 8_000_000:  ((RadioButton) findViewById(R.id.bit_rate_8m)).setChecked(true);  break;
            case 16_000_000: ((RadioButton) findViewById(R.id.bit_rate_16m)).setChecked(true); break;
            default:         ((RadioButton) findViewById(R.id.bit_rate_4m)).setChecked(true);
        }
        switch (Settings.maxFps(this)) {
            case 15:  ((RadioButton) findViewById(R.id.max_fps_15)).setChecked(true); break;
            case 30:  ((RadioButton) findViewById(R.id.max_fps_30)).setChecked(true); break;
            case 120: ((RadioButton) findViewById(R.id.max_fps_120)).setChecked(true); break;
            case 0:   ((RadioButton) findViewById(R.id.max_fps_0)).setChecked(true); break;
            default:  ((RadioButton) findViewById(R.id.max_fps_60)).setChecked(true);
        }
        videoGroup.setOnCheckedChangeListener((g, id) -> {
            String v = "h264";
            if (id == R.id.video_h265) v = "h265";
            else if (id == R.id.video_av1) v = "av1";
            Settings.setVideoCodec(this, v);
            Log.i("settings: video_codec=%s", v);
        });

        audioGroup.setOnCheckedChangeListener((g, id) -> {
            String a = id == R.id.audio_opus ? "opus" : "raw";
            Settings.setAudioCodec(this, a);
            Log.i("settings: audio_codec=%s", a);
        });

        maxSizeGroup.setOnCheckedChangeListener((g, id) -> {
            int v = 0;
            if      (id == R.id.max_size_480)  v = 480;
            else if (id == R.id.max_size_720)  v = 720;
            else if (id == R.id.max_size_1080) v = 1080;
            else if (id == R.id.max_size_1440) v = 1440;
            else if (id == R.id.max_size_2160) v = 2160;
            Settings.setMaxSize(this, v);
            Log.i("settings: max_size=%d", v);
        });

        bitRateGroup.setOnCheckedChangeListener((g, id) -> {
            // Every button maps explicitly. Falling back to
            // DEFAULT_VIDEO_BIT_RATE for the unmatched one silently tied
            // whichever button that was to the default's current value,
            // so changing the default changed what that button stored.
            int v;
            if      (id == R.id.bit_rate_1m)  v = 1_000_000;
            else if (id == R.id.bit_rate_2m)  v = 2_000_000;
            else if (id == R.id.bit_rate_4m)  v = 4_000_000;
            else if (id == R.id.bit_rate_8m)  v = 8_000_000;
            else if (id == R.id.bit_rate_16m) v = 16_000_000;
            else return;
            Settings.setVideoBitRate(this, v);
            Log.i("settings: video_bit_rate=%d", v);
        });


        maxFpsGroup.setOnCheckedChangeListener((g, id) -> {
            int v = 60;
            if      (id == R.id.max_fps_0)   v = 0;
            else if (id == R.id.max_fps_15)  v = 15;
            else if (id == R.id.max_fps_30)  v = 30;
            else if (id == R.id.max_fps_60)  v = 60;
            else if (id == R.id.max_fps_120) v = 120;
            else return;
            Settings.setMaxFps(this, v);
            Log.i("settings: max_fps=%d", v);
        });

        findViewById(R.id.licenses).setOnClickListener(v ->
                startActivity(new android.content.Intent(this, Licenses.class)));


        CheckBox lowLatencyBox = findViewById(R.id.low_latency);
        lowLatencyBox.setChecked(Settings.lowLatency(this));
        lowLatencyBox.setOnCheckedChangeListener((b, checked) -> {
            Settings.setLowLatency(this, checked);
            Log.i("settings: low_latency=%b", checked);
        });

        CheckBox clipboardBox = findViewById(R.id.clipboard_sync);
        clipboardBox.setChecked(Settings.clipboardSync(this));
        clipboardBox.setOnCheckedChangeListener((b, checked) -> {
            Settings.setClipboardSync(this, checked);
            Log.i("settings: clipboard=%b", checked);
        });

    }

    @SuppressWarnings("deprecation")
    private void showVersion() {
        try {
            PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            ((TextView) findViewById(R.id.version)).setText(getString(
                    R.string.version_format, info.versionName, info.getLongVersionCode()));
        } catch (PackageManager.NameNotFoundException e) {
            throw new IllegalStateException("installed package is missing", e);
        }
    }
}

package com.lixkrt.hotspotplus;

import android.app.Activity;
import android.os.Bundle;

/** Launcher long-press shortcut "切换热点": no UI, toggles and reports via toast. */
public final class ToggleActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        App.toast(this, "正在切换热点…");
        App.toggle(getApplicationContext(), null);
        finish();
    }
}

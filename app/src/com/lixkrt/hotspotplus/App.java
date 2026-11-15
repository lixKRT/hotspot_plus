package com.lixkrt.hotspotplus;

import android.app.Application;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;

public final class App extends Application {
    public static final String MODDIR = "/data/adb/modules/hotspot_plus";
    public static final String HSP = "sh " + MODDIR + "/bin/hsp";
    private static RootShell shell;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    public static synchronized RootShell shell() {
        if (shell == null) shell = new RootShell(new String[] {"su"}, true, 4);
        return shell;
    }

    public static void ui(Runnable r) {
        MAIN.post(r);
    }

    public static void toast(Context c, String msg) {
        if (msg == null || msg.trim().isEmpty()) return;
        final Context app = c.getApplicationContext();
        ui(() -> Toast.makeText(app, msg.trim(), Toast.LENGTH_LONG).show());
    }

    /** Toggle the hotspot via the module CLI (used by the tile and the launcher shortcut). */
    public static void toggle(Context c, RootShell.Callback done) {
        java.util.List<String> argv = java.util.Arrays.asList("LOCK_WAIT=20", "sh", HSP, "toggle");
        shell().execArgv(argv, r -> {
            if (r.code == RootShell.EACCES) toast(c, RootShell.DENIED_MSG);
            else toast(c, r.lastLine().isEmpty() ? (r.code == 0 ? "完成" : "失败 (" + r.code + ")") : r.lastLine());
            if (done != null) done.onResult(r);
        });
    }
}

package com.lixkrt.hotspotplus;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import org.json.JSONObject;

/** Quick Settings tile 「热点增强」: shows AP state, tap = hsp toggle. */
public final class HspTileService extends TileService {
    private static volatile boolean busy;
    private static volatile String lastSub = "";
    private static volatile int lastState = Tile.STATE_INACTIVE;

    @Override
    public void onStartListening() {
        apply(busy ? Tile.STATE_UNAVAILABLE : lastState, busy ? "切换中…" : lastSub);
        if (!busy) refresh();
    }

    @Override
    public void onClick() {
        if (busy) return;
        if (App.shell().isDenied()) {
            openApp();
            return;
        }
        busy = true;
        apply(Tile.STATE_UNAVAILABLE, "切换中…");
        App.toggle(getApplicationContext(), r -> {
            busy = false;
            App.ui(this::refresh);
            requestUpdate();
        });
    }

    private void refresh() {
        App.shell().execArgv(java.util.Arrays.asList("sh", App.HSP, "status", "--json"), r -> {
            int st;
            String sub;
            if (r.code == RootShell.EACCES) {
                st = Tile.STATE_INACTIVE;
                sub = "未授权 root";
            } else {
                try {
                    String o = r.out.trim();
                    JSONObject j = new JSONObject(o.substring(o.lastIndexOf('\n') + 1));
                    boolean ap = j.optBoolean("ap");
                    st = ap ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE;
                    sub = ap ? j.optString("addr", "已开启") : "已关闭";
                    if (j.optBoolean("op_busy")) sub = "操作进行中…";
                } catch (Exception e) {
                    st = Tile.STATE_INACTIVE;
                    sub = "模块未就绪";
                }
            }
            lastState = st;
            lastSub = sub;
            final int fst = st;
            final String fsub = sub;
            App.ui(() -> apply(fst, fsub));
        });
    }

    private void apply(int state, String sub) {
        Tile t = getQsTile();
        if (t == null) return;
        t.setState(state);
        t.setLabel("热点增强");
        t.setSubtitle(sub);
        t.updateTile();
    }

    private void requestUpdate() {
        try {
            TileService.requestListeningState(getApplicationContext(),
                    new ComponentName(getApplicationContext(), HspTileService.class));
        } catch (Exception ignored) {
        }
    }

    @SuppressWarnings("deprecation")
    private void openApp() {
        Intent i = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, i,
                    PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        } else {
            startActivityAndCollapse(i);
        }
    }
}

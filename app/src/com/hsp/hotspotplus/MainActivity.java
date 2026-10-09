package com.hsp.hotspotplus;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Bundle;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

/**
 * Hosts the module's own WebUI (single source of truth: /data/adb/modules/hotspot_plus/webroot/index.html,
 * read through su) and provides a KernelSU-compatible `window.ksu` bridge backed by persistent root shells.
 */
public final class MainActivity extends Activity {
    static final String BASE_URL = "https://hotspot-plus.local/";
    private WebView web;
    private FrameLayout root;
    private boolean night;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        night = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
                == Configuration.UI_MODE_NIGHT_YES;
        int bg = night ? 0xFF0F1115 : 0xFFF4F5F7;

        Window w = getWindow();
        w.setDecorFitsSystemWindows(false); // edge-to-edge (also the default for targetSdk 35+)

        root = new FrameLayout(this);
        root.setBackgroundColor(bg);
        web = new WebView(this);
        web.setBackgroundColor(bg);
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));
        // keep the page out of status bar / nav bar / cutout / keyboard
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()
                    | WindowInsets.Type.ime());
            v.setPadding(i.left, i.top, i.right, i.bottom);
            return WindowInsets.CONSUMED;
        });
        setContentView(root);
        // must run after setContentView: on HyperOS the DecorView doesn't exist yet before it (NPE in getInsetsController)
        try {
            WindowInsetsController ic = w.getDecorView().getWindowInsetsController();
            if (ic != null) {
                int light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                        | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                ic.setSystemBarsAppearance(night ? 0 : light, light);
            }
        } catch (Throwable t) {
            android.util.Log.w("HotspotPlus", "system bar appearance failed", t);
        }

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setSupportZoom(false);
        if (android.os.Build.VERSION.SDK_INT >= 33) s.setAlgorithmicDarkeningAllowed(false);
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                Uri u = req.getUrl();
                if (u != null && ("http".equals(u.getScheme()) || "https".equals(u.getScheme()))
                        && !BASE_URL.startsWith(u.getScheme() + "://" + u.getHost())) {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW, u));
                    } catch (Exception ignored) {
                    }
                }
                return true;
            }
        });
        web.addJavascriptInterface(new KsuBridge(), "ksu");
        web.addJavascriptInterface(new AppBridge(), "hspApp");
        load();
    }

    private void showHtml(String html) {
        App.ui(() -> web.loadDataWithBaseURL(BASE_URL, html, "text/html", "utf-8", null));
    }

    /** Read the module's index.html via su; fall back to the bundled copy. */
    void load() {
        showHtml(page("正在获取 root 权限…", "", false));
        App.shell().exec("cat " + App.MODDIR + "/webroot/index.html; [ -f " + App.MODDIR
                + "/disable ] && echo '<!--hsp-module-disabled-->'", null, null, r -> {
            if (r.code == RootShell.EACCES) {
                showHtml(page("需要 root 权限", RootShell.DENIED_MSG, true));
                return;
            }
            String html = r.out;
            if (!html.contains("<html")) {
                html = asset("index.html");
                App.toast(this, "未找到模块 hotspot_plus，已使用 App 内置界面；请先在 KernelSU 中安装模块并重启");
            } else if (html.contains("<!--hsp-module-disabled-->")) {
                App.toast(this, "模块 hotspot_plus 已在 KernelSU 中被禁用");
            }
            showHtml(html);
        });
    }

    private String asset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] b = new byte[16384];
            int n;
            while ((n = in.read(b)) > 0) bo.write(b, 0, n);
            return new String(bo.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return page("界面加载失败", String.valueOf(e), true);
        }
    }

    private String page(String title, String msg, boolean retry) {
        String fg = night ? "#e8eaed" : "#1d1d1f", sub = night ? "#9aa0a6" : "#6b7280",
                bg = night ? "#0f1115" : "#f4f5f7", card = night ? "#1a1d23" : "#fff";
        return "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
                + "<style>body{margin:0;background:" + bg + ";color:" + fg + ";font:15px/1.6 sans-serif;padding:24px}"
                + ".c{background:" + card + ";border-radius:16px;padding:20px}h2{margin:0 0 10px;font-size:19px}p{color:" + sub + "}"
                + "button{border:none;border-radius:10px;padding:10px 18px;font-size:15px;background:#2563eb;color:#fff}</style></head>"
                + "<body><div class='c'><h2>" + esc(title) + "</h2><p>" + esc(msg) + "</p>"
                + (retry ? "<button onclick='hspApp.retry()'>重试</button>" : "") + "</div></body></html>";
    }

    private static String esc(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.removeJavascriptInterface("ksu");
            web.destroy();
        }
        super.onDestroy();
    }

    /** App-only helpers (not part of the KernelSU API). */
    final class AppBridge {
        @JavascriptInterface
        public void retry() {
            App.ui(MainActivity.this::load);
        }
    }

    /** Same surface as KernelSU's WebUI `window.ksu` (exec / toast / fullScreen / moduleInfo). */
    final class KsuBridge {
        @JavascriptInterface
        public void exec(String cmd, String callback) {
            exec(cmd, "{}", callback);
        }

        @JavascriptInterface
        public void exec(String cmd, String options, String callback) {
            if (!RootShell.validCallbackName(callback)) return;
            String cwd = null;
            Map<String, String> env = null;
            try {
                if (options != null && !options.isEmpty()) {
                    JSONObject o = new JSONObject(options);
                    cwd = o.optString("cwd", null);
                    JSONObject e = o.optJSONObject("env");
                    if (e != null) {
                        env = new HashMap<>();
                        for (Iterator<String> it = e.keys(); it.hasNext(); ) {
                            String k = it.next();
                            env.put(k, e.optString(k));
                        }
                    }
                }
            } catch (Exception ignored) {
            }
            App.shell().exec(cmd == null ? "" : cmd, cwd, env, r -> {
                final String js = RootShell.callbackJs(callback, r);
                App.ui(() -> {
                    if (!isDestroyed()) web.evaluateJavascript(js, null);
                });
            });
        }

        @JavascriptInterface
        public void toast(String msg) {
            App.toast(MainActivity.this, msg);
        }

        @JavascriptInterface
        public void fullScreen(boolean on) {
            App.ui(() -> {
                WindowInsetsController c = getWindow().getDecorView().getWindowInsetsController();
                if (c == null) return;
                if (on) {
                    c.hide(WindowInsets.Type.systemBars());
                    c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                } else {
                    c.show(WindowInsets.Type.systemBars());
                }
            });
        }

        @JavascriptInterface
        public String moduleInfo() {
            return "{\"id\":\"hotspot_plus\",\"moduleDir\":\"" + App.MODDIR + "\",\"host\":\"hotspot_plus_app\"}";
        }
    }

}

package com.lixkrt.hotspotplus;

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
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import java.util.List;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;

/**
 * Hosts the module's own WebUI (single source of truth: /data/adb/modules/hotspot_plus/webroot/index.html,
 * read through su) and provides a WebUI-compatible `window.ksu` bridge backed by persistent root shells.
 */
public final class MainActivity extends Activity {
    static final String BASE_URL = WebPolicy.LOCAL_ORIGIN;
    private WebView web;
    private FrameLayout root;
    private boolean night;
    private final BridgeLifecycle bridge = new BridgeLifecycle();
    private String localHtml;

    private boolean trustedDocument() {
        return bridge.trusted();
    }

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
        // must run after setContentView: some OEM themes have no DecorView before it
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
        s.setAllowFileAccessFromFileURLs(false);
        s.setAllowUniversalAccessFromFileURLs(false);
        s.setBlockNetworkLoads(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setSupportZoom(false);
        if (android.os.Build.VERSION.SDK_INT >= 33) s.setAlgorithmicDarkeningAllowed(false);
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture,
                                          android.os.Message resultMsg) {
                return false;
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, String url) {
                return handleNavigation(url == null ? null : Uri.parse(url));
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                return handleNavigation(req.getUrl());
            }

            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                BridgeLifecycle.Action action = bridge.pageStarted(url);
                if (action == BridgeLifecycle.Action.REMOVE) {
                    web.removeJavascriptInterface("ksu");
                    web.removeJavascriptInterface("hspApp");
                }
            }

            @Override
            public void onPageCommitVisible(WebView view, String url) {
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                if (!bridge.accepting(url)) {
                    if (bridge.navigating(url) == BridgeLifecycle.Action.REMOVE) {
                        web.removeJavascriptInterface("ksu");
                        web.removeJavascriptInterface("hspApp");
                    }
                } else if (bridge.needsInstall()) {
                    installBridges();
                }
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                Uri u = request.getUrl();
                if (u != null && localHtml != null && WebPolicy.classifyDocument(u.toString())) {
                    return new WebResourceResponse("text/html", "utf-8",
                            new ByteArrayInputStream(localHtml.getBytes(StandardCharsets.UTF_8)));
                }
                if (u == null || !WebPolicy.subresource(u.toString())) {
                    return new WebResourceResponse("text/plain", "utf-8", null);
                }
                return null;
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            }
        });
        load();
    }

    private void showHtml(String html) {
        localHtml = html;
        App.ui(() -> {
            if (bridge.loadingDocument(BASE_URL) == BridgeLifecycle.Action.REMOVE) {
                web.removeJavascriptInterface("ksu");
                web.removeJavascriptInterface("hspApp");
            }
            web.loadUrl(BASE_URL);
        });
    }

    /** Read the module's index.html via su. Missing/disabled module pages get an explicit degraded page. */
    void load() {
        showHtml(page("正在获取 root 权限…", "", false));
        App.shell().execArgv(BridgeCommands.moduleDisabled(BridgeCommands.DISABLE), disabled -> {
            if (disabled.code == 0) {
                showHtml(page("本地界面不可用", "模块 hotspot_plus v0.3.0 已被禁用。请在 Magisk 中启用模块并重启；本应用不会加载内置副本或远程页面。", true));
                return;
            }
            App.shell().execArgv(BridgeCommands.readPage(BridgeCommands.PAGE), r -> {
                if (r.code == RootShell.EACCES) {
                    showHtml(page("需要 root 权限", RootShell.DENIED_MSG, true));
                    return;
                }
                String html = r.out;
                if (r.code != 0 || !html.contains("<html")) {
                    showHtml(page("本地界面不可用", "未找到模块 hotspot_plus v0.3.0 的本地 WebUI。请在 Magisk 中安装或启用模块并重启；本应用不会回退到内置副本或远程页面。", true));
                    return;
                }
                showHtml(html);
            });
        });
    }

    private boolean handleNavigation(Uri u) {
        WebPolicy.Nav nav = WebPolicy.navigation(u == null ? null : u.toString());
        if (nav == WebPolicy.Nav.EXTERNAL) {
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, u));
            } catch (Exception ignored) {
            }
        }
        return nav != WebPolicy.Nav.ALLOW;
    }

    private void installBridges() {
        web.addJavascriptInterface(new KsuBridge(), "ksu");
        web.addJavascriptInterface(new AppBridge(), "hspApp");
        bridge.markInstalled();
        web.evaluateJavascript("window.hspBridgeReady&&window.hspBridgeReady()", null);
    }

    private String page(String title, String msg, boolean retry) {
        String fg = night ? "#e8eaed" : "#1d1d1f", sub = night ? "#9aa0a6" : "#6b7280",
                bg = night ? "#0f1115" : "#f4f5f7", card = night ? "#1a1d23" : "#fff";
        return "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
                + "<style>body{margin:0;background:" + bg + ";color:" + fg + ";font:15px/1.6 sans-serif;padding:24px}"
                + ".c{background:" + card + ";border-radius:16px;padding:20px}h2{margin:0 0 10px;font-size:19px}p{color:" + sub + "}"
                + "button{border:none;border-radius:10px;padding:10px 18px;font-size:15px;background:#2563eb;color:#fff}</style></head>"
                + "<body><div class='c'><h2>" + esc(title) + "</h2><p>" + esc(msg) + "</p>"
                + (retry ? "<button id='retry'>重试</button><script>document.getElementById('retry').onclick=function(){location.replace('"
                + BASE_URL + "')}</script>" : "") + "</div></body></html>";
    }

    private static String esc(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            if (bridge.destroy() == BridgeLifecycle.Action.REMOVE) {
                web.removeJavascriptInterface("ksu");
                web.removeJavascriptInterface("hspApp");
            }
            web.destroy();
        }
        super.onDestroy();
    }

    /** App-only helpers (not part of the legacy WebUI bridge API). */
    final class AppBridge {
        @JavascriptInterface
        public void retry() {
            App.ui(MainActivity.this::load);
        }
    }

    /** Same surface as the WebUI `window.ksu` bridge (exec / toast / fullScreen / moduleInfo). */
    final class KsuBridge {
        @JavascriptInterface
        public void exec(String cmd, String callback) {
            exec(cmd, "{}", callback);
        }

        @JavascriptInterface
        public void exec(String cmd, String options, String callback) {
            if (!RootShell.validCallbackName(callback)) return;
            final boolean trusted = trustedDocument();
            if (!trusted) return;
            List<String> argv = CommandPolicy.parse(cmd);
            if (argv == null) {
                App.ui(() -> {
                    if (trustedDocument()) {
                        web.evaluateJavascript(RootShell.callbackJs(callback,
                                new RootShell.Result(126, "", "命令不在 hsp 允许的固定接口内。", false)), null);
                    }
                });
                return;
            }
            if (argv.size() == 5 && "lease".equals(argv.get(1)) && "stage".equals(argv.get(2))
                    && argv.get(4).startsWith("import=")) {
                stageLeaseImport(callback, trusted, argv.get(4).substring(7));
                return;
            }
            runArgv(callback, trusted, argv);
        }

        private void stageLeaseImport(String callback, boolean trusted, String payload) {
            String content = CommandPolicy.decodeImport(payload);
            if (content == null) {
                App.ui(() -> {
                    if (trustedDocument()) {
                        web.evaluateJavascript(RootShell.callbackJs(callback,
                                new RootShell.Result(126, "", "静态租约导入数据无效。", false)), null);
                    }
                });
                return;
            }
            App.shell().execArgv(BridgeCommands.stageImport(BridgeCommands.HSP, BridgeCommands.LEASE_IMPORT),
                    content, r -> {
                        if (r.code != 0) {
                            finish(callback, trusted, r);
                            return;
                        }
                        App.shell().execArgv(BridgeCommands.importFile(BridgeCommands.HSP, BridgeCommands.LEASE_IMPORT),
                                done -> finish(callback, trusted, done));
                    });
        }

        private void finish(String callback, boolean trusted, RootShell.Result r) {
            App.ui(() -> {
                if (trustedDocument() && trusted == trustedDocument()) {
                    web.evaluateJavascript(RootShell.callbackJs(callback, r), null);
                }
            });
        }

        private void runArgv(String callback, boolean trusted, List<String> argv) {
            App.shell().execArgv(argv, r -> {
                final String js = RootShell.callbackJs(callback, r);
                App.ui(() -> {
                    if (!isDestroyed() && trustedDocument() && trusted == trustedDocument()) {
                        web.evaluateJavascript(js, null);
                    }
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

        /** Probe for the WebUI: a live bridge answers; a stale/unbound one throws. */
        @JavascriptInterface
        public String ping() {
            return "ok";
        }
    }

}

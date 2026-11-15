package com.lixkrt.hotspotplus;

public final class WebPolicyTest {
    private static int failures;

    public static void main(String[] args) {
        check("local document is trusted", WebPolicy.classifyDocument(WebPolicy.LOCAL_ORIGIN));
        check("same-origin navigation stays in WebView", WebPolicy.navigation(WebPolicy.LOCAL_ORIGIN + "settings") == WebPolicy.Nav.ALLOW);
        check("external http opens browser", WebPolicy.navigation("https://example.com/a") == WebPolicy.Nav.EXTERNAL);
        check("scheme-relative remote is rejected", WebPolicy.navigation("//example.com/a") == WebPolicy.Nav.BLOCK);
        check("file navigation is rejected", WebPolicy.navigation("file:///data/local/tmp/x") == WebPolicy.Nav.BLOCK);
        check("content navigation is rejected", WebPolicy.navigation("content://x/y") == WebPolicy.Nav.BLOCK);
        check("javascript navigation is rejected", WebPolicy.navigation("javascript:alert(1)") == WebPolicy.Nav.BLOCK);
        check("lookalike host is external, never trusted", WebPolicy.navigation("https://hotspot-plus.local.evil/") == WebPolicy.Nav.EXTERNAL);
        check("local subresource allowed", WebPolicy.subresource(WebPolicy.LOCAL_ORIGIN + "index.html"));
        check("remote subresource blocked", !WebPolicy.subresource("https://example.com/a.js"));
        check("data main document allowed", WebPolicy.subresource("data:text/html;charset=utf-8;base64,PGh0bWw+"));
        check("data document is not trusted", !WebPolicy.classifyDocument("data:text/html,<script>alert(1)</script>"));
        check("file subresource blocked", !WebPolicy.subresource("file:///data/local/tmp/x"));
        System.out.println("web policy: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static void check(String name, boolean ok) {
        if (!ok) { failures++; System.err.println("FAIL " + name); }
    }
}

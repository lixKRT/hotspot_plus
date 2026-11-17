package com.lixkrt.hotspotplus;

import java.net.URI;
import java.net.URISyntaxException;

/** Pure navigation/content policy shared by the WebView host and host-side tests. */
public final class WebPolicy {
    public static final String LOCAL_ORIGIN = "https://hotspot-plus.local/";
    private static final String SCHEME = "https";
    private static final String HOST = "hotspot-plus.local";

    public enum Nav { ALLOW, EXTERNAL, BLOCK }

    private WebPolicy() {}

    /** Whether a document URL belongs to the app's single trusted local origin. */
    public static boolean classifyDocument(String url) {
        URI u = parse(url);
        return u != null && isLocalOrigin(u);
    }

    public static Nav navigation(String url) {
        URI u = parse(url);
        if (u == null) return Nav.BLOCK;
        if (isLocalOrigin(u)) return Nav.ALLOW;
        if ("http".equalsIgnoreCase(u.getScheme()) || "https".equalsIgnoreCase(u.getScheme())) {
            return u.getHost() != null && !u.getHost().isEmpty() ? Nav.EXTERNAL : Nav.BLOCK;
        }
        return Nav.BLOCK;
    }

    /** Main-frame and subresource requests must stay on the local origin. */
    public static boolean subresource(String url) {
        URI u = parse(url);
        if (u == null) return false;
        if (isLocalOrigin(u)) return true;
        return "data".equalsIgnoreCase(u.getScheme());
    }

    private static boolean isLocalOrigin(URI u) {
        if (!SCHEME.equalsIgnoreCase(u.getScheme())) return false;
        if (u.getHost() == null || !HOST.equalsIgnoreCase(u.getHost())) return false;
        int port = u.getPort();
        return port == -1 || port == 443;
    }

    private static URI parse(String url) {
        if (url == null) return null;
        try {
            URI u = new URI(url.trim());
            return u.isAbsolute() ? u : null;
        } catch (URISyntaxException e) {
            return null;
        }
    }
}

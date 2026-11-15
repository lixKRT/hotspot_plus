package com.lixkrt.hotspotplus;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Fixed argv templates for app-originated root operations. Never contains shell source. */
public final class BridgeCommands {
    public static final String MODDIR = "/data/adb/modules/hotspot_plus";
    public static final String HSP = MODDIR + "/bin/hsp";
    public static final String PAGE = MODDIR + "/webroot/index.html";
    public static final String DISABLE = MODDIR + "/disable";
    public static final String LEASE_IMPORT = MODDIR + "/webroot/lease-import.conf";

    private BridgeCommands() {}

    public static List<String> readPage(String page) {
        return Arrays.asList("cat", page);
    }

    public static List<String> moduleDisabled(String disable) {
        return Arrays.asList("test", "-f", disable);
    }

    public static List<String> toggle(String hsp) {
        return Arrays.asList(hsp, "toggle");
    }

    public static List<String> hsp(String hsp, String... args) {
        List<String> out = new ArrayList<>();
        out.add(hsp);
        out.addAll(Arrays.asList(args));
        return out;
    }

    public static List<String> importFile(String hsp, String path) {
        return Arrays.asList(hsp, "lease", "import-file", path);
    }

    public static List<String> stageImport(String hsp, String path) {
        return Arrays.asList(hsp, "lease", "stage", path);
    }

    /** Ordered argv sequence for page detection and loading (no shell source). */
    public static List<List<String>> pageLoad() {
        return Arrays.asList(moduleDisabled(DISABLE), readPage(PAGE));
    }
}
